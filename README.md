# Breaker (CBRK) and CircuitBreakerHook

A Uniswap v4 launch for Sepolia (chain id 11155111): a fixed-supply ERC-20 and a hook that refuses any
swap leaving the pool's price more than 10% away from where the block started.

| Contract | Source | ABI | What it is |
| --- | --- | --- | --- |
| `CBRK` | `src/CBRK.sol` | `docs/abi/CBRK.json` | "Breaker", 1,000,000,000 CBRK, 18 decimals, minted once to the deployer, no constructor arguments, no owner or mint |
| `CircuitBreakerHook` | `src/CircuitBreakerHook.sol` | `docs/abi/CircuitBreakerHook.json` | v4 hook with `beforeSwap` + `afterSwap`, one constructor argument (the PoolManager), no owner, fee, deltas or funds |
| `HookFlags` | `src/HookFlags.sol` | library | The 14 permission bits, address matching and a deterministic CREATE2 salt miner |

## How the hook works

Per pool (keyed by `PoolId`) and per block:

1. **`beforeSwap`** of the block's first swap stores `refBlock[poolId] = block.number` and
   `refSqrtPrice[poolId] = sqrtPriceX96` read from `StateLibrary.getSlot0`, the price *before* that swap,
   and emits `ReferenceSet(poolId, blockNumber, sqrtPriceX96)`. Later swaps in the same block reuse it.
2. **`afterSwap`** reads the post-swap `sqrtPriceX96` and reverts with `Tripped(refSqrtPriceX96, newSqrtPriceX96)`
   unless `ref * sqrt(0.9) <= new <= ref * sqrt(1.1)`, which is the spot price (sqrt price squared) within
   -10% / +10% of the reference.
3. **`afterSwap`** then reverts with `PhantomSwap(refSqrtPriceX96, newSqrtPriceX96)` when the swap delta the
   PoolManager hands it is zero in both currencies. The PoolManager rejects a zero `amountSpecified` and a
   price limit at the current price, so a zero delta means the swap only slid the price through ticks that
   hold no liquidity. That is not a trade, and it may not become the next block's reference (see
   "Reference ratchet through empty liquidity" below). The band is checked first, so a phantom move that
   also leaves the band reports `Tripped`.

The band is computed with `FullMath.mulDiv` against two Q64.96 constants:

| Constant | Value | Rounding |
| --- | --- | --- |
| `SQRT_0_9_X96` | 75162434512514379355924140471 | ceiling of sqrt(0.9) * 2^96 |
| `SQRT_1_1_X96` | 83095197869223157896060286990 | floor of sqrt(1.1) * 2^96 |

The lower edge uses `mulDivRoundingUp`, the upper edge plain `mulDiv`, so every rounding leans inward and
the allowed band is always a subset of the true 10% band. `test_constants_areRoundedInward` proves the
constants are the tightest integers on the inward side; the fuzz tests check the band never exceeds 10%
for any reference and never overflows anywhere in the sqrt-price domain.

Consequences worth knowing:

- **A single swap can trip.** The reference is taken before the block's first swap, so one trade that
  would move the price more than 10% reverts. Large trades have to be split across blocks.
- **Tripped swaps leave nothing behind.** The revert unwinds the reference write and the event; the site
  simulates instead of listing tripped swaps. The same holds for refused phantom swaps.
- **A swap has to exchange something.** A swap whose delta is zero in both currencies is refused. No
  ordinary trade is affected: exact-in always consumes its input, exact-out always delivers its output, and
  a real trade that runs out of liquidity and slides on to its limit still has a non-zero delta.
- **Liquidity changes and donations are never checked.** They do not move the price and the hook has no
  liquidity or donate permissions, so nothing in the hook can revert the factory's initialize or seed.
- **Non-ETH pools are ignored.** A pool on this hook whose `currency0` is not native ETH gets zero deltas
  and nothing else: no reference, no event, no check.
- **Every callback requires `msg.sender == PoolManager`.** The eight disabled callbacks also refuse other
  callers, then revert `HookNotImplemented`; they are unreachable through the PoolManager because their
  address bits are off.

### Permissions

`getHookPermissions()` enables exactly `beforeSwap` and `afterSwap`: low address bits `0x00C0`. The
constructor calls `Hooks.validateHookPermissions`, so deploying at any other address reverts with
`HookAddressNotValid`. All four return-delta flags are off; the hook never takes, settles or adjusts an
amount and holds no funds.

### Views for integrators

| View | Returns |
| --- | --- |
| `refBlock(poolId)`, `refSqrtPrice(poolId)` | The stored reference (zero before a pool's first swap) |
| `currentReference(poolId)` | This block's reference, or the live price when no swap happened yet this block, plus a flag saying which |
| `currentBand(poolId)` | The same reference with its lower and upper sqrt-price edges |
| `allowedBand(ref)`, `isWithinBand(ref, new)` | The pure band maths |
| `wouldTrip(poolId, newSqrtPriceX96)` | Whether a swap ending at that price would trip right now |

**Decoding a trip from a simulation.** The PoolManager wraps hook reverts, so an `eth_call` of a tripping
swap returns `CustomRevert.WrappedError(address hook, bytes4 0xb47b2fb1 /* afterSwap */, bytes reason,
bytes details)` where `reason` is `Tripped(uint160 ref, uint160 new)` (selector `0xf5207678`) or
`PhantomSwap(uint160 ref, uint160 new)` (selector `0x9ac63f26`) and `details` is `HookCallFailed()`
(`0xa9e35b2f`). The tests' `decodeTripped` and `decodePhantom` helpers in
`test/utils/CircuitBreakerFixture.sol` show the exact decoding.

## Deployment parameters

| Parameter | Value | Where it lives |
| --- | --- | --- |
| Chain | Sepolia, 11155111 | manifest |
| PoolManager (hook constructor argument, the only one) | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` | `script/Deploy.s.sol`, manifest |
| Hook flags / address suffix | `0x00C0` (`beforeSwap`, `afterSwap`) | `HookFlags`, `CircuitBreakerHook.HOOK_FLAGS()` |
| Hook creation code | `type(CircuitBreakerHook).creationCode ++ abi.encode(poolManager)`, 6,126 bytes with the Sepolia PoolManager | `Deploy.hookCreationCode()` |
| Token | `CBRK`, zero-argument constructor, 1e27 base units minted to `msg.sender` | `src/CBRK.sol` |
| Pool key | `currency0` = native ETH (address zero), `currency1` = CBRK, fee 3000, tickSpacing 60, hooks = the hook | factory; mirrored in `test/utils/LaunchParams.sol` |
| Band | 10% either side of the block's opening price; source constants, not configurable | `CircuitBreakerHook` |

The CREATE2 salt is a pure function of the creation code and the deploying address. `Deploy.mineHookSalt`
recomputes it for any deployer; `test_sepoliaSaltIsDeterministic` shows two runs agree. Through Foundry's
deterministic deployer (`0x4e59b44847b379578588920cA78FbF26c0B4956C`) the current bytecode lands at
`0xb7E7CaD69B7F227e4Deda87a791f9f3D02f240c0` with salt 1643. The factory deploys from its own address and
therefore mines its own salt; the flags and creation code are what it must match, not that address.

### Assumptions the rehearsal makes about the factory

The workflow fixes the pool key and says the factory seeds one-sided CBRK liquidity, but not the opening
price or the seed size. `test/utils/LaunchParams.sol` pins the values the rehearsal uses; they are inputs
to the manifest, not something the contracts know:

| Assumption | Rehearsal value |
| --- | --- |
| Opening tick / price | tick 152040, about 4,005,700 CBRK per ETH (roughly 250 ETH for the whole supply) |
| Seed range | ticks 92040 to 152040, i.e. from the opening price down to about 9,900 CBRK per ETH |
| Seed size | 500,000,000 CBRK (half the supply); liquidity 262,912,293,681,752,076,105,596 |

With that seed, the first buy of 1 ETH moves the opening price by about 1.5% and passes; anything above
roughly 7.5 ETH in one swap trips. If the factory opens at a different price or seeds differently, only
the "small" and "oversized" buy sizes shift; the hook behaves the same. The rehearsal also shows that a
sell before any buy into the ETH-less pool either trips (far price limit) or is refused as a phantom swap
(limit inside the band), because there is no liquidity above the opening price and the slide would
exchange nothing. A sell after buys exist that drains the pool's ETH and slides on is a real trade and only
the band judges it.

### Reference ratchet through empty liquidity

The independent review found that the accepted design, combined with the one-sided seed, let anyone move
the next block's reference for gas alone. Nothing above the opening tick holds liquidity, so a
`oneForZero` swap of 1 wei with its price limit at the block's upper band edge slid the price to that edge
while exchanging nothing (delta `(0, 0)`, no CBRK, no ETH, no approval), and passed `afterSwap` because
the end price was exactly the inclusive edge. The next block's reference was then the pushed price; a
second push put it 21% above the opening price, and from there every buy tripped, because a buy has to
travel back down to the opening price before it reaches liquidity and can never end above it. Walking the
price back down was equally free but capped at -10% per block, and the attacker could re-push in the
same block, so whoever was last in a block set the next reference.

**What changed.** `afterSwap` now refuses a swap whose delta is zero in both currencies (`PhantomSwap`).
The exact reported sequence reverts, leaves no state and no reference, and buys in the following block are
judged against the opening price (`test_ratchet_freeEdgePushIsRefusedAndNextBlockBuysStillPass`). The rule
costs no legitimate trader anything: a swap that exchanges nothing has no economic purpose.

**What it does not close, and the decision it leaves open.** The rule raises the attacker's cost from
zero to a few wei, not to a real trade. An attacker can first park a dust ETH-only position just above the
opening tick (tens of wei of ETH), then sell dust CBRK through it. That swap has a non-zero delta, so only
the band judges it, and the reference can still be walked upward by 10% per block
(`test_ratchet_dustLiquidityVariantIsNotClosedByTheRule` records this). Closing it needs a change the
approved workflow does not give this hook: either the factory seeds two-sided liquidity around the
opening price, so that pushing the price up means buying into real depth and paying real slippage (the
documented, accepted one-block griefing), or the reference is redefined as something other than the raw
pre-block `slot0` price. Both are launch-owner decisions; this repository documents the exposure and
leaves the approved reference definition and seed shape alone. Until one is taken, the launch pool is
exposed to a cheap buy-side lock-out that a defender can only undo by being the last swap in a block.

## Operational responsibilities

- **Nothing to operate on the hook.** There is no owner, admin, setter, pause, upgrade or sweep. The
  band, the flags and the PoolManager are fixed at deployment. Changing anything means a new hook and a
  new pool.
- **Traders split large orders across blocks.** The site's pre-check simulates a typed swap and says
  whether it would trip; routers that do not simulate will see reverts.
- **One-block edge griefing with live liquidity is possible and accepted.** With two-sided liquidity
  around the price, whoever is first in a block can swap the price to just inside a band edge; every later
  swap in that block that would move further in that direction reverts in `afterSwap`, so victims pay gas
  and get no fill (`test_griefing_edgePushBlocksSameDirectionForTheBlock`). Call sequence: block N, tx 1,
  attacker swaps `zeroForOne` with a huge exact-in amount and `sqrtPriceLimitX96` at -9.5% from the
  reference; tx 2, a victim's ordinary buy reverts with `Tripped`; tx 3, a sell (back toward the
  reference) passes; block N+1 re-anchors at the pushed price and the victim's buy passes. Holding the
  edge costs the attacker the 0.30% fee plus the slippage of a real trade of roughly 9.5% of pool depth,
  recoverable only by trading back. This is inherent to a per-block band and is not mitigated here.
- **The costless variant on an empty range is refused, the dust variant is not.** See "Reference ratchet
  through empty liquidity" above: on the one-sided launch pool the phantom-swap rule stops the free push,
  but a push through dust liquidity still costs only wei. The launch owners need to decide between a
  two-sided seed and accepting that exposure before launch.
- **Same-block reference is per pool.** A second ETH pool on the same hook (different fee or spacing)
  gets its own reference and budget.
- **hookData is unused.** The hook reads no swapper identity and credits nobody; hookData is
  unauthenticated and ignored.
- **Independent review before release.** The suite is not an audit. The adversarial review should attack:
  the sqrt constants and rounding direction (`allowedBand`), overflow in the band maths (`FullMath`,
  `uint256` results), that the reference is captured before any swap including the first
  (`beforeSwap` ordering), any same-block path that moves the price without reaching `afterSwap`
  (none known: liquidity and donate do not move price; initialize has no swap), and the griefing above.
- **Monitoring.** Watch `ReferenceSet` per block for the reference the site displays; tripped swaps have
  no on-chain trace beyond the failed transaction.

## Repository layout

```
src/              CBRK.sol, CircuitBreakerHook.sol, HookFlags.sol
script/Deploy.s.sol   reference deployment; constants only, no env reads; deploy() is covered by a test
test/             Foundry suite (see below), test/utils fixture and launch parameters, test/mocks
docs/abi/         ABI exports for the two deployable contracts
lib/              vendored dependencies as plain files; versions in lib/VERSIONS.md
```

`foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"`, `bytecode_hash = "none"`, `via_ir = true`
with the same optimizer runs v4-core uses, `ffi = false` and no filesystem permissions. `remappings.txt`
maps `v4-core/`, `forge-std/`, `solmate/` and `@openzeppelin/` to `lib/`.

## Tests

```
forge build
forge test
forge fmt --check
```

The suite deploys a real v4-core `PoolManager` in each test, mines the hook address for `0x00C0` and
deploys it with CREATE2, exactly as the factory will. It reads no environment variables, so it runs in any
order and in parallel.

| File | Covers |
| --- | --- |
| `test/LaunchRehearsal.t.sol` | Factory-style initialize at the manifest price, one-sided CBRK seed (zero ETH taken), the first buy into the ETH-less pool passing and emitting `ReferenceSet`, an oversized first buy tripping and leaving no state, the same amount succeeding when split across blocks, a sell into the ETH-less pool (trips or is refused as phantom), a real sell that drains the ETH and slides on, the next block's reference, fuzzed first-buy sizes, the reference ratchet: the free edge push is refused and next-block buys pass, the arithmetic of a pushed reference, and the dust-liquidity residual |
| `test/CircuitBreakerHook.t.sol` | Permissions exactly `beforeSwap`/`afterSwap` and the address bits, constructor rejecting a wrong address, inward-rounded constants, band fuzzing (contains reference, never exceeds 10%, never overflows), all ten callbacks refusing non-PoolManager callers, disabled callbacks refusing even the PoolManager, reference capture and once-per-block emission, exact-in and exact-out both ways, dust, 9.9% passing and 10.1% tripping both ways, inclusive band edges, two same-block swaps whose sum passes 10% (second trips), swap back inside the band, new block reset, griefing, liquidity/donate never checked, non-ETH pool ignored, per-`PoolId` state, views, fuzzed buys/sells/exact-out with truthful `Tripped` reasons |
| `test/CBRK.t.sol` | Metadata, single mint to the deployer from bare creation code, exact transfers, allowance, reverts, no admin selector changes supply, fuzzed conservation |
| `test/HookFlags.t.sol` | Constants mirror v4-core, matching, packing permissions, deterministic mining for any deployer, budget exhaustion |
| `test/Deploy.t.sol` | `Deploy.deploy()` end to end against a fresh manager; Sepolia salt determinism |

Tests use `vm.getBlockNumber()` rather than `block.number` after `vm.roll`: under via-IR the compiler may
cache `block.number` within a test function.

## Out of scope here

The manifest (`launch.json`) is produced by a separate assignment; the adversarial review is separate and
read-only; publication, attestation, admission, the factory deployment and the static site come after this
stage. This repository authorises no transactions and holds no keys.
