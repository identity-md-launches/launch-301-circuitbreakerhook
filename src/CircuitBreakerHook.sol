// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title CircuitBreakerHook
/// @notice A Uniswap v4 hook that refuses any swap leaving a native-ETH pool's price more than 10% away
/// from the price the pool had before the block's first swap.
///
/// How it works, per pool and per block:
///  - `beforeSwap` of the first swap in a block records the pool's current `sqrtPriceX96` as that block's
///    reference and emits {ReferenceSet}. Later swaps in the same block reuse it.
///  - `afterSwap` reads the post-swap `sqrtPriceX96` and reverts with {Tripped} unless
///    `ref * sqrt(0.9) <= new <= ref * sqrt(1.1)`, i.e. the spot price (sqrtPrice squared) is within
///    -10% / +10% of the reference. The bounds are rounded inward, so the band never exceeds 10%.
///
/// A tripped swap reverts the whole transaction, so it leaves no state and no event. The check also covers
/// a block's first swap: a single trade that would move the price more than 10% cannot execute at all and
/// has to be split across blocks. Liquidity changes and donations never move the price and are not
/// checked. The hook takes no deltas, charges no fee, holds no funds and has no owner, setter, pause,
/// upgrade or sweep. Every number it uses is a source constant.
///
/// Pools whose `currency0` is not native ETH may still point at this hook: they get zero deltas and no
/// other effect (no reference, no event, no check). All state is keyed by `PoolId`.
contract CircuitBreakerHook is IHooks {
    using StateLibrary for IPoolManager;

    /// @notice The PoolManager this hook serves. Set once in the constructor; the only callback caller.
    IPoolManager public immutable POOL_MANAGER;

    /// @notice Largest allowed move of the spot price away from the block reference, in basis points.
    uint256 public constant MAX_MOVE_BPS = 1000;

    /// @notice sqrt(0.9) in Q64.96, rounded UP so the lower sqrt-price bound is never below the true bound.
    /// @dev floor would give ...470; ...471 squared times 10 is the first value >= 9 * 2^192.
    uint256 public constant SQRT_0_9_X96 = 75_162_434_512_514_379_355_924_140_471;

    /// @notice sqrt(1.1) in Q64.96, rounded DOWN so the upper sqrt-price bound is never above the true bound.
    /// @dev ...990 squared times 10 is the last value <= 11 * 2^192.
    uint256 public constant SQRT_1_1_X96 = 83_095_197_869_223_157_896_060_286_990;

    /// @notice The permission bits this hook's address must carry: beforeSwap | afterSwap = 0x00C0.
    uint160 public constant HOOK_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;

    /// @notice Block in which `refSqrtPrice[poolId]` was captured. Zero until the pool's first swap.
    mapping(PoolId poolId => uint256 blockNumber) public refBlock;

    /// @notice The sqrtPriceX96 the pool had before its first swap of `refBlock[poolId]`.
    mapping(PoolId poolId => uint160 sqrtPriceX96) public refSqrtPrice;

    /// @notice Emitted by the first swap of a block in a native-ETH pool, once per pool per block.
    /// @param poolId The pool whose reference was captured.
    /// @param blockNumber The block the reference is valid for.
    /// @param sqrtPriceX96 The pool price before the block's first swap.
    event ReferenceSet(PoolId indexed poolId, uint256 blockNumber, uint160 sqrtPriceX96);

    /// @notice The swap would leave the price outside the +/-10% band around the block reference.
    /// @dev Surfaces from the PoolManager wrapped as `CustomRevert.WrappedError(hook, afterSwap.selector,
    /// abi.encodeWithSelector(Tripped.selector, ref, new), abi.encodeWithSelector(HookCallFailed.selector))`.
    error Tripped(uint160 refSqrtPriceX96, uint160 newSqrtPriceX96);

    /// @notice A callback was invoked by something other than the PoolManager.
    error NotPoolManager();

    /// @notice A callback the hook does not enable was invoked.
    error HookNotImplemented();

    modifier onlyPoolManager() {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        _;
    }

    /// @param poolManager The PoolManager whose pools this hook protects (on Sepolia:
    /// 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543). The only constructor argument.
    /// @dev Reverts with `Hooks.HookAddressNotValid` unless the deployed address carries exactly the bits
    /// {getHookPermissions} declares, so the CREATE2 salt has to be mined for `HOOK_FLAGS`.
    constructor(IPoolManager poolManager) {
        POOL_MANAGER = poolManager;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    // ---------------------------------------------------------------------------------------------
    // Permissions
    // ---------------------------------------------------------------------------------------------

    /// @notice Exactly `beforeSwap` and `afterSwap`. Everything else, including every return-delta
    /// flag, is off: the hook never takes, settles or adjusts an amount.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------------------------------------
    // Enabled callbacks
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    /// @dev Captures the block reference before the pool state changes. Returns zero deltas and no fee
    /// override in every path.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (_isNativePool(key)) {
            PoolId poolId = key.toId();
            if (refBlock[poolId] != block.number) {
                (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(poolId);
                refBlock[poolId] = block.number;
                refSqrtPrice[poolId] = sqrtPriceX96;
                emit ReferenceSet(poolId, block.number, sqrtPriceX96);
            }
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @inheritdoc IHooks
    /// @dev Reads the post-swap price and reverts with {Tripped} when it is outside the band. Returns a
    /// zero unspecified-currency delta in every path.
    function afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        if (_isNativePool(key)) {
            PoolId poolId = key.toId();
            (uint160 newSqrtPriceX96,,,) = POOL_MANAGER.getSlot0(poolId);
            uint160 ref = refSqrtPrice[poolId];
            if (!isWithinBand(ref, newSqrtPriceX96)) revert Tripped(ref, newSqrtPriceX96);
        }
        return (IHooks.afterSwap.selector, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Views for integrators (the site's reference display and pre-check)
    // ---------------------------------------------------------------------------------------------

    /// @notice The sqrt-price band a swap may end in for a given reference.
    /// @dev `lower = ceil(ref * SQRT_0_9_X96 / 2^96)`, `upper = floor(ref * SQRT_1_1_X96 / 2^96)`. Both
    /// roundings and both constants lean inward, so the band is a subset of the true +/-10% band. Computed
    /// with 512-bit `FullMath.mulDiv`; `ref * SQRT_1_1_X96` is up to 2^257 and would overflow plain math.
    /// The results are `uint256` because `upper` can exceed `type(uint160).max` when `ref` is near
    /// `TickMath.MAX_SQRT_PRICE`; no price can ever be above it in that case.
    function allowedBand(uint160 refSqrtPriceX96)
        public
        pure
        returns (uint256 lowerSqrtPriceX96, uint256 upperSqrtPriceX96)
    {
        lowerSqrtPriceX96 = FullMath.mulDivRoundingUp(refSqrtPriceX96, SQRT_0_9_X96, FixedPoint96.Q96);
        upperSqrtPriceX96 = FullMath.mulDiv(refSqrtPriceX96, SQRT_1_1_X96, FixedPoint96.Q96);
    }

    /// @notice True when `newSqrtPriceX96` lies inside {allowedBand} of `refSqrtPriceX96`.
    function isWithinBand(uint160 refSqrtPriceX96, uint160 newSqrtPriceX96) public pure returns (bool) {
        (uint256 lower, uint256 upper) = allowedBand(refSqrtPriceX96);
        return uint256(newSqrtPriceX96) >= lower && uint256(newSqrtPriceX96) <= upper;
    }

    /// @notice The reference the next swap in this block would be judged against.
    /// @return sqrtPriceX96 The stored reference if a swap already happened this block, else the pool's
    /// current price (which is exactly what `beforeSwap` would capture).
    /// @return setThisBlock Whether the reference came from a swap earlier in this block.
    function currentReference(PoolId poolId) public view returns (uint160 sqrtPriceX96, bool setThisBlock) {
        setThisBlock = refBlock[poolId] == block.number;
        if (setThisBlock) {
            sqrtPriceX96 = refSqrtPrice[poolId];
        } else {
            (sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(poolId);
        }
    }

    /// @notice {currentReference} together with its {allowedBand}, in one call.
    function currentBand(PoolId poolId)
        external
        view
        returns (uint160 refSqrtPriceX96, uint256 lowerSqrtPriceX96, uint256 upperSqrtPriceX96, bool setThisBlock)
    {
        (refSqrtPriceX96, setThisBlock) = currentReference(poolId);
        (lowerSqrtPriceX96, upperSqrtPriceX96) = allowedBand(refSqrtPriceX96);
    }

    /// @notice Whether a swap that ends at `newSqrtPriceX96` would trip right now, given this block's
    /// reference for `poolId`. A pure read; the site combines it with a simulated swap's end price.
    function wouldTrip(PoolId poolId, uint160 newSqrtPriceX96) external view returns (bool) {
        (uint160 ref,) = currentReference(poolId);
        return !isWithinBand(ref, newSqrtPriceX96);
    }

    // ---------------------------------------------------------------------------------------------
    // Disabled callbacks: never reached through the PoolManager because their address bits are off.
    // They still refuse every caller other than the PoolManager and then report themselves unimplemented.
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    function beforeInitialize(address, PoolKey calldata, uint160)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view override onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view override onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    // ---------------------------------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------------------------------

    /// @dev The hook only acts on pools whose `currency0` is native ETH (address zero). Because v4 sorts
    /// currencies, native ETH can only ever be `currency0`.
    function _isNativePool(PoolKey calldata key) private pure returns (bool) {
        return Currency.unwrap(key.currency0) == address(0);
    }
}
