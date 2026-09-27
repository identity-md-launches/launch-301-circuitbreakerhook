// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";

import {CBRK} from "../../src/CBRK.sol";
import {CircuitBreakerHook} from "../../src/CircuitBreakerHook.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {LaunchParams} from "./LaunchParams.sol";

/// @notice Shared fixture: a real v4 `PoolManager`, the v4-core test routers, the CBRK token and the hook
/// deployed with CREATE2 at an address mined for its two permission bits, exactly as the factory does.
abstract contract CircuitBreakerFixture is Test {
    using StateLibrary for IPoolManager;
    using StateLibrary for PoolManager;

    /// @dev Native ETH is address zero; v4 sorts currencies, so it is always `currency0`.
    Currency internal constant ETH = Currency.wrap(address(0));

    /// @dev How much ETH a native-input swap is handed. `PoolSwapTest` refunds whatever the pool did not take.
    uint256 internal constant ETH_BUDGET = 10_000 ether;

    PoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;
    PoolDonateTest internal donateRouter;

    CBRK internal cbrk;
    CircuitBreakerHook internal hook;

    /// @dev The launch pool: native ETH / CBRK, 0.30%, tick spacing 60, this hook.
    PoolKey internal key;
    PoolId internal poolId;
    uint160 internal initialSqrtPrice;

    receive() external payable {}

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        donateRouter = new PoolDonateTest(manager);

        cbrk = new CBRK();
        hook = deployHook(manager);

        key = PoolKey({
            currency0: ETH,
            currency1: Currency.wrap(address(cbrk)),
            fee: LaunchParams.FEE,
            tickSpacing: LaunchParams.TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();
        initialSqrtPrice = LaunchParams.initialSqrtPriceX96();

        cbrk.approve(address(swapRouter), type(uint256).max);
        cbrk.approve(address(lpRouter), type(uint256).max);
        cbrk.approve(address(donateRouter), type(uint256).max);
        vm.deal(address(this), 1_000_000 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // Deployment
    // ---------------------------------------------------------------------------------------------

    /// @dev Mines a salt for the hook's flags and deploys with CREATE2 from this contract. Mirrors what
    /// the factory (and the protected floor test) do with the attested creation code.
    function deployHook(IPoolManager poolManager) internal returns (CircuitBreakerHook deployed) {
        bytes memory creationCode = abi.encodePacked(type(CircuitBreakerHook).creationCode, abi.encode(poolManager));
        (address predicted, bytes32 salt) =
            HookFlags.mine(address(this), (HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP), creationCode, 1_000_000);
        deployed = new CircuitBreakerHook{salt: salt}(poolManager);
        assertEq(address(deployed), predicted, "hook did not land on the mined address");
    }

    // ---------------------------------------------------------------------------------------------
    // Pool setup
    // ---------------------------------------------------------------------------------------------

    /// @dev The factory step: open the pool at the manifest price.
    function initializePool() internal returns (int24 tick) {
        tick = manager.initialize(key, initialSqrtPrice);
    }

    /// @dev The factory step: one-sided CBRK liquidity in [SEED_TICK_LOWER, INITIAL_TICK]. The range sits
    /// entirely at or below the current tick, so the pool takes only CBRK and no ETH.
    function seedOneSided() internal returns (BalanceDelta delta, uint128 liquidity) {
        liquidity = LaunchParams.seedLiquidity();
        delta = lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: LaunchParams.SEED_TICK_LOWER,
                tickUpper: LaunchParams.INITIAL_TICK,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
    }

    /// @dev Two-sided liquidity around the current price, for tests that need to move the price in both
    /// directions by exact ratios. Sends exactly the ETH the pool will ask for.
    function seedTwoSided(PoolKey memory k, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        returns (BalanceDelta delta)
    {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(k.toId());
        uint256 ethNeeded = 0;
        if (Currency.unwrap(k.currency0) == address(0)) {
            // v4's signed overload returns the caller's delta: negative for an add, so negate it.
            int256 amount0 =
                SqrtPriceMath.getAmount0Delta(sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickUpper), int128(liquidity));
            ethNeeded = uint256(-amount0);
        }
        delta = lpRouter.modifyLiquidity{value: ethNeeded}(
            k,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liquidity)), salt: bytes32(0)
            }),
            ""
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Swaps
    // ---------------------------------------------------------------------------------------------

    function swap(PoolKey memory k, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        internal
        returns (BalanceDelta delta)
    {
        bool nativeIn = zeroForOne && Currency.unwrap(k.currency0) == address(0);
        delta = swapRouter.swap{value: nativeIn ? ETH_BUDGET : 0}(
            k,
            SwapParams({
                zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev Exact-in swap with no meaningful price limit.
    function swapExactIn(bool zeroForOne, uint256 amountIn) internal returns (BalanceDelta) {
        return swap(key, zeroForOne, -int256(amountIn), limitFor(zeroForOne));
    }

    /// @dev Exact-out swap with no meaningful price limit.
    function swapExactOut(bool zeroForOne, uint256 amountOut) internal returns (BalanceDelta) {
        return swap(key, zeroForOne, int256(amountOut), limitFor(zeroForOne));
    }

    /// @dev Pushes the pool price to exactly `sqrtPriceLimitX96` (a huge exact-in amount stops at the
    /// limit; the router only settles what the pool consumed).
    function swapToPrice(PoolKey memory k, uint160 sqrtPriceLimitX96) internal returns (BalanceDelta) {
        (uint160 current,,,) = manager.getSlot0(k.toId());
        bool zeroForOne = sqrtPriceLimitX96 < current;
        return swap(k, zeroForOne, -int256(uint256(type(uint96).max)), sqrtPriceLimitX96);
    }

    /// @dev `swapToPrice` that must trip. Reads the current price before arming `expectRevert`, so the
    /// expectation attaches to the router call and not to the price read.
    function swapToPriceExpectTripped(PoolKey memory k, uint160 ref, uint160 sqrtPriceLimitX96) internal {
        (uint160 current,,,) = manager.getSlot0(k.toId());
        bool zeroForOne = sqrtPriceLimitX96 < current;
        expectTripped(ref, sqrtPriceLimitX96);
        swap(k, zeroForOne, -int256(uint256(type(uint96).max)), sqrtPriceLimitX96);
    }

    function limitFor(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    // ---------------------------------------------------------------------------------------------
    // Price helpers
    // ---------------------------------------------------------------------------------------------

    function currentSqrtPrice(PoolKey memory k) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = manager.getSlot0(k.toId());
    }

    function currentSqrtPrice() internal view returns (uint160) {
        return currentSqrtPrice(key);
    }

    /// @dev The sqrt price at which the spot price equals `ratioBps / 10_000` times the spot price at
    /// `ref`. Exact integer sqrt; valid for `ref < 2^127`, which covers every price in these tests.
    function sqrtPriceAtRatio(uint160 ref, uint256 ratioBps) internal pure returns (uint160) {
        uint256 priceScaled = FullMath.mulDiv(uint256(ref) * uint256(ref), ratioBps, 10_000);
        return uint160(Math.sqrt(priceScaled));
    }

    // ---------------------------------------------------------------------------------------------
    // Revert helpers
    // ---------------------------------------------------------------------------------------------

    /// @dev The exact bytes the PoolManager surfaces when `afterSwap` reverts with `Tripped`.
    function trippedRevert(uint160 ref, uint160 newSqrtPrice) internal view returns (bytes memory) {
        return afterSwapRevert(CircuitBreakerHook.Tripped.selector, ref, newSqrtPrice);
    }

    /// @dev The exact bytes the PoolManager surfaces when `afterSwap` reverts with `PhantomSwap`.
    function phantomRevert(uint160 ref, uint160 newSqrtPrice) internal view returns (bytes memory) {
        return afterSwapRevert(CircuitBreakerHook.PhantomSwap.selector, ref, newSqrtPrice);
    }

    function afterSwapRevert(bytes4 errorSelector, uint160 ref, uint160 newSqrtPrice)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.afterSwap.selector,
            abi.encodeWithSelector(errorSelector, ref, newSqrtPrice),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function expectTripped(uint160 ref, uint160 newSqrtPrice) internal {
        vm.expectRevert(trippedRevert(ref, newSqrtPrice));
    }

    function expectPhantom(uint160 ref, uint160 newSqrtPrice) internal {
        vm.expectRevert(phantomRevert(ref, newSqrtPrice));
    }

    /// @dev Decodes a caught revert and asserts it is a `Tripped` from this hook. Returns its arguments.
    function decodeTripped(bytes memory reason) internal view returns (uint160 ref, uint160 newSqrtPrice) {
        return decodeAfterSwapError(reason, CircuitBreakerHook.Tripped.selector);
    }

    /// @dev Decodes a caught revert and asserts it is a `PhantomSwap` from this hook. Returns its arguments.
    function decodePhantom(bytes memory reason) internal view returns (uint160 ref, uint160 newSqrtPrice) {
        return decodeAfterSwapError(reason, CircuitBreakerHook.PhantomSwap.selector);
    }

    function decodeAfterSwapError(bytes memory reason, bytes4 errorSelector)
        internal
        view
        returns (uint160 ref, uint160 newSqrtPrice)
    {
        assertEq(bytes4(reason), CustomRevert.WrappedError.selector, "not a wrapped hook error");
        (address target, bytes4 selector, bytes memory inner, bytes memory details) =
            abi.decode(slice4(reason), (address, bytes4, bytes, bytes));
        assertEq(target, address(hook), "wrapped error is not from the hook");
        assertEq(selector, IHooks.afterSwap.selector, "wrapped error is not from afterSwap");
        assertEq(details, abi.encodeWithSelector(Hooks.HookCallFailed.selector), "unexpected details");
        assertEq(bytes4(inner), errorSelector, "inner error is not the expected one");
        (ref, newSqrtPrice) = abi.decode(slice4(inner), (uint160, uint160));
    }

    /// @dev Drops the 4-byte selector.
    function slice4(bytes memory data) internal pure returns (bytes memory out) {
        out = new bytes(data.length - 4);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = data[i + 4];
        }
    }

    /// @dev Number of `ReferenceSet` logs emitted by the hook among the recorded logs.
    function countReferenceSet(Vm.Log[] memory logs) internal view returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == CircuitBreakerHook.ReferenceSet.selector) n++;
        }
    }
}
