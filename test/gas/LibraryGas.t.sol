// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";

/// @dev Standalone getters on compiled utility libraries; internal math has no separate call gas.
contract GasLibraryFunctionsTest is Test {
    address internal library0;
    address internal library1;
    address internal library2;
    address internal library3;
    address internal library4;
    address internal library5;
    address internal library6;

    function setUp() public {
        library0 = deployCode("BalanceDelta.sol:BalanceDeltaLibrary");
        library1 = deployCode("BeforeSwapDelta.sol:BeforeSwapDeltaLibrary");
        library2 = deployCode("Currency.sol:CurrencyLibrary");
        library3 = deployCode("LPFeeLibrary.sol:LPFeeLibrary");
        library4 = deployCode("ProtocolFeeLibrary.sol:ProtocolFeeLibrary");
        library5 = deployCode("StateLibrary.sol:StateLibrary");
        library6 = deployCode("StdError.sol:stdError");
    }

    function measure(string memory label, address target, bytes memory data) external {
        vm.cool(target);
        (bool ok, bytes memory result) = target.call(data);
        uint256 used = vm.lastCallGas().gasTotalUsed;
        assertTrue(ok, label);
        assertGe(result.length, 32);
        emit log_named_uint(label, used);
    }

    function test_gas_BalanceDeltaLibrary_ZERO_DELTA() public {
        this.measure("BalanceDeltaLibrary.ZERO_DELTA", library0, abi.encodeWithSignature("ZERO_DELTA()"));
    }

    function test_gas_BeforeSwapDeltaLibrary_ZERO_DELTA() public {
        this.measure("BeforeSwapDeltaLibrary.ZERO_DELTA", library1, abi.encodeWithSignature("ZERO_DELTA()"));
    }

    function test_gas_CurrencyLibrary_ADDRESS_ZERO() public {
        this.measure("CurrencyLibrary.ADDRESS_ZERO", library2, abi.encodeWithSignature("ADDRESS_ZERO()"));
    }

    function test_gas_LPFeeLibrary_DYNAMIC_FEE_FLAG() public {
        this.measure("LPFeeLibrary.DYNAMIC_FEE_FLAG", library3, abi.encodeWithSignature("DYNAMIC_FEE_FLAG()"));
    }

    function test_gas_LPFeeLibrary_MAX_LP_FEE() public {
        this.measure("LPFeeLibrary.MAX_LP_FEE", library3, abi.encodeWithSignature("MAX_LP_FEE()"));
    }

    function test_gas_LPFeeLibrary_OVERRIDE_FEE_FLAG() public {
        this.measure("LPFeeLibrary.OVERRIDE_FEE_FLAG", library3, abi.encodeWithSignature("OVERRIDE_FEE_FLAG()"));
    }

    function test_gas_LPFeeLibrary_REMOVE_OVERRIDE_MASK() public {
        this.measure("LPFeeLibrary.REMOVE_OVERRIDE_MASK", library3, abi.encodeWithSignature("REMOVE_OVERRIDE_MASK()"));
    }

    function test_gas_ProtocolFeeLibrary_MAX_PROTOCOL_FEE() public {
        this.measure("ProtocolFeeLibrary.MAX_PROTOCOL_FEE", library4, abi.encodeWithSignature("MAX_PROTOCOL_FEE()"));
    }

    function test_gas_StateLibrary_FEE_GROWTH_GLOBAL0_OFFSET() public {
        this.measure(
            "StateLibrary.FEE_GROWTH_GLOBAL0_OFFSET", library5, abi.encodeWithSignature("FEE_GROWTH_GLOBAL0_OFFSET()")
        );
    }

    function test_gas_StateLibrary_LIQUIDITY_OFFSET() public {
        this.measure("StateLibrary.LIQUIDITY_OFFSET", library5, abi.encodeWithSignature("LIQUIDITY_OFFSET()"));
    }

    function test_gas_StateLibrary_POOLS_SLOT() public {
        this.measure("StateLibrary.POOLS_SLOT", library5, abi.encodeWithSignature("POOLS_SLOT()"));
    }

    function test_gas_StateLibrary_POSITIONS_OFFSET() public {
        this.measure("StateLibrary.POSITIONS_OFFSET", library5, abi.encodeWithSignature("POSITIONS_OFFSET()"));
    }

    function test_gas_StateLibrary_TICKS_OFFSET() public {
        this.measure("StateLibrary.TICKS_OFFSET", library5, abi.encodeWithSignature("TICKS_OFFSET()"));
    }

    function test_gas_StateLibrary_TICK_BITMAP_OFFSET() public {
        this.measure("StateLibrary.TICK_BITMAP_OFFSET", library5, abi.encodeWithSignature("TICK_BITMAP_OFFSET()"));
    }

    function test_gas_stdError_arithmeticError() public {
        this.measure("stdError.arithmeticError", library6, abi.encodeWithSignature("arithmeticError()"));
    }

    function test_gas_stdError_assertionError() public {
        this.measure("stdError.assertionError", library6, abi.encodeWithSignature("assertionError()"));
    }

    function test_gas_stdError_divisionError() public {
        this.measure("stdError.divisionError", library6, abi.encodeWithSignature("divisionError()"));
    }

    function test_gas_stdError_encodeStorageError() public {
        this.measure("stdError.encodeStorageError", library6, abi.encodeWithSignature("encodeStorageError()"));
    }

    function test_gas_stdError_enumConversionError() public {
        this.measure("stdError.enumConversionError", library6, abi.encodeWithSignature("enumConversionError()"));
    }

    function test_gas_stdError_indexOOBError() public {
        this.measure("stdError.indexOOBError", library6, abi.encodeWithSignature("indexOOBError()"));
    }

    function test_gas_stdError_memOverflowError() public {
        this.measure("stdError.memOverflowError", library6, abi.encodeWithSignature("memOverflowError()"));
    }

    function test_gas_stdError_popError() public {
        this.measure("stdError.popError", library6, abi.encodeWithSignature("popError()"));
    }

    function test_gas_stdError_zeroVarError() public {
        this.measure("stdError.zeroVarError", library6, abi.encodeWithSignature("zeroVarError()"));
    }
}
