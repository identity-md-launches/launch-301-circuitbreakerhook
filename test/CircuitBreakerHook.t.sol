// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {CircuitBreakerHook} from "../src/CircuitBreakerHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {CircuitBreakerFixture} from "./utils/CircuitBreakerFixture.sol";
import {LaunchParams} from "./utils/LaunchParams.sol";

/// @notice Behaviour of the hook on a two-sided ETH/CBRK pool, where the price can be pushed to exact
/// ratios in both directions.
contract CircuitBreakerHookTest is CircuitBreakerFixture {
    /// @dev +/- 6000 ticks around the opening tick: roughly -45% / +82% in price, plenty for a 10% band.
    int24 constant HALF_WIDTH = 6000;
    uint128 constant TWO_SIDED_LIQUIDITY = 1e22;

    function setUp() public override {
        super.setUp();
        initializePool();
        seedTwoSided(
            key, LaunchParams.INITIAL_TICK - HALF_WIDTH, LaunchParams.INITIAL_TICK + HALF_WIDTH, TWO_SIDED_LIQUIDITY
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Permissions and construction
    // ---------------------------------------------------------------------------------------------

    function test_permissions_exactlyBeforeSwapAndAfterSwap() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertFalse(p.beforeInitialize);
        assertFalse(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);

        assertEq(HookFlags.fromPermissions(p), 0x00C0, "flags are not beforeSwap | afterSwap");
        assertEq(hook.HOOK_FLAGS(), 0x00C0);
        assertEq(HookFlags.flagsOf(address(hook)), 0x00C0, "the mined address carries other bits");
        assertEq(address(hook.POOL_MANAGER()), address(manager));
    }

    function test_constructor_rejectsAnAddressWithoutTheFlags() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        assertFalse(
            HookFlags.matches(predicted, (HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP)),
            "test needs a non-matching address"
        );
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new CircuitBreakerHook(manager);
    }

    // ---------------------------------------------------------------------------------------------
    // Band maths
    // ---------------------------------------------------------------------------------------------

    /// @dev The constants are the nearest Q96 integers to sqrt(0.9) and sqrt(1.1) on the inward side.
    function test_constants_areRoundedInward() public view {
        uint256 lo = hook.SQRT_0_9_X96();
        uint256 hi = hook.SQRT_1_1_X96();
        uint256 q192 = FixedPoint96.Q96 * FixedPoint96.Q96;

        // lo is the smallest integer whose square is at least 0.9 * 2^192: rounded up.
        assertGe(lo * lo * 10, 9 * q192, "sqrt(0.9) constant is below the true value");
        assertLt((lo - 1) * (lo - 1) * 10, 9 * q192, "sqrt(0.9) constant is not the tightest ceiling");
        // hi is the largest integer whose square is at most 1.1 * 2^192: rounded down.
        assertLe(hi * hi * 10, 11 * q192, "sqrt(1.1) constant is above the true value");
        assertGt((hi + 1) * (hi + 1) * 10, 11 * q192, "sqrt(1.1) constant is not the tightest floor");
        assertEq(hook.MAX_MOVE_BPS(), 1000);
    }

    function test_allowedBand_atUnitPriceEqualsTheConstants() public view {
        (uint256 lower, uint256 upper) = hook.allowedBand(uint160(FixedPoint96.Q96));
        assertEq(lower, hook.SQRT_0_9_X96());
        assertEq(upper, hook.SQRT_1_1_X96());
        assertTrue(hook.isWithinBand(uint160(FixedPoint96.Q96), uint160(lower)));
        assertTrue(hook.isWithinBand(uint160(FixedPoint96.Q96), uint160(upper)));
        assertFalse(hook.isWithinBand(uint160(FixedPoint96.Q96), uint160(lower - 1)));
        assertFalse(hook.isWithinBand(uint160(FixedPoint96.Q96), uint160(upper + 1)));
    }

    /// @dev For every reference where the squares fit in 256 bits, the band contains the reference and
    /// the spot price at either edge is within 10% of the spot price at the reference.
    function testFuzz_allowedBand_containsRefAndNeverExceedsTenPercent(uint160 ref) public view {
        ref = uint160(bound(ref, TickMath.MIN_SQRT_PRICE, (1 << 126) - 1));
        (uint256 lower, uint256 upper) = hook.allowedBand(ref);
        assertLe(lower, ref);
        assertGe(upper, ref);
        assertGe(lower * lower * 10, uint256(ref) * uint256(ref) * 9, "lower edge is more than 10% below");
        assertLe(upper * upper * 10, uint256(ref) * uint256(ref) * 11, "upper edge is more than 10% above");
        assertTrue(hook.isWithinBand(ref, ref));
    }

    /// @dev No reference in the whole sqrt-price domain makes the band maths revert (512-bit mulDiv).
    function testFuzz_allowedBand_neverOverflows(uint160 ref) public view {
        ref = uint160(bound(ref, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));
        (uint256 lower, uint256 upper) = hook.allowedBand(ref);
        assertLe(lower, ref);
        assertGe(upper, ref);
        assertGt(lower, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Access control
    // ---------------------------------------------------------------------------------------------

    function test_callbacks_refuseCallersOtherThanThePoolManager() public {
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-60, 60, 1 ether, bytes32(0));
        SwapParams memory sp = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        BalanceDelta zero = BalanceDelta.wrap(0);
        address stranger = address(0xBAD);
        vm.startPrank(stranger);

        vm.expectRevert(CircuitBreakerHook.NotPoolManager.selector);
        hook.beforeSwap(stranger, key, sp, "");
        vm.expectRevert(CircuitBreakerHook.NotPoolManager.selector);
        hook.afterSwap(stranger, key, sp, zero, "");
        vm.expectRevert(CircuitBreakerHook.NotPoolManager.selector);
        hook.beforeInitialize(stranger, key, initialSqrtPrice);
        vm.expectRevert(CircuitBreakerHook.NotPoolManager.selector);
        hook.afterInitialize(stranger, key, initialSqrtPrice, 0);
        vm.expectRevert(CircuitBreakerHook.NotPoolManager.selector);
        hook.beforeAddLiquidity(stranger, key, lp, "");
        vm.expectRevert(CircuitBreakerHook.NotPoolManager.selector);
        hook.afterAddLiquidity(stranger, key, lp, zero, zero, "");
        vm.expectRevert(CircuitBreakerHook.NotPoolManager.selector);
        hook.beforeRemoveLiquidity(stranger, key, lp, "");
        vm.expectRevert(CircuitBreakerHook.NotPoolManager.selector);
        hook.afterRemoveLiquidity(stranger, key, lp, zero, zero, "");
        vm.expectRevert(CircuitBreakerHook.NotPoolManager.selector);
        hook.beforeDonate(stranger, key, 1, 1, "");
        vm.expectRevert(CircuitBreakerHook.NotPoolManager.selector);
        hook.afterDonate(stranger, key, 1, 1, "");

        vm.stopPrank();
        assertEq(hook.refBlock(poolId), 0, "a refused call changed state");
    }

    /// @dev Even the PoolManager cannot drive a callback the hook does not enable: they are unreachable
    /// through the address bits and, if reached anyway, report themselves unimplemented.
    function test_disabledCallbacks_revertEvenForThePoolManager() public {
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-60, 60, 1 ether, bytes32(0));
        BalanceDelta zero = BalanceDelta.wrap(0);
        vm.startPrank(address(manager));

        vm.expectRevert(CircuitBreakerHook.HookNotImplemented.selector);
        hook.beforeInitialize(address(this), key, initialSqrtPrice);
        vm.expectRevert(CircuitBreakerHook.HookNotImplemented.selector);
        hook.afterInitialize(address(this), key, initialSqrtPrice, 0);
        vm.expectRevert(CircuitBreakerHook.HookNotImplemented.selector);
        hook.beforeAddLiquidity(address(this), key, lp, "");
        vm.expectRevert(CircuitBreakerHook.HookNotImplemented.selector);
        hook.afterAddLiquidity(address(this), key, lp, zero, zero, "");
        vm.expectRevert(CircuitBreakerHook.HookNotImplemented.selector);
        hook.beforeRemoveLiquidity(address(this), key, lp, "");
        vm.expectRevert(CircuitBreakerHook.HookNotImplemented.selector);
        hook.afterRemoveLiquidity(address(this), key, lp, zero, zero, "");
        vm.expectRevert(CircuitBreakerHook.HookNotImplemented.selector);
        hook.beforeDonate(address(this), key, 1, 1, "");
        vm.expectRevert(CircuitBreakerHook.HookNotImplemented.selector);
        hook.afterDonate(address(this), key, 1, 1, "");

        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------
    // Reference capture
    // ---------------------------------------------------------------------------------------------

    function test_firstSwapInBlock_capturesThePriceBeforeItAndEmits() public {
        uint160 before = currentSqrtPrice();
        assertEq(hook.refBlock(poolId), 0);

        vm.expectEmit(true, true, true, true, address(hook));
        emit CircuitBreakerHook.ReferenceSet(poolId, vm.getBlockNumber(), before);
        swapExactIn(true, 0.01 ether);

        assertEq(hook.refBlock(poolId), vm.getBlockNumber());
        assertEq(hook.refSqrtPrice(poolId), before, "reference is not the pre-swap price");
        assertLt(currentSqrtPrice(), before, "a buy should have moved the price down");
    }

    function test_secondSwapInSameBlock_keepsTheReferenceAndEmitsNothing() public {
        uint160 before = currentSqrtPrice();
        swapExactIn(true, 0.01 ether);

        vm.recordLogs();
        swapExactIn(true, 0.01 ether);
        swapExactIn(false, 1000 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(countReferenceSet(logs), 0, "reference was re-set within the block");
        assertEq(hook.refSqrtPrice(poolId), before);
    }

    function test_newBlock_resetsTheReferenceToTheCurrentPrice() public {
        uint160 ref0 = currentSqrtPrice();
        swapToPrice(key, sqrtPriceAtRatio(ref0, 9100)); // -9% in block N
        assertEq(hook.refSqrtPrice(poolId), ref0);

        vm.roll(vm.getBlockNumber() + 1);
        uint160 ref1 = currentSqrtPrice();
        assertLt(ref1, ref0);

        vm.expectEmit(true, true, true, true, address(hook));
        emit CircuitBreakerHook.ReferenceSet(poolId, vm.getBlockNumber(), ref1);
        swapToPrice(key, sqrtPriceAtRatio(ref1, 9100)); // another -9%, allowed against the new reference

        assertEq(hook.refBlock(poolId), vm.getBlockNumber());
        assertEq(hook.refSqrtPrice(poolId), ref1);
    }

    // ---------------------------------------------------------------------------------------------
    // Swaps in every shape
    // ---------------------------------------------------------------------------------------------

    function test_exactIn_bothDirections() public {
        uint160 ref = currentSqrtPrice();

        BalanceDelta buy = swapExactIn(true, 0.05 ether);
        assertEq(buy.amount0(), -0.05 ether, "exact-in ETH not fully consumed");
        assertGt(buy.amount1(), 0, "no CBRK received");
        assertLt(currentSqrtPrice(), ref);

        BalanceDelta sell = swapExactIn(false, 50_000 ether);
        assertEq(sell.amount1(), -50_000 ether, "exact-in CBRK not fully consumed");
        assertGt(sell.amount0(), 0, "no ETH received");

        assertTrue(hook.isWithinBand(ref, currentSqrtPrice()));
    }

    function test_exactOut_bothDirections() public {
        uint160 ref = currentSqrtPrice();

        BalanceDelta buy = swapExactOut(true, 100_000 ether);
        assertEq(buy.amount1(), 100_000 ether, "exact-out CBRK not delivered");
        assertLt(buy.amount0(), 0, "no ETH paid");

        BalanceDelta sell = swapExactOut(false, 0.02 ether);
        assertEq(sell.amount0(), 0.02 ether, "exact-out ETH not delivered");
        assertLt(sell.amount1(), 0, "no CBRK paid");

        assertTrue(hook.isWithinBand(ref, currentSqrtPrice()));
    }

    function test_dustAmounts_passInEveryShape() public {
        uint160 ref = currentSqrtPrice();
        swapExactIn(true, 1);
        swapExactIn(false, 1);
        swapExactOut(true, 1);
        swapExactOut(false, 1);
        assertEq(hook.refSqrtPrice(poolId), ref);
        assertTrue(hook.isWithinBand(ref, currentSqrtPrice()));
    }

    // ---------------------------------------------------------------------------------------------
    // The band edges: 9.9% passes, 10.1% trips, in both directions
    // ---------------------------------------------------------------------------------------------

    function test_move_9_9pctDown_passes() public {
        uint160 ref = currentSqrtPrice();
        uint160 target = sqrtPriceAtRatio(ref, 9010);
        swapToPrice(key, target);
        assertEq(currentSqrtPrice(), target, "swap did not stop at the limit");
    }

    function test_move_9_9pctUp_passes() public {
        uint160 ref = currentSqrtPrice();
        uint160 target = sqrtPriceAtRatio(ref, 10_990);
        swapToPrice(key, target);
        assertEq(currentSqrtPrice(), target, "swap did not stop at the limit");
    }

    function test_move_10_1pctDown_trips() public {
        uint160 ref = currentSqrtPrice();
        uint160 target = sqrtPriceAtRatio(ref, 8990);
        swapToPriceExpectTripped(key, ref, target);
        assertEq(currentSqrtPrice(), ref, "a tripped swap changed the price");
        assertEq(hook.refBlock(poolId), 0, "a tripped swap left a reference behind");
    }

    function test_move_10_1pctUp_trips() public {
        uint160 ref = currentSqrtPrice();
        uint160 target = sqrtPriceAtRatio(ref, 11_010);
        swapToPriceExpectTripped(key, ref, target);
        assertEq(currentSqrtPrice(), ref, "a tripped swap changed the price");
    }

    /// @dev The edges themselves: the last allowed sqrt price passes, one wei beyond it trips.
    function test_bandEdges_areInclusive() public {
        uint160 ref = currentSqrtPrice();
        (uint256 lower, uint256 upper) = hook.allowedBand(ref);

        swapToPrice(key, uint160(lower));
        assertEq(currentSqrtPrice(), lower);
        swapToPrice(key, uint160(upper));
        assertEq(currentSqrtPrice(), upper);

        swapToPriceExpectTripped(key, ref, uint160(upper + 1));
        swapToPriceExpectTripped(key, ref, uint160(lower - 1));
    }

    // ---------------------------------------------------------------------------------------------
    // Same-block sequences
    // ---------------------------------------------------------------------------------------------

    function test_twoSwapsInOneBlock_thatTogetherPassTenPercent_secondTrips() public {
        uint160 ref = currentSqrtPrice();
        swapToPrice(key, sqrtPriceAtRatio(ref, 9400)); // -6%: fine on its own

        uint160 second = sqrtPriceAtRatio(ref, 8800); // another -6% from the same reference: -12%
        swapToPriceExpectTripped(key, ref, second);
    }

    function test_swapBackInsideTheBand_passes() public {
        uint160 ref = currentSqrtPrice();
        swapToPrice(key, sqrtPriceAtRatio(ref, 9400)); // -6%
        swapToPrice(key, ref); // back to the reference
        swapToPrice(key, sqrtPriceAtRatio(ref, 10_900)); // +9% is still inside the same block's band
        assertEq(hook.refSqrtPrice(poolId), ref);
    }

    /// @dev Griefing, documented in README: whoever pushes the price to the band edge first blocks every
    /// further move in that direction for the rest of the block. Moves back toward the reference stay
    /// open, and the next block starts from wherever the price ended.
    function test_griefing_edgePushBlocksSameDirectionForTheBlock() public {
        uint160 ref = currentSqrtPrice();
        swapToPrice(key, sqrtPriceAtRatio(ref, 9050)); // attacker: -9.5%

        // a victim's ordinary buy would land below -10%
        vm.expectRevert();
        swapExactIn(true, 0.05 ether);

        // but selling (moving back toward the reference) still works
        swapExactIn(false, 1000 ether);

        // and the next block is judged from the new price
        vm.roll(vm.getBlockNumber() + 1);
        swapExactIn(true, 0.05 ether);
        assertEq(hook.refBlock(poolId), vm.getBlockNumber());
    }

    // ---------------------------------------------------------------------------------------------
    // Things the hook never checks
    // ---------------------------------------------------------------------------------------------

    function test_liquidityChangesAndDonations_areNeverChecked() public {
        uint160 ref = currentSqrtPrice();
        (uint256 lower,) = hook.allowedBand(ref);
        swapToPrice(key, uint160(lower)); // sit exactly on the edge

        // add, remove and donate in the same block: none of them consult the hook or move the price
        seedTwoSided(key, LaunchParams.INITIAL_TICK - HALF_WIDTH, LaunchParams.INITIAL_TICK + HALF_WIDTH, 1e20);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams(
                LaunchParams.INITIAL_TICK - HALF_WIDTH, LaunchParams.INITIAL_TICK + HALF_WIDTH, -1e20, bytes32(0)
            ),
            ""
        );
        donateRouter.donate(key, 0, 1000 ether, "");

        assertEq(currentSqrtPrice(), lower, "liquidity or donate moved the price");
        assertEq(hook.refSqrtPrice(poolId), ref);
        assertEq(hook.refBlock(poolId), vm.getBlockNumber());
    }

    function test_poolWhoseCurrency0IsNotEth_getsNoReferenceNoEventNoCheck() public {
        MockERC20 a = new MockERC20("A", "A", 1e30);
        MockERC20 b = new MockERC20("B", "B", 1e30);
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);
        t0.approve(address(lpRouter), type(uint256).max);
        t1.approve(address(lpRouter), type(uint256).max);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);

        PoolKey memory erc20Key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        PoolId erc20Id = erc20Key.toId();
        uint160 unit = uint160(FixedPoint96.Q96);
        manager.initialize(erc20Key, unit);
        seedTwoSided(erc20Key, -6000, 6000, 1e22);

        vm.recordLogs();
        swapToPrice(erc20Key, sqrtPriceAtRatio(unit, 5000)); // -50%, would trip an ETH pool
        assertEq(countReferenceSet(vm.getRecordedLogs()), 0, "hook emitted for a non-ETH pool");
        assertEq(currentSqrtPrice(erc20Key), sqrtPriceAtRatio(unit, 5000));

        assertEq(hook.refBlock(erc20Id), 0);
        assertEq(hook.refSqrtPrice(erc20Id), 0);
        (uint160 refNow, bool setThisBlock) = hook.currentReference(erc20Id);
        assertEq(refNow, currentSqrtPrice(erc20Key));
        assertFalse(setThisBlock);
    }

    function test_stateIsKeyedByPoolId() public {
        // a second native-ETH pool on the same hook: 0.05% tier, spacing 10
        PoolKey memory other = PoolKey({
            currency0: ETH,
            currency1: Currency.wrap(address(cbrk)),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });
        PoolId otherId = other.toId();
        manager.initialize(other, initialSqrtPrice);
        seedTwoSided(
            other, LaunchParams.INITIAL_TICK - HALF_WIDTH, LaunchParams.INITIAL_TICK + HALF_WIDTH, TWO_SIDED_LIQUIDITY
        );

        uint160 ref = currentSqrtPrice();
        swapToPrice(key, sqrtPriceAtRatio(ref, 9400)); // launch pool: -6%
        assertEq(hook.refBlock(poolId), vm.getBlockNumber());
        assertEq(hook.refBlock(otherId), 0, "the other pool picked up a reference");

        // the other pool has its own reference and its own budget
        swapToPrice(other, sqrtPriceAtRatio(initialSqrtPrice, 9100));
        assertEq(hook.refSqrtPrice(otherId), initialSqrtPrice);

        // and the launch pool's budget is unaffected by the other pool's move
        uint160 second = sqrtPriceAtRatio(ref, 8800);
        swapToPriceExpectTripped(key, ref, second);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    function test_views_beforeAndAfterTheBlocksFirstSwap() public {
        uint160 price = currentSqrtPrice();
        (uint160 ref, bool setThisBlock) = hook.currentReference(poolId);
        assertEq(ref, price);
        assertFalse(setThisBlock);

        (uint160 bandRef, uint256 lower, uint256 upper, bool bandSet) = hook.currentBand(poolId);
        (uint256 expLower, uint256 expUpper) = hook.allowedBand(price);
        assertEq(bandRef, price);
        assertEq(lower, expLower);
        assertEq(upper, expUpper);
        assertFalse(bandSet);
        assertFalse(hook.wouldTrip(poolId, uint160(lower)));
        assertTrue(hook.wouldTrip(poolId, uint160(lower - 1)));

        swapExactIn(true, 0.05 ether);
        (ref, setThisBlock) = hook.currentReference(poolId);
        assertEq(ref, price, "reference should be the pre-swap price");
        assertTrue(setThisBlock);
        assertLt(currentSqrtPrice(), price);
        assertFalse(hook.wouldTrip(poolId, currentSqrtPrice()));
        assertTrue(hook.wouldTrip(poolId, sqrtPriceAtRatio(price, 8900)));

        vm.roll(vm.getBlockNumber() + 1);
        (ref, setThisBlock) = hook.currentReference(poolId);
        assertEq(ref, currentSqrtPrice(), "a new block should fall back to the live price");
        assertFalse(setThisBlock);
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz: any buy or sell either lands inside the band or trips with a truthful reason
    // ---------------------------------------------------------------------------------------------

    function testFuzz_exactInBuy_passesIffItStaysInsideTheBand(uint256 ethIn) public {
        ethIn = bound(ethIn, 1, 3 ether);
        uint160 ref = currentSqrtPrice();
        try swapRouter.swap{value: ethIn}(
            key,
            SwapParams(true, -int256(ethIn), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        ) {
            assertTrue(hook.isWithinBand(ref, currentSqrtPrice()), "a passing swap ended outside the band");
            assertEq(hook.refSqrtPrice(poolId), ref);
        } catch (bytes memory reason) {
            (uint160 reportedRef, uint160 reportedNew) = decodeTripped(reason);
            assertEq(reportedRef, ref);
            assertFalse(hook.isWithinBand(ref, reportedNew), "tripped although inside the band");
            assertEq(currentSqrtPrice(), ref, "a tripped swap moved the price");
            assertEq(hook.refBlock(poolId), 0, "a tripped swap persisted state");
        }
    }

    function testFuzz_exactInSell_passesIffItStaysInsideTheBand(uint256 cbrkIn) public {
        cbrkIn = bound(cbrkIn, 1, 3_000_000 ether);
        uint160 ref = currentSqrtPrice();
        try swapRouter.swap(
            key,
            SwapParams(false, -int256(cbrkIn), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        ) {
            assertTrue(hook.isWithinBand(ref, currentSqrtPrice()), "a passing swap ended outside the band");
        } catch (bytes memory reason) {
            (uint160 reportedRef, uint160 reportedNew) = decodeTripped(reason);
            assertEq(reportedRef, ref);
            assertFalse(hook.isWithinBand(ref, reportedNew), "tripped although inside the band");
            assertEq(currentSqrtPrice(), ref);
        }
    }

    function testFuzz_exactOut_passesIffItStaysInsideTheBand(uint256 cbrkOut, bool buy) public {
        uint160 ref = currentSqrtPrice();
        int256 amountSpecified = buy ? int256(bound(cbrkOut, 1, 2_000_000 ether)) : int256(bound(cbrkOut, 1, 1 ether));
        try swapRouter.swap{value: buy ? ETH_BUDGET : 0}(
            key, SwapParams(buy, amountSpecified, limitFor(buy)), PoolSwapTest.TestSettings(false, false), ""
        ) {
            assertTrue(hook.isWithinBand(ref, currentSqrtPrice()), "a passing swap ended outside the band");
        } catch (bytes memory reason) {
            (uint160 reportedRef, uint160 reportedNew) = decodeTripped(reason);
            assertEq(reportedRef, ref);
            assertFalse(hook.isWithinBand(ref, reportedNew), "tripped although inside the band");
        }
    }
}
