// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
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
    /// a limit inside the band the swap settles at the limit with nothing exchanged.
    function test_rehearsal_sellIntoEthlessPool() public {
        initializePool();
        seedOneSided();

        uint160 far = TickMath.MAX_SQRT_PRICE - 1;
        expectTripped(initialSqrtPrice, far);
        swap(key, false, -int256(1000 ether), far);

        uint160 nearLimit = sqrtPriceAtRatio(initialSqrtPrice, 10_500);
        BalanceDelta d = swap(key, false, -int256(1000 ether), nearLimit);
        assertEq(d.amount0(), 0, "ETH came out of an ETH-less pool");
        assertEq(d.amount1(), 0, "CBRK was taken with nothing given back");
        assertEq(currentSqrtPrice(), nearLimit);
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
