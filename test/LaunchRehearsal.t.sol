// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {CircuitBreakerHook} from "../src/CircuitBreakerHook.sol";
import {CircuitBreakerFixture} from "./utils/CircuitBreakerFixture.sol";
import {LaunchParams} from "./utils/LaunchParams.sol";

/// @notice The launch, step by step, the way the factory performs it: initialize at the manifest price,
/// seed one-sided CBRK liquidity, and let the first buy land in a pool that holds no ETH.
contract LaunchRehearsalTest is CircuitBreakerFixture {
    using StateLibrary for IPoolManager;
    using StateLibrary for PoolManager;

    /// @dev Sized against `LaunchParams`: 1 ETH moves the opening price by well under 1%; 20 ETH by more
    /// than 10%. Both are checked below rather than assumed.
    uint256 constant SMALL_FIRST_BUY = 1 ether;
    uint256 constant OVERSIZED_FIRST_BUY = 20 ether;

    function test_rehearsal_initializeSeedAndFirstBuy() public {
        // 1. initialize: the hook has no initialize callbacks, so nothing here can revert the factory
        int24 tick = initializePool();
        assertEq(tick, LaunchParams.INITIAL_TICK);
        assertEq(currentSqrtPrice(), initialSqrtPrice);
        assertEq(hook.refBlock(poolId), 0, "initialize must not touch the hook");

        // 2. one-sided seed: only CBRK goes in, the pool holds no ETH
        uint256 cbrkBefore = cbrk.balanceOf(address(this));
        (BalanceDelta seed, uint128 liquidity) = seedOneSided();
        assertEq(seed.amount0(), 0, "the seed took ETH");
        assertLt(seed.amount1(), 0, "the seed took no CBRK");
        assertLe(uint256(uint128(-seed.amount1())), LaunchParams.SEED_AMOUNT, "the seed took more than committed");
        assertEq(cbrkBefore - cbrk.balanceOf(address(this)), uint256(uint128(-seed.amount1())));
        assertEq(address(manager).balance, 0, "the pool holds ETH before the first buy");
        assertEq(manager.getLiquidity(poolId), 0, "the seed is active at the opening tick; it must sit below it");
        assertGt(liquidity, 0);
        assertEq(hook.refBlock(poolId), 0, "adding liquidity must not touch the hook");

        // 3. the first buy: ETH into an ETH-less pool, judged against the opening price
        uint256 ethBefore = address(this).balance;
        vm.expectEmit(true, true, true, true, address(hook));
        emit CircuitBreakerHook.ReferenceSet(poolId, vm.getBlockNumber(), initialSqrtPrice);
        BalanceDelta buy = swapExactIn(true, SMALL_FIRST_BUY);

        assertEq(buy.amount0(), -int256(SMALL_FIRST_BUY), "the first buy did not spend all its ETH");
        assertGt(buy.amount1(), 0, "the first buy received no CBRK");
        assertEq(ethBefore - address(this).balance, SMALL_FIRST_BUY, "router kept ETH");
        assertEq(address(manager).balance, SMALL_FIRST_BUY, "the pool did not receive the ETH");
        assertLt(currentSqrtPrice(), initialSqrtPrice, "the buy did not move the price");
        assertTrue(hook.isWithinBand(initialSqrtPrice, currentSqrtPrice()));
        assertEq(hook.refSqrtPrice(poolId), initialSqrtPrice);
        assertEq(hook.refBlock(poolId), vm.getBlockNumber());
        assertEq(manager.getLiquidity(poolId), liquidity, "the buy did not enter the seeded range");
    }

    function test_rehearsal_oversizedFirstBuyTrips() public {
        initializePool();
        seedOneSided();

        try swapRouter.swap{value: OVERSIZED_FIRST_BUY}(
            key,
            SwapParams(true, -int256(OVERSIZED_FIRST_BUY), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        ) {
            revert("an oversized first buy went through");
        } catch (bytes memory reason) {
            (uint160 ref, uint160 newPrice) = decodeTripped(reason);
            assertEq(ref, initialSqrtPrice, "reference must be the opening price");
            (uint256 lower,) = hook.allowedBand(initialSqrtPrice);
            assertLt(newPrice, lower, "not below the lower edge");
        }

        assertEq(currentSqrtPrice(), initialSqrtPrice, "a tripped buy moved the price");
        assertEq(address(manager).balance, 0, "a tripped buy left ETH in the pool");
        assertEq(hook.refBlock(poolId), 0, "a tripped buy left a reference");
    }

    /// @dev The same oversized amount goes through when split across blocks, each part inside its band.
    function test_rehearsal_oversizedBuySplitAcrossBlocksSucceeds() public {
        initializePool();
        seedOneSided();

        uint256 part = OVERSIZED_FIRST_BUY / 4;
        for (uint256 i = 0; i < 4; i++) {
            uint160 ref = currentSqrtPrice();
            swapExactIn(true, part);
            assertTrue(hook.isWithinBand(ref, currentSqrtPrice()));
            vm.roll(vm.getBlockNumber() + 1);
        }
        assertEq(address(manager).balance, OVERSIZED_FIRST_BUY);
    }

    /// @dev A sell before any buy: there is no liquidity above the opening price, so the pool would slide
    /// to the price limit without trading. With a far limit that is a >10% move and the hook trips; with
    /// a limit inside the band the slide exchanges nothing and is refused as a phantom swap, so the price
    /// stays where it was and no reference is left behind.
    function test_rehearsal_sellIntoEthlessPool() public {
        initializePool();
        seedOneSided();

        uint160 far = TickMath.MAX_SQRT_PRICE - 1;
        expectTripped(initialSqrtPrice, far);
        swap(key, false, -int256(1000 ether), far);

        uint160 nearLimit = sqrtPriceAtRatio(initialSqrtPrice, 10_500);
        expectPhantom(initialSqrtPrice, nearLimit);
        swap(key, false, -int256(1000 ether), nearLimit);

        assertEq(currentSqrtPrice(), initialSqrtPrice, "a refused slide moved the price");
        assertEq(hook.refBlock(poolId), 0, "a refused slide left a reference");
        assertEq(address(manager).balance, 0);
    }

    /// @dev A real sell after buys exist trades through the seed range and may run out of ETH at the
    /// opening tick; the swap then slides on to its limit without exchanging more. Its delta is not zero,
    /// so it is not a phantom swap; only the band judges it. The price it leaves above the seed is one a
    /// real trade reached, and a small buy in the next block brings the pool back into the seeded range.
    function test_rehearsal_sellThatDrainsTheEthAndSlidesOnIsATrade() public {
        initializePool();
        seedOneSided();
        swapExactIn(true, SMALL_FIRST_BUY);
        vm.roll(vm.getBlockNumber() + 1);

        uint160 ref = currentSqrtPrice();
        uint160 limit = sqrtPriceAtRatio(ref, 10_500); // inside the band, above the opening price
        assertGt(limit, initialSqrtPrice);
        BalanceDelta d = swap(key, false, -int256(100_000_000 ether), limit); // far more than the pool's ETH
        // the buy's 0.30% fee stays with the seed position as ETH; everything else comes back out
        assertGt(d.amount0(), int256(SMALL_FIRST_BUY * 99 / 100), "the sell did not take (almost) all the ETH");
        assertLt(d.amount1(), 0, "the sell paid no CBRK");
        assertEq(currentSqrtPrice(), limit, "the sell did not slide to its limit");
        assertLt(address(manager).balance, SMALL_FIRST_BUY / 100, "ETH left after a full drain");

        vm.roll(vm.getBlockNumber() + 1);
        swapExactIn(true, 0.05 ether);
        assertLt(currentSqrtPrice(), initialSqrtPrice, "the buy did not re-enter the seed");
    }

    // ---------------------------------------------------------------------------------------------
    // Reference ratchet through empty liquidity (review finding a8a8d7ba...)
    // ---------------------------------------------------------------------------------------------

    /// @dev The reported attack, verbatim: an account with no CBRK, no ETH and no approvals pushes the
    /// price to the block's upper band edge with a oneForZero swap of 1 wei. Nothing above the opening
    /// tick holds liquidity, so the pool would slide there exchanging nothing and the next block's
    /// reference would be the pushed price. The hook now refuses the slide as a phantom swap, the price
    /// and the reference are untouched, and buys in the next block are judged against the opening price.
    function test_ratchet_freeEdgePushIsRefusedAndNextBlockBuysStillPass() public {
        initializePool();
        seedOneSided();

        address attacker = makeAddr("attacker");
        vm.deal(attacker, 1 ether); // gas money only; the swap sends none of it
        (, uint256 upper) = hook.allowedBand(initialSqrtPrice);

        vm.prank(attacker);
        (bool ok, bytes memory reason) = address(swapRouter)
            .call(
                abi.encodeCall(
                    PoolSwapTest.swap,
                    (key, SwapParams(false, -1, uint160(upper)), PoolSwapTest.TestSettings(false, false), "")
                )
            );
        assertFalse(ok, "a costless slide to the band edge went through");
        (uint160 ref, uint160 pushed) = decodePhantom(reason);
        assertEq(ref, initialSqrtPrice);
        assertEq(pushed, uint160(upper));
        assertEq(currentSqrtPrice(), initialSqrtPrice, "the refused push moved the price");
        assertEq(hook.refBlock(poolId), 0, "the refused push left a reference");
        assertEq(attacker.balance, 1 ether);
        assertEq(cbrk.balanceOf(attacker), 0);

        // the same push below the band edge, and a slide downward, are phantom too
        vm.prank(attacker);
        (ok, reason) = address(swapRouter)
            .call(
                abi.encodeCall(
                    PoolSwapTest.swap,
                    (
                        key,
                        SwapParams(false, -1, sqrtPriceAtRatio(initialSqrtPrice, 10_100)),
                        PoolSwapTest.TestSettings(false, false),
                        ""
                    )
                )
            );
        assertFalse(ok, "a smaller costless slide went through");
        decodePhantom(reason);

        // next block: buys of every size the band allows pass, judged against the opening price
        vm.roll(vm.getBlockNumber() + 1);
        vm.expectEmit(true, true, true, true, address(hook));
        emit CircuitBreakerHook.ReferenceSet(poolId, vm.getBlockNumber(), initialSqrtPrice);
        swapExactIn(true, 1);
        swapExactIn(true, 0.001 ether);
        BalanceDelta buy = swapExactIn(true, SMALL_FIRST_BUY);
        assertGt(buy.amount1(), 0, "the buy received no CBRK");
        assertEq(hook.refSqrtPrice(poolId), initialSqrtPrice);
    }

    /// @dev What the ratchet would do without the phantom-swap rule, kept as the reference for the
    /// finding: simulate the pushed reference directly and show that from a reference 21% above the
    /// opening price (two pushes) every buy trips, because a buy can never end above the opening price.
    /// This is the arithmetic the rule prevents from becoming reachable for free.
    function test_ratchet_aReferenceAboveTheSeedWouldLockEveryBuy() public view {
        (, uint256 push1) = hook.allowedBand(initialSqrtPrice);
        (, uint256 push2) = hook.allowedBand(uint160(push1));
        // one push: a buy ending exactly at the opening price is still inside the band
        assertTrue(hook.isWithinBand(uint160(push1), initialSqrtPrice));
        // two pushes: the opening price itself is already below the lower edge, so no buy can pass
        assertFalse(hook.isWithinBand(uint160(push2), initialSqrtPrice));
        (uint256 lower2,) = hook.allowedBand(uint160(push2));
        assertGt(lower2, initialSqrtPrice);
    }

    /// @dev The residual the phantom-swap rule does not close, recorded so it is visible rather than
    /// discovered again: an attacker who first parks a dust ETH-only position above the opening tick
    /// gives the empty range a sliver of liquidity, and a sell of dust CBRK through it is a real (tiny)
    /// trade. Its delta is non-zero, so the band alone judges it and the reference can still be walked
    /// upward for the cost of a few wei. README states the launch-owner decision this leaves open
    /// (a two-sided seed, or accepting the exposure).
    function test_ratchet_dustLiquidityVariantIsNotClosedByTheRule() public {
        initializePool();
        seedOneSided();

        address attacker = makeAddr("attacker");
        vm.deal(attacker, 1 ether);
        cbrk.transfer(attacker, 1_000_000_000); // 1e-9 CBRK
        vm.startPrank(attacker);
        cbrk.approve(address(swapRouter), type(uint256).max);
        BalanceDelta parked = lpRouter.modifyLiquidity{value: 1000}(
            key,
            ModifyLiquidityParams(
                LaunchParams.INITIAL_TICK + LaunchParams.TICK_SPACING,
                LaunchParams.INITIAL_TICK + LaunchParams.TICK_SPACING * 200,
                1000,
                bytes32(0)
            ),
            ""
        );
        assertGt(parked.amount0(), -100, "the dust position cost more than 100 wei of ETH");
        assertEq(parked.amount1(), 0);

        (, uint256 upper) = hook.allowedBand(initialSqrtPrice);
        BalanceDelta push = swap(key, false, -int256(uint256(1_000_000_000)), uint160(upper));
        vm.stopPrank();
        assertEq(push.amount0(), 0, "the push took ETH out");
        assertLt(push.amount1(), 0, "the push exchanged nothing; the rule should have caught it");
        assertGt(push.amount1(), -1_000_000_000, "the push consumed the whole dust budget");
        assertEq(currentSqrtPrice(), uint160(upper), "the push did not reach the edge");

        // next block: the reference is the pushed price and a 1 ETH buy trips
        vm.roll(vm.getBlockNumber() + 1);
        try swapRouter.swap{value: SMALL_FIRST_BUY}(
            key,
            SwapParams(true, -int256(SMALL_FIRST_BUY), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        ) {
            revert("the residual is closed; update README and this test");
        } catch (bytes memory reason) {
            (uint160 ref,) = decodeTripped(reason);
            assertEq(ref, uint160(upper), "the pushed price became the reference");
        }
    }

    /// @dev The buy after the first one, in the next block, is judged against the new opening price.
    function test_rehearsal_secondBlockContinuesFromTheNewPrice() public {
        initializePool();
        seedOneSided();
        swapExactIn(true, SMALL_FIRST_BUY);
        uint160 afterFirst = currentSqrtPrice();

        vm.roll(vm.getBlockNumber() + 1);
        vm.expectEmit(true, true, true, true, address(hook));
        emit CircuitBreakerHook.ReferenceSet(poolId, vm.getBlockNumber(), afterFirst);
        swapExactIn(true, SMALL_FIRST_BUY);
        assertEq(hook.refSqrtPrice(poolId), afterFirst);
    }

    function testFuzz_rehearsal_firstBuy_passesIffInsideTheBand(uint256 ethIn) public {
        initializePool();
        seedOneSided();
        ethIn = bound(ethIn, 1, 50 ether);

        try swapRouter.swap{value: ethIn}(
            key,
            SwapParams(true, -int256(ethIn), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        ) {
            assertTrue(hook.isWithinBand(initialSqrtPrice, currentSqrtPrice()), "a passing first buy left the band");
            assertEq(address(manager).balance, ethIn);
        } catch (bytes memory reason) {
            (uint160 ref, uint160 newPrice) = decodeTripped(reason);
            assertEq(ref, initialSqrtPrice);
            assertFalse(hook.isWithinBand(ref, newPrice), "tripped inside the band");
            assertEq(address(manager).balance, 0);
        }
    }
}
