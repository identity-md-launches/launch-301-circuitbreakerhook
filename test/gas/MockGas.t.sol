// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GasFixture} from "./GasFixture.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev The repository's test token is inventoried separately from the launch token.
contract GasMockFunctionsTest is GasFixture {
    MockERC20 internal mock;
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);

    function setUp() public {
        mock = MockERC20(deployCode("MockERC20.sol:MockERC20", abi.encode("Mock", "MOCK", 100 ether)));
        assertTrue(mock.approve(ALICE, 5 ether));
    }

    function check(string memory name, bytes memory data, bytes memory expected) internal {
        assertEq(this.measureCall(name, address(mock), data, address(this)), expected);
    }

    function test_gas_MockERC20_name() public {
        check("MockERC20.name", abi.encodeCall(mock.name, ()), abi.encode("Mock"));
    }

    function test_gas_MockERC20_symbol() public {
        check("MockERC20.symbol", abi.encodeCall(mock.symbol, ()), abi.encode("MOCK"));
    }

    function test_gas_MockERC20_decimals() public {
        check("MockERC20.decimals", abi.encodeCall(mock.decimals, ()), abi.encode(uint8(18)));
    }

    function test_gas_MockERC20_totalSupply() public {
        check("MockERC20.totalSupply", abi.encodeCall(mock.totalSupply, ()), abi.encode(uint256(100 ether)));
    }

    function test_gas_MockERC20_balanceOf() public {
        check("MockERC20.balanceOf", abi.encodeCall(mock.balanceOf, (address(this))), abi.encode(uint256(100 ether)));
    }

    function test_gas_MockERC20_allowance() public {
        check(
            "MockERC20.allowance", abi.encodeCall(mock.allowance, (address(this), ALICE)), abi.encode(uint256(5 ether))
        );
    }

    function test_gas_MockERC20_approve() public {
        check("MockERC20.approve", abi.encodeCall(mock.approve, (BOB, 1 ether)), abi.encode(true));
        assertEq(mock.allowance(address(this), BOB), 1 ether);
    }

    function test_gas_MockERC20_transfer() public {
        check("MockERC20.transfer", abi.encodeCall(mock.transfer, (BOB, 1 ether)), abi.encode(true));
        assertEq(mock.balanceOf(BOB), 1 ether);
    }

    function test_gas_MockERC20_transferFrom() public {
        assertEq(
            this.measureCall(
                "MockERC20.transferFrom",
                address(mock),
                abi.encodeCall(mock.transferFrom, (address(this), BOB, 1 ether)),
                ALICE
            ),
            abi.encode(true)
        );
        assertEq(mock.balanceOf(BOB), 1 ether);
        assertEq(mock.allowance(address(this), ALICE), 4 ether);
    }
}
