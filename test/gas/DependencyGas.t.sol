// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GasFixture} from "./GasFixture.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {LaunchParams} from "../utils/LaunchParams.sol";

/// @dev Supplemental measurements for callable upstream surfaces included in the size inventory.
/// These are not hook permissions or launch administration; they belong to v4 PoolManager itself.
abstract contract GasManagerFixture is GasFixture {
    address constant ALICE = address(0xA11CE);
    address constant DYNAMIC_HOOK = address(0x10000); // no callback bits
    PoolKey internal dynamicKey;

    function setUp() public {
        setupPools(true, false);
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(hooked, 100);
        trade(hooked, true, -int256(0.01 ether));
        dynamicKey = hooked;
        dynamicKey.fee = 0x800000;
        dynamicKey.hooks = IHooks(DYNAMIC_HOOK);
        manager.initialize(dynamicKey, LaunchParams.initialSqrtPriceX96());
        manager.unlock(abi.encode(uint8(0)));
        assertTrue(manager.approve(ALICE, 0, 0.5 ether));
    }

    function measured(string memory name, bytes memory data) external returns (bytes memory) {
        return this.measureCall(name, address(manager), data, address(this));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        uint8 mode = abi.decode(data, (uint8));
        Currency eth = Currency.wrap(address(0));
        if (mode == 0) {
            manager.settle{value: 1 ether}();
            manager.mint(address(this), 0, 1 ether);
        } else if (mode == 1) {
            this.measured("PoolManager.burn", abi.encodeCall(manager.burn, (address(this), 0, 0.1 ether)));
            manager.take(eth, address(this), 0.1 ether);
        } else if (mode == 2) {
            manager.settle{value: 0.1 ether}();
            this.measured("PoolManager.mint", abi.encodeCall(manager.mint, (ALICE, 0, 0.1 ether)));
        } else if (mode == 3) {
            manager.settle{value: 0.1 ether}();
            this.measured("PoolManager.clear", abi.encodeCall(manager.clear, (eth, 0.1 ether)));
        } else {
            manager.take(eth, address(this), 0.1 ether);
            vm.cool(address(manager));
            uint256 paid = manager.settleFor{value: 0.1 ether}(address(this));
            uint256 used = vm.lastCallGas().gasTotalUsed;
            assertEq(paid, 0.1 ether);
            emit log_named_uint("PoolManager.settleFor", used);
        }
        return "";
    }
}

contract GasRouterFunctionsTest is GasFixture {
    PoolDonateTest internal donateRouter;

    function setUp() public {
        setupPools(true, false);
        donateRouter = PoolDonateTest(payable(deployCode("PoolDonateTest.sol:PoolDonateTest", abi.encode(manager))));
        assertTrue(token.approve(address(donateRouter), type(uint256).max));
    }

    function test_gas_router_manager() public {
        assertEq(
            this.measureCall(
                "PoolSwapTest.manager", address(router), abi.encodeWithSignature("manager()"), address(this)
            ),
            abi.encode(manager)
        );
        assertEq(
            this.measureCall(
                "PoolModifyLiquidityTest.manager",
                address(liquidityRouter),
                abi.encodeWithSignature("manager()"),
                address(this)
            ),
            abi.encode(manager)
        );
        assertEq(
            this.measureCall(
                "PoolDonateTest.manager", address(donateRouter), abi.encodeWithSignature("manager()"), address(this)
            ),
            abi.encode(manager)
        );
    }

    function test_gas_router_donate() public {
        donateRouter.donate{value: 0.01 ether}(hooked, 0.01 ether, 1 ether, "");
        emit log_named_uint("PoolDonateTest.donate", vm.lastCallGas().gasTotalUsed);
    }

    function test_gas_router_modifyLiquidity_fiveArguments() public {
        liquidityRouter.modifyLiquidity{value: 1 ether}(
            hooked,
            ModifyLiquidityParams(LaunchParams.SEED_TICK_LOWER, LaunchParams.INITIAL_TICK, 1e15, bytes32(uint256(1))),
            "",
            false,
            false
        );
        emit log_named_uint("PoolModifyLiquidityTest.modifyLiquidity.fiveArguments", vm.lastCallGas().gasTotalUsed);
    }
}

contract GasManagerFunctionsTest is GasManagerFixture {
    function test_gas_PoolManager_approve() public {
        assertEq(
            this.measured("PoolManager.approve", abi.encodeCall(manager.approve, (ALICE, 0, 0.1 ether))),
            abi.encode(true)
        );
        assertEq(manager.allowance(address(this), ALICE, 0), 0.1 ether);
    }

    function test_gas_PoolManager_setOperator() public {
        assertEq(
            this.measured("PoolManager.setOperator", abi.encodeCall(manager.setOperator, (ALICE, true))),
            abi.encode(true)
        );
        assertTrue(manager.isOperator(address(this), ALICE));
    }

    function test_gas_PoolManager_transfer() public {
        assertEq(
            this.measured("PoolManager.transfer", abi.encodeCall(manager.transfer, (ALICE, 0, 0.1 ether))),
            abi.encode(true)
        );
        assertEq(manager.balanceOf(ALICE, 0), 0.1 ether);
    }

    function test_gas_PoolManager_transferFrom() public {
        assertEq(
            this.measureCall(
                "PoolManager.transferFrom",
                address(manager),
                abi.encodeCall(manager.transferFrom, (address(this), ALICE, 0, 0.1 ether)),
                ALICE
            ),
            abi.encode(true)
        );
        assertEq(manager.balanceOf(ALICE, 0), 0.1 ether);
        assertEq(manager.allowance(address(this), ALICE, 0), 0.4 ether);
    }

    function test_gas_PoolManager_transferOwnership() public {
        this.measured("PoolManager.transferOwnership", abi.encodeCall(manager.transferOwnership, (ALICE)));
        assertEq(manager.owner(), ALICE);
    }

    function test_gas_PoolManager_setProtocolFeeController() public {
        this.measured("PoolManager.setProtocolFeeController", abi.encodeCall(manager.setProtocolFeeController, (ALICE)));
        assertEq(manager.protocolFeeController(), ALICE);
    }

    function test_gas_PoolManager_setProtocolFee() public {
        this.measured("PoolManager.setProtocolFee", abi.encodeCall(manager.setProtocolFee, (hooked, 500)));
    }

    function test_gas_PoolManager_collectProtocolFees() public {
        uint256 beforeBalance = ALICE.balance;
        uint256 accrued = manager.protocolFeesAccrued(Currency.wrap(address(0)));
        assertEq(
            this.measured(
                "PoolManager.collectProtocolFees",
                abi.encodeCall(manager.collectProtocolFees, (ALICE, Currency.wrap(address(0)), 0))
            ),
            abi.encode(accrued)
        );
        assertEq(ALICE.balance - beforeBalance, accrued);
    }

    function test_gas_PoolManager_updateDynamicLPFee() public {
        this.measureCall(
            "PoolManager.updateDynamicLPFee",
            address(manager),
            abi.encodeCall(manager.updateDynamicLPFee, (dynamicKey, 3000)),
            DYNAMIC_HOOK
        );
    }

    function test_gas_PoolManager_burn() public {
        manager.unlock(abi.encode(uint8(1)));
        assertEq(manager.balanceOf(address(this), 0), 0.9 ether);
    }

    function test_gas_PoolManager_mint() public {
        manager.unlock(abi.encode(uint8(2)));
        assertEq(manager.balanceOf(ALICE, 0), 0.1 ether);
    }

    function test_gas_PoolManager_clear() public {
        manager.unlock(abi.encode(uint8(3)));
    }

    function test_gas_PoolManager_settleFor() public {
        manager.unlock(abi.encode(uint8(4)));
    }
}

contract GasManagerViewsTest is GasManagerFixture {
    function test_gas_PoolManager_extsload_sparse() public {
        bytes32[] memory slots = new bytes32[](2);
        slots[0] = bytes32(uint256(123));
        slots[1] = bytes32(uint256(456));
        assertEq(
            this.measured("PoolManager.extsload(bytes32[])", abi.encodeWithSignature("extsload(bytes32[])", slots)),
            abi.encode(new bytes32[](2))
        );
    }

    function test_gas_PoolManager_exttload_sparse() public {
        bytes32[] memory slots = new bytes32[](2);
        slots[0] = bytes32(uint256(123));
        slots[1] = bytes32(uint256(456));
        assertEq(
            this.measured("PoolManager.exttload(bytes32[])", abi.encodeWithSignature("exttload(bytes32[])", slots)),
            abi.encode(new bytes32[](2))
        );
    }

    function test_gas_PoolManager_owner() public {
        assertEq(this.measured("PoolManager.owner", abi.encodeCall(manager.owner, ())), abi.encode(address(this)));
    }

    function test_gas_PoolManager_protocolFeeController() public {
        assertEq(
            this.measured("PoolManager.protocolFeeController", abi.encodeCall(manager.protocolFeeController, ())),
            abi.encode(address(this))
        );
    }

    function test_gas_PoolManager_protocolFeesAccrued() public {
        assertGt(
            abi.decode(
                this.measured(
                    "PoolManager.protocolFeesAccrued",
                    abi.encodeCall(manager.protocolFeesAccrued, (Currency.wrap(address(0))))
                ),
                (uint256)
            ),
            0
        );
    }

    function test_gas_PoolManager_balanceOf() public {
        assertEq(
            this.measured("PoolManager.balanceOf", abi.encodeCall(manager.balanceOf, (address(this), 0))),
            abi.encode(uint256(1 ether))
        );
    }

    function test_gas_PoolManager_allowance() public {
        assertEq(
            this.measured("PoolManager.allowance", abi.encodeCall(manager.allowance, (address(this), ALICE, 0))),
            abi.encode(uint256(0.5 ether))
        );
    }

    function test_gas_PoolManager_isOperator() public {
        assertEq(
            this.measured("PoolManager.isOperator", abi.encodeCall(manager.isOperator, (address(this), ALICE))),
            abi.encode(false)
        );
    }

    function test_gas_PoolManager_supportsInterface() public {
        assertEq(
            this.measured(
                "PoolManager.supportsInterface", abi.encodeCall(manager.supportsInterface, (bytes4(0x01ffc9a7)))
            ),
            abi.encode(true)
        );
    }
}
