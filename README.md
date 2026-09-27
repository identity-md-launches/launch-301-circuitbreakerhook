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
  simulates instead of listing tripped swaps.
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
bytes details)` where `reason` is `Tripped(uint160 ref, uint160 new)` (selector `0xf5207678`) and
`details` is `HookCallFailed()` (`0xa9e35b2f`). The tests' `decodeTripped` helper in
`test/utils/CircuitBreakerFixture.sol` shows the exact decoding.

## Deployment parameters

| Parameter | Value | Where it lives |
| --- | --- | --- |
| Chain | Sepolia, 11155111 | manifest |
| PoolManager (hook constructor argument, the only one) | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` | `script/Deploy.s.sol`, manifest |
| Hook flags / address suffix | `0x00C0` (`beforeSwap`, `afterSwap`) | `HookFlags`, `CircuitBreakerHook.HOOK_FLAGS()` |
| Hook creation code | `type(CircuitBreakerHook).creationCode ++ abi.encode(poolManager)`, 6,048 bytes with the Sepolia PoolManager | `Deploy.hookCreationCode()` |
| Token | `CBRK`, zero-argument constructor, 1e27 base units minted to `msg.sender` | `src/CBRK.sol` |
| Pool key | `currency0` = native ETH (address zero), `currency1` = CBRK, fee 3000, tickSpacing 60, hooks = the hook | factory; mirrored in `test/utils/LaunchParams.sol` |
| Band | 10% either side of the block's opening price; source constants, not configurable | `CircuitBreakerHook` |

The CREATE2 salt is a pure function of the creation code and the deploying address. `Deploy.mineHookSalt`
recomputes it for any deployer; `test_sepoliaSaltIsDeterministic` shows two runs agree. Through Foundry's
deterministic deployer (`0x4e59b44847b379578588920cA78FbF26c0B4956C`) the current bytecode lands at
`0x11Dd314E859Ff3925BE83eC5d6f2634D19D4C0C0` with salt 3177. The factory deploys from its own address and
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
sell before any buy into the ETH-less pool either trips (far price limit) or settles at its limit with
nothing exchanged (limit inside the band), because there is no liquidity above the opening price.

## Operational responsibilities

- **Nothing to operate on the hook.** There is no owner, admin, setter, pause, upgrade or sweep. The
  band, the flags and the PoolManager are fixed at deployment. Changing anything means a new hook and a
  new pool.
- **Traders split large orders across blocks.** The site's pre-check simulates a typed swap and says
  whether it would trip; routers that do not simulate will see reverts.
- **Griefing is possible and accepted.** Anyone can push the price to the band edge early in a block and
  block every further move in that direction until the next block (`test_griefing_edgePushBlocksSameDirectionForTheBlock`).
  Moves back toward the reference stay open, the attacker pays fees and slippage to hold the edge, and
  the next block starts from wherever the price ended. This is inherent to a per-block band and is not
  mitigated here.
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
| `test/LaunchRehearsal.t.sol` | Factory-style initialize at the manifest price, one-sided CBRK seed (zero ETH taken), the first buy into the ETH-less pool passing and emitting `ReferenceSet`, an oversized first buy tripping and leaving no state, the same amount succeeding when split across blocks, a sell into the ETH-less pool, the next block's reference, fuzzed first-buy sizes |
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
