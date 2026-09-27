// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {CBRK} from "../../src/CBRK.sol";
import {CircuitBreakerHook} from "../../src/CircuitBreakerHook.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {LaunchParams} from "../utils/LaunchParams.sol";

/// @dev No source bytecode is embedded in these test contracts. All deployments load the compiled
/// artifacts, keeping the measurement harness itself below EIP-170. No fork or network is needed.
abstract contract GasFixture is Test {
    using StateLibrary for PoolManager;

    PoolManager internal manager;
    PoolSwapTest internal router;
    PoolModifyLiquidityTest internal liquidityRouter;
    CBRK internal token;
    CircuitBreakerHook internal hook;
    PoolKey internal hooked;
    PoolKey internal bare;

    receive() external payable {}

    function setupPools(bool prime, bool nextBlock) internal {
        vm.roll(100);
        manager = PoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        router = PoolSwapTest(payable(deployCode("PoolSwapTest.sol:PoolSwapTest", abi.encode(manager))));
        liquidityRouter = PoolModifyLiquidityTest(
            payable(deployCode("PoolModifyLiquidityTest.sol:PoolModifyLiquidityTest", abi.encode(manager)))
        );
        token = CBRK(deployCode("CBRK.sol:CBRK"));
        bytes memory initCode =
            abi.encodePacked(vm.getCode("CircuitBreakerHook.sol:CircuitBreakerHook"), abi.encode(manager));
        (address predicted, bytes32 salt) = HookFlags.mine(address(this), 0x00C0, initCode, 1_000_000);
        address deployed;
        assembly ("memory-safe") {
            deployed := create2(0, add(initCode, 32), mload(initCode), salt)
        }
        assertEq(deployed, predicted);
        hook = CircuitBreakerHook(deployed);
        hooked = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(deployed));
        bare = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(0)));
        token.approve(address(router), type(uint256).max);
        token.approve(address(liquidityRouter), type(uint256).max);
        vm.deal(address(this), 100 ether);
        seed(hooked);
        seed(bare);
        // Preparation belongs in setUp: its storage becomes the original state of each test call.
        // Merely vm.roll/cool after a swap inside a test would leave SSTORE slots dirty.
        if (prime) {
            trade(hooked, true, -int256(0.1 ether));
            trade(bare, true, -int256(0.1 ether));
        }
        if (nextBlock) vm.roll(101);
        (uint160 a,,,) = manager.getSlot0(hooked.toId());
        (uint160 b,,,) = manager.getSlot0(bare.toId());
        assertEq(a, b, "benchmark pools must have identical starting prices");
        assertEq(manager.getLiquidity(hooked.toId()), manager.getLiquidity(bare.toId()));
    }

    function seed(PoolKey memory key) internal {
        manager.initialize(key, LaunchParams.initialSqrtPriceX96());
        liquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams(
                LaunchParams.SEED_TICK_LOWER,
                LaunchParams.INITIAL_TICK,
                int256(uint256(LaunchParams.seedLiquidity())),
                bytes32(0)
            ),
            ""
        );
    }

    function trade(PoolKey memory key, bool buy, int256 amount) internal returns (BalanceDelta) {
        return router.swap{value: buy ? 1 ether : 0}(
            key,
            SwapParams(buy, amount, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function coolPool() internal {
        vm.cool(address(manager));
        vm.cool(address(router));
        vm.cool(address(token));
        vm.cool(address(hook));
    }

    /// @dev Callee execution gas, before refunds. No test assertions, setup, transaction intrinsic
    /// gas, or outer CALL overhead is included. Includes router, unlock, callbacks and settlement.
    function measureSwap(bool withHook, bool buy, bool exactOut) internal {
        PoolKey memory key = withHook ? hooked : bare;
        uint160 oldRef = hook.refSqrtPrice(hooked.toId());
        uint256 oldBlock = hook.refBlock(hooked.toId());
        (uint160 beforePrice,,,) = manager.getSlot0(key.toId());
        uint256 amount = buy == exactOut ? 10_000 ether : 0.01 ether;
        int256 specified = exactOut ? int256(amount) : -int256(amount);
        uint256 ethBefore = address(this).balance;
        uint256 tokenBefore = token.balanceOf(address(this));
        coolPool();
        vm.recordLogs();
        BalanceDelta delta = trade(key, buy, specified);
        uint256 used = vm.lastCallGas().gasTotalUsed;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        emit log_named_uint("swap execution gas", used);
        assertGt(used, 0);
        if (buy) {
            assertLt(delta.amount0(), 0);
            assertGt(delta.amount1(), 0);
            assertEq(ethBefore - address(this).balance, uint256(uint128(-delta.amount0())));
            assertEq(token.balanceOf(address(this)) - tokenBefore, uint256(uint128(delta.amount1())));
        } else {
            assertGt(delta.amount0(), 0);
            assertLt(delta.amount1(), 0);
            assertEq(address(this).balance - ethBefore, uint256(uint128(delta.amount0())));
            assertEq(tokenBefore - token.balanceOf(address(this)), uint256(uint128(-delta.amount1())));
        }
        int128 specifiedDelta = buy == exactOut ? delta.amount1() : delta.amount0();
        assertEq(int256(specifiedDelta), specified, "entire requested amount must trade");
        assertEq(address(router).balance, 0, "router must refund unused ETH");
        uint256 references;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == CircuitBreakerHook.ReferenceSet.selector) {
                ++references;
            }
        }
        if (withHook) {
            bool first = oldBlock != vm.getBlockNumber();
            assertEq(references, first ? 1 : 0);
            assertEq(hook.refBlock(key.toId()), vm.getBlockNumber());
            assertEq(hook.refSqrtPrice(key.toId()), first ? beforePrice : oldRef);
            (uint160 afterPrice,,,) = manager.getSlot0(key.toId());
            assertTrue(hook.isWithinBand(hook.refSqrtPrice(key.toId()), afterPrice));
        } else {
            assertEq(references, 0);
            assertEq(hook.refBlock(hooked.toId()), oldBlock);
            assertEq(hook.refSqrtPrice(hooked.toId()), oldRef);
        }
    }

    function measureCall(string memory label, address target, bytes memory data, address caller)
        external
        returns (bytes memory result)
    {
        vm.cool(target);
        vm.cool(address(manager));
        vm.prank(caller);
        (bool ok, bytes memory returned) = target.call(data);
        uint256 used = vm.lastCallGas().gasTotalUsed;
        assertTrue(ok, label);
        emit log_named_uint(label, used);
        return returned;
    }

    /// @dev Same measurement for a path that is expected to revert with exactly `expectedReason`.
    function measureRevert(
        string memory label,
        address target,
        bytes memory data,
        address caller,
        bytes memory expectedReason
    ) external {
        vm.cool(target);
        vm.cool(address(manager));
        vm.prank(caller);
        (bool ok, bytes memory returned) = target.call(data);
        uint256 used = vm.lastCallGas().gasTotalUsed;
        assertFalse(ok, label);
        assertEq(returned, expectedReason, label);
        emit log_named_uint(label, used);
    }

    /// @dev The gas a swapper burns on a swap the hook refuses: the block's first buy, sized well past the
    /// 10% band on the launch seed. Everything the PoolManager did is unwound, so the only thing that
    /// survives is the gas bill. Cost is comparable to the passing swap because the revert happens at the
    /// very end, after the full swap and the hook's `getSlot0` read.
    function measureTrippedSwap() internal {
        uint160 ref = hook.refSqrtPrice(hooked.toId());
        uint256 oldBlock = hook.refBlock(hooked.toId());
        (uint160 before,,,) = manager.getSlot0(hooked.toId());
        uint256 ethIn = 20 ether;
        bytes memory data = abi.encodeCall(
            router.swap,
            (
                hooked,
                SwapParams(true, -int256(ethIn), TickMath.MIN_SQRT_PRICE + 1),
                PoolSwapTest.TestSettings(false, false),
                ""
            )
        );
        coolPool();
        (bool ok, bytes memory reason) = address(router).call{value: ethIn}(data);
        uint256 used = vm.lastCallGas().gasTotalUsed;
        assertFalse(ok, "an oversized first buy must trip");
        assertEq(bytes4(reason), CustomRevert.WrappedError.selector);
        (address at, bytes4 selector, bytes memory inner,) =
            abi.decode(slice(reason, 4), (address, bytes4, bytes, bytes));
        assertEq(at, address(hook));
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(bytes4(inner), CircuitBreakerHook.Tripped.selector);
        emit log_named_uint("tripped swap execution gas", used);
        (uint160 afterPrice,,,) = manager.getSlot0(hooked.toId());
        assertEq(afterPrice, before, "a tripped swap leaves the pool untouched");
        assertEq(hook.refBlock(hooked.toId()), oldBlock, "a tripped swap leaves no reference");
        assertEq(hook.refSqrtPrice(hooked.toId()), ref);
        assertEq(address(router).balance, 0);
    }

    function slice(bytes memory data, uint256 start) internal pure returns (bytes memory out) {
        out = new bytes(data.length - start);
        for (uint256 i; i < out.length; ++i) {
            out[i] = data[start + i];
        }
    }
}
