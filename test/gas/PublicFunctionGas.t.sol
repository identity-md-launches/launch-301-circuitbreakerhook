// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GasFixture} from "./GasFixture.sol";
import {CBRK} from "../../src/CBRK.sol";
import {CircuitBreakerHook} from "../../src/CircuitBreakerHook.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LaunchParams} from "../utils/LaunchParams.sol";

contract GasTokenFunctionsTest is GasFixture {
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);

    function setUp() public {
        token = CBRK(deployCode("CBRK.sol:CBRK"));
        assertTrue(token.transfer(ALICE, 10 ether));
        assertTrue(token.approve(ALICE, 5 ether));
    }

    function check(string memory label, bytes memory data, bytes memory expected) internal {
        assertEq(this.measureCall(label, address(token), data, address(this)), expected);
    }

    function test_gas_CBRK_name() public {
        check("CBRK.name", abi.encodeWithSignature("name()"), abi.encode("Breaker"));
    }

    function test_gas_CBRK_symbol() public {
        check("CBRK.symbol", abi.encodeWithSignature("symbol()"), abi.encode("CBRK"));
    }

    function test_gas_CBRK_decimals() public {
        check("CBRK.decimals", abi.encodeWithSignature("decimals()"), abi.encode(uint256(18)));
    }

    function test_gas_CBRK_totalSupply() public {
        check("CBRK.totalSupply", abi.encodeWithSignature("totalSupply()"), abi.encode(uint256(1_000_000_000 ether)));
    }

    function test_gas_CBRK_TOTAL_SUPPLY() public {
        check("CBRK.TOTAL_SUPPLY", abi.encodeWithSignature("TOTAL_SUPPLY()"), abi.encode(uint256(1_000_000_000 ether)));
    }

    function test_gas_CBRK_balanceOf() public {
        check("CBRK.balanceOf", abi.encodeWithSignature("balanceOf(address)", ALICE), abi.encode(uint256(10 ether)));
    }

    function test_gas_CBRK_allowance() public {
        check(
            "CBRK.allowance",
            abi.encodeWithSignature("allowance(address,address)", address(this), ALICE),
            abi.encode(uint256(5 ether))
        );
    }

    function test_gas_CBRK_approve_new() public {
        check("CBRK.approve.new", abi.encodeWithSignature("approve(address,uint256)", BOB, 1 ether), abi.encode(true));
        assertEq(token.allowance(address(this), BOB), 1 ether);
    }

    function test_gas_CBRK_approve_overwrite() public {
        check(
            "CBRK.approve.overwrite",
            abi.encodeWithSignature("approve(address,uint256)", ALICE, 1 ether),
            abi.encode(true)
        );
        assertEq(token.allowance(address(this), ALICE), 1 ether);
    }

    function test_gas_CBRK_transfer_newHolder() public {
        check(
            "CBRK.transfer.newHolder",
            abi.encodeWithSignature("transfer(address,uint256)", BOB, 1 ether),
            abi.encode(true)
        );
        assertEq(token.balanceOf(BOB), 1 ether);
    }

    function test_gas_CBRK_transfer_existingHolder() public {
        check(
            "CBRK.transfer.existingHolder",
            abi.encodeWithSignature("transfer(address,uint256)", ALICE, 1 ether),
            abi.encode(true)
        );
        assertEq(token.balanceOf(ALICE), 11 ether);
    }

    function test_gas_CBRK_transferFrom() public {
        bytes memory result = this.measureCall(
            "CBRK.transferFrom.finiteAllowance.newHolder",
            address(token),
            abi.encodeWithSignature("transferFrom(address,address,uint256)", address(this), BOB, 1 ether),
            ALICE
        );
        assertEq(result, abi.encode(true));
        assertEq(token.balanceOf(BOB), 1 ether);
        assertEq(token.allowance(address(this), ALICE), 4 ether);
    }
}

abstract contract GasHookViews is GasFixture {
    function test_gas_hook_currentReference() public {
        bytes memory result = this.measureCall(
            "Hook.currentReference",
            address(hook),
            abi.encodeCall(hook.currentReference, (hooked.toId())),
            address(this)
        );
        (uint160 ref, bool stored) = abi.decode(result, (uint160, bool));
        assertEq(stored, hook.refBlock(hooked.toId()) == vm.getBlockNumber());
        assertEq(ref, stored ? hook.refSqrtPrice(hooked.toId()) : currentPrice());
    }

    function test_gas_hook_currentBand() public {
        bytes memory result = this.measureCall(
            "Hook.currentBand", address(hook), abi.encodeCall(hook.currentBand, (hooked.toId())), address(this)
        );
        (uint160 ref, uint256 lower, uint256 upper, bool stored) = abi.decode(result, (uint160, uint256, uint256, bool));
        (uint256 expectedLower, uint256 expectedUpper) = hook.allowedBand(ref);
        assertEq(lower, expectedLower);
        assertEq(upper, expectedUpper);
        assertEq(stored, hook.refBlock(hooked.toId()) == vm.getBlockNumber());
    }

    function test_gas_hook_wouldTrip() public {
        uint160 price = currentPrice();
        assertEq(
            this.measureCall(
                "Hook.wouldTrip", address(hook), abi.encodeCall(hook.wouldTrip, (hooked.toId(), price)), address(this)
            ),
            abi.encode(false)
        );
    }

    function currentPrice() internal view returns (uint160 price) {
        (price,,,) = StateLibrary.getSlot0(IPoolManager(address(manager)), hooked.toId());
    }
}

contract GasHookStoredViewsTest is GasHookViews {
    function setUp() public {
        setupPools(true, false);
    }

    function test_gas_hook_beforeSwap_laterInBlock() public {
        uint160 storedRef = hook.refSqrtPrice(hooked.toId());
        bytes memory result = this.measureCall(
            "Hook.beforeSwap.laterInBlock",
            address(hook),
            abi.encodeCall(hook.beforeSwap, (address(router), hooked, SwapParams(true, -1, 1), bytes(""))),
            address(manager)
        );
        assertEq(result, abi.encode(IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), uint24(0)));
        assertEq(hook.refSqrtPrice(hooked.toId()), storedRef);
    }
}

contract GasHookFunctionsTest is GasHookViews {
    function setUp() public {
        setupPools(true, true);
    }

    function check(string memory label, bytes memory data, bytes memory expected) internal {
        assertEq(this.measureCall(label, address(hook), data, address(this)), expected);
    }

    function test_gas_hook_POOL_MANAGER() public {
        check("Hook.POOL_MANAGER", abi.encodeWithSignature("POOL_MANAGER()"), abi.encode(manager));
    }

    function test_gas_hook_MAX_MOVE_BPS() public {
        check("Hook.MAX_MOVE_BPS", abi.encodeWithSignature("MAX_MOVE_BPS()"), abi.encode(uint256(1000)));
    }

    function test_gas_hook_SQRT_0_9_X96() public {
        check(
            "Hook.SQRT_0_9_X96",
            abi.encodeWithSignature("SQRT_0_9_X96()"),
            abi.encode(uint256(75_162_434_512_514_379_355_924_140_471))
        );
    }

    function test_gas_hook_SQRT_1_1_X96() public {
        check(
            "Hook.SQRT_1_1_X96",
            abi.encodeWithSignature("SQRT_1_1_X96()"),
            abi.encode(uint256(83_095_197_869_223_157_896_060_286_990))
        );
    }

    function test_gas_hook_HOOK_FLAGS() public {
        check("Hook.HOOK_FLAGS", abi.encodeWithSignature("HOOK_FLAGS()"), abi.encode(uint160(0xC0)));
    }

    function test_gas_hook_refBlock() public {
        check("Hook.refBlock", abi.encodeCall(hook.refBlock, (hooked.toId())), abi.encode(uint256(100)));
    }

    function test_gas_hook_refSqrtPrice() public {
        check(
            "Hook.refSqrtPrice",
            abi.encodeCall(hook.refSqrtPrice, (hooked.toId())),
            abi.encode(LaunchParams.initialSqrtPriceX96())
        );
    }

    function test_gas_hook_getHookPermissions() public {
        Hooks.Permissions memory p = abi.decode(
            this.measureCall(
                "Hook.getHookPermissions", address(hook), abi.encodeCall(hook.getHookPermissions, ()), address(this)
            ),
            (Hooks.Permissions)
        );
        assertEq(HookFlags.fromPermissions(p), 0xC0);
    }

    function test_gas_hook_allowedBand() public {
        uint160 ref = LaunchParams.initialSqrtPriceX96();
        (uint256 lower, uint256 upper) = abi.decode(
            this.measureCall("Hook.allowedBand", address(hook), abi.encodeCall(hook.allowedBand, (ref)), address(this)),
            (uint256, uint256)
        );
        assertLt(lower, ref);
        assertGt(upper, ref);
    }

    function test_gas_hook_allowedBand_fullWidth() public {
        uint160 ref = type(uint160).max;
        (uint256 lower, uint256 upper) = abi.decode(
            this.measureCall(
                "Hook.allowedBand.fullWidth", address(hook), abi.encodeCall(hook.allowedBand, (ref)), address(this)
            ),
            (uint256, uint256)
        );
        assertLt(lower, ref);
        assertGt(upper, ref);
    }

    function test_gas_hook_isWithinBand() public {
        uint160 ref = LaunchParams.initialSqrtPriceX96();
        check("Hook.isWithinBand", abi.encodeCall(hook.isWithinBand, (ref, ref)), abi.encode(true));
    }

    function test_gas_hook_beforeSwap_firstInBlock() public {
        uint160 price = currentPrice();
        bytes memory result = this.measureCall(
            "Hook.beforeSwap.firstInBlock",
            address(hook),
            abi.encodeCall(hook.beforeSwap, (address(router), hooked, SwapParams(true, -1, 1), bytes(""))),
            address(manager)
        );
        assertEq(result, abi.encode(IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), uint24(0)));
        assertEq(hook.refBlock(hooked.toId()), 101);
        assertEq(hook.refSqrtPrice(hooked.toId()), price);
    }

    /// @dev A real trade hands `afterSwap` a non-zero delta; the zero delta is the refused phantom path below.
    function test_gas_hook_afterSwap() public {
        bytes memory result = this.measureCall(
            "Hook.afterSwap.inBand",
            address(hook),
            abi.encodeCall(
                hook.afterSwap, (address(router), hooked, SwapParams(true, -1, 1), toBalanceDelta(-1, 1), bytes(""))
            ),
            address(manager)
        );
        assertEq(result, abi.encode(IHooks.afterSwap.selector, int128(0)));
    }

    function test_gas_hook_afterSwap_phantom() public {
        uint160 ref = hook.refSqrtPrice(hooked.toId());
        this.measureRevert(
            "Hook.afterSwap.phantom",
            address(hook),
            abi.encodeCall(
                hook.afterSwap, (address(router), hooked, SwapParams(true, -1, 1), BalanceDelta.wrap(0), bytes(""))
            ),
            address(manager),
            abi.encodeWithSelector(CircuitBreakerHook.PhantomSwap.selector, ref, currentPrice())
        );
    }

    function test_gas_hook_beforeSwap_nonNative() public {
        PoolKey memory k = hooked;
        k.currency0 = Currency.wrap(address(1));
        bytes memory result = this.measureCall(
            "Hook.beforeSwap.nonNative",
            address(hook),
            abi.encodeCall(hook.beforeSwap, (address(router), k, SwapParams(true, -1, 1), bytes(""))),
            address(manager)
        );
        assertEq(result, abi.encode(IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), uint24(0)));
        assertEq(hook.refBlock(k.toId()), 0);
    }

    function test_gas_hook_afterSwap_nonNative() public {
        PoolKey memory k = hooked;
        k.currency0 = Currency.wrap(address(1));
        assertEq(
            this.measureCall(
                "Hook.afterSwap.nonNative",
                address(hook),
                abi.encodeCall(
                    hook.afterSwap, (address(router), k, SwapParams(true, -1, 1), BalanceDelta.wrap(0), bytes(""))
                ),
                address(manager)
            ),
            abi.encode(IHooks.afterSwap.selector, int128(0))
        );
    }
}

contract GasHookFirstEverTest is GasFixture {
    function setUp() public {
        setupPools(false, false);
    }

    function test_gas_hook_beforeSwap_firstEver() public {
        bytes memory result = this.measureCall(
            "Hook.beforeSwap.firstEver",
            address(hook),
            abi.encodeCall(hook.beforeSwap, (address(router), hooked, SwapParams(true, -1, 1), bytes(""))),
            address(manager)
        );
        assertEq(result, abi.encode(IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), uint24(0)));
        assertEq(hook.refBlock(hooked.toId()), 100);
        assertEq(hook.refSqrtPrice(hooked.toId()), LaunchParams.initialSqrtPriceX96());
    }

    /// @dev Before any swap the stored reference is zero, so every price is outside the band: the cheapest
    /// way to reach the `Tripped` revert path through the callback alone.
    function test_gas_hook_afterSwap_tripped() public {
        this.measureRevert(
            "Hook.afterSwap.tripped",
            address(hook),
            abi.encodeCall(
                hook.afterSwap, (address(router), hooked, SwapParams(true, -1, 1), toBalanceDelta(-1, 1), bytes(""))
            ),
            address(manager),
            abi.encodeWithSelector(CircuitBreakerHook.Tripped.selector, uint160(0), LaunchParams.initialSqrtPriceX96())
        );
    }
}

contract GasDeployFunctionsTest is GasFixture {
    Deploy internal deployment;

    function setUp() public {
        deployment = Deploy(deployCode("Deploy.s.sol:Deploy"));
    }

    function test_gas_Deploy_SEPOLIA_POOL_MANAGER() public {
        assertEq(
            this.measureCall(
                "Deploy.SEPOLIA_POOL_MANAGER",
                address(deployment),
                abi.encodeWithSignature("SEPOLIA_POOL_MANAGER()"),
                address(this)
            ),
            abi.encode(address(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543))
        );
    }

    function test_gas_Deploy_CREATE2_DEPLOYER() public {
        assertEq(
            this.measureCall(
                "Deploy.CREATE2_DEPLOYER",
                address(deployment),
                abi.encodeWithSignature("CREATE2_DEPLOYER()"),
                address(this)
            ),
            abi.encode(address(0x4e59b44847b379578588920cA78FbF26c0B4956C))
        );
    }

    function test_gas_Deploy_MAX_SALT_ITERATIONS() public {
        assertEq(
            this.measureCall(
                "Deploy.MAX_SALT_ITERATIONS",
                address(deployment),
                abi.encodeWithSignature("MAX_SALT_ITERATIONS()"),
                address(this)
            ),
            abi.encode(uint256(5_000_000))
        );
    }

    function test_gas_Deploy_IS_SCRIPT() public {
        assertEq(
            this.measureCall(
                "Deploy.IS_SCRIPT", address(deployment), abi.encodeWithSignature("IS_SCRIPT()"), address(this)
            ),
            abi.encode(true)
        );
    }

    function test_gas_Deploy_hookCreationCode() public {
        IPoolManager pm = IPoolManager(deployment.SEPOLIA_POOL_MANAGER());
        bytes memory result = this.measureCall(
            "Deploy.hookCreationCode",
            address(deployment),
            abi.encodeCall(deployment.hookCreationCode, (pm)),
            address(this)
        );
        assertEq(
            abi.decode(result, (bytes)),
            abi.encodePacked(vm.getCode("CircuitBreakerHook.sol:CircuitBreakerHook"), abi.encode(pm))
        );
    }

    function test_gas_Deploy_mineHookSalt() public {
        IPoolManager pm = IPoolManager(deployment.SEPOLIA_POOL_MANAGER());
        address origin = deployment.CREATE2_DEPLOYER();
        bytes memory result = this.measureCall(
            "Deploy.mineHookSalt.Sepolia",
            address(deployment),
            abi.encodeCall(deployment.mineHookSalt, (pm, origin)),
            address(this)
        );
        (address predicted, bytes32 salt) = abi.decode(result, (address, bytes32));
        assertEq(HookFlags.flagsOf(predicted), 0xC0);
        assertEq(predicted, HookFlags.computeAddress(origin, salt, keccak256(deployment.hookCreationCode(pm))));
        emit log_named_uint("salt candidates tried", uint256(salt) + 1);
    }

    function test_gas_Deploy_deploy() public {
        IPoolManager pm = IPoolManager(deployment.SEPOLIA_POOL_MANAGER());
        bytes memory result = this.measureCall(
            "Deploy.deploy.local",
            address(deployment),
            abi.encodeCall(deployment.deploy, (pm, address(deployment))),
            address(this)
        );
        (CBRK t, CircuitBreakerHook h, bytes32 salt) = abi.decode(result, (CBRK, CircuitBreakerHook, bytes32));
        assertEq(t.balanceOf(address(deployment)), t.totalSupply());
        assertEq(address(h.POOL_MANAGER()), address(pm));
        assertEq(HookFlags.flagsOf(address(h)), 0xC0);
        assertEq(
            address(h), HookFlags.computeAddress(address(deployment), salt, keccak256(deployment.hookCreationCode(pm)))
        );
    }
}

contract GasHookDisabledFunctionsTest is GasFixture {
    function setUp() public {
        setupPools(false, false);
    }

    function disabled(string memory label, bytes memory data) external {
        vm.cool(address(hook));
        vm.prank(address(manager));
        (bool ok, bytes memory reason) = address(hook).call(data);
        uint256 used = vm.lastCallGas().gasTotalUsed;
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(CircuitBreakerHook.HookNotImplemented.selector));
        emit log_named_uint(label, used);
    }

    function test_gas_hook_beforeInitialize() public {
        this.disabled(
            "Hook.beforeInitialize.disabled",
            abi.encodeCall(hook.beforeInitialize, (address(router), hooked, uint160(1)))
        );
    }

    function test_gas_hook_afterInitialize() public {
        this.disabled(
            "Hook.afterInitialize.disabled",
            abi.encodeCall(hook.afterInitialize, (address(router), hooked, uint160(1), int24(0)))
        );
    }

    function test_gas_hook_beforeAddLiquidity() public {
        this.disabled(
            "Hook.beforeAddLiquidity.disabled",
            abi.encodeCall(
                hook.beforeAddLiquidity, (address(router), hooked, ModifyLiquidityParams(0, 60, 1, 0), bytes(""))
            )
        );
    }

    function test_gas_hook_afterAddLiquidity() public {
        this.disabled(
            "Hook.afterAddLiquidity.disabled",
            abi.encodeCall(
                hook.afterAddLiquidity,
                (
                    address(router),
                    hooked,
                    ModifyLiquidityParams(0, 60, 1, 0),
                    BalanceDelta.wrap(0),
                    BalanceDelta.wrap(0),
                    bytes("")
                )
            )
        );
    }

    function test_gas_hook_beforeRemoveLiquidity() public {
        this.disabled(
            "Hook.beforeRemoveLiquidity.disabled",
            abi.encodeCall(
                hook.beforeRemoveLiquidity, (address(router), hooked, ModifyLiquidityParams(0, 60, -1, 0), bytes(""))
            )
        );
    }

    function test_gas_hook_afterRemoveLiquidity() public {
        this.disabled(
            "Hook.afterRemoveLiquidity.disabled",
            abi.encodeCall(
                hook.afterRemoveLiquidity,
                (
                    address(router),
                    hooked,
                    ModifyLiquidityParams(0, 60, -1, 0),
                    BalanceDelta.wrap(0),
                    BalanceDelta.wrap(0),
                    bytes("")
                )
            )
        );
    }

    function test_gas_hook_beforeDonate() public {
        this.disabled(
            "Hook.beforeDonate.disabled",
            abi.encodeCall(hook.beforeDonate, (address(router), hooked, uint256(1), uint256(1), bytes("")))
        );
    }

    function test_gas_hook_afterDonate() public {
        this.disabled(
            "Hook.afterDonate.disabled",
            abi.encodeCall(hook.afterDonate, (address(router), hooked, uint256(1), uint256(1), bytes("")))
        );
    }
}
