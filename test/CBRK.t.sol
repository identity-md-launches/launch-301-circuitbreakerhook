// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {CBRK} from "../src/CBRK.sol";

contract CBRKTest is Test {
    CBRK token;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        token = new CBRK();
    }

    function test_metadata() public view {
        assertEq(token.name(), "Breaker");
        assertEq(token.symbol(), "CBRK");
        assertEq(token.decimals(), 18);
    }

    function test_mintsTheWholeSupplyToTheDeployerOnce() public view {
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000 ether);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    /// @dev The factory deploys with no constructor arguments: the raw creation code alone must work and
    /// must mint to whoever sends it.
    function test_deploysFromBareCreationCodeAndMintsToTheSender() public {
        bytes memory creationCode = type(CBRK).creationCode;
        vm.startPrank(alice);
        address deployed;
        assembly {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        vm.stopPrank();
        require(deployed != address(0), "deployment reverted");
        assertEq(CBRK(deployed).balanceOf(alice), 1_000_000_000 ether);
        assertEq(CBRK(deployed).totalSupply(), 1_000_000_000 ether);
    }

    function test_transferMovesExactlyTheAmount() public {
        uint256 supply = token.totalSupply();
        assertTrue(token.transfer(alice, 1234 ether));
        assertEq(token.balanceOf(alice), 1234 ether);
        assertEq(token.balanceOf(address(this)), supply - 1234 ether);
        assertEq(token.totalSupply(), supply, "a transfer changed the supply");
    }

    function test_transferFromRespectsAllowance() public {
        token.transfer(alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, 4 ether);

        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 4 ether));
        assertEq(token.balanceOf(bob), 4 ether);
        assertEq(token.allowance(alice, bob), 0);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    function test_transferBeyondBalanceReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_transferToZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    /// @dev There is no mint, burn-to-mint, owner or upgrade selector: none of the usual admin calls exist,
    /// from anyone, including the deployer.
    function test_noAdminSelectorChangesSupply() public {
        string[8] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "setMinter(address)"
        ];
        uint256 supply = token.totalSupply();
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], alice, type(uint128).max);
            (bool okFromStranger,) = address(token).call(data);
            assertFalse(okFromStranger, signatures[i]);
            vm.prank(alice);
            (bool okFromDeployer,) = address(token).call(data);
            assertFalse(okFromDeployer, signatures[i]);
            assertEq(token.totalSupply(), supply, signatures[i]);
            assertEq(token.balanceOf(alice), 0, signatures[i]);
        }
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(this));
        amount = bound(amount, 0, token.totalSupply());
        token.transfer(to, amount);
        assertEq(token.balanceOf(to) + token.balanceOf(address(this)), token.totalSupply());
    }
}
