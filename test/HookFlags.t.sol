// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {CircuitBreakerHook} from "../src/CircuitBreakerHook.sol";

contract HookFlagsTest is Test {
    address constant SEPOLIA_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

    function test_constantsMirrorV4Core() public pure {
        assertEq(HookFlags.BEFORE_INITIALIZE, Hooks.BEFORE_INITIALIZE_FLAG);
        assertEq(HookFlags.AFTER_INITIALIZE, Hooks.AFTER_INITIALIZE_FLAG);
        assertEq(HookFlags.BEFORE_ADD_LIQUIDITY, Hooks.BEFORE_ADD_LIQUIDITY_FLAG);
        assertEq(HookFlags.AFTER_ADD_LIQUIDITY, Hooks.AFTER_ADD_LIQUIDITY_FLAG);
        assertEq(HookFlags.BEFORE_REMOVE_LIQUIDITY, Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG);
        assertEq(HookFlags.AFTER_REMOVE_LIQUIDITY, Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);
        assertEq(HookFlags.BEFORE_SWAP, 1 << 7);
        assertEq(HookFlags.AFTER_SWAP, 1 << 6);
        assertEq(HookFlags.BEFORE_DONATE, Hooks.BEFORE_DONATE_FLAG);
        assertEq(HookFlags.AFTER_DONATE, Hooks.AFTER_DONATE_FLAG);
        assertEq(HookFlags.BEFORE_SWAP_RETURN_DELTA, Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        assertEq(HookFlags.AFTER_SWAP_RETURN_DELTA, Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        assertEq(HookFlags.AFTER_ADD_LIQUIDITY_RETURN_DELTA, Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG);
        assertEq(HookFlags.AFTER_REMOVE_LIQUIDITY_RETURN_DELTA, Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG);
        assertEq(HookFlags.ALL, 0x3FFF);
    }

    function test_flagsOfAndMatches() public pure {
        address a = address(uint160(0x1234 << 16) | 0x00C0);
        assertEq(HookFlags.flagsOf(a), 0x00C0);
        assertTrue(HookFlags.matches(a, 0x00C0));
        assertTrue(HookFlags.matches(a, 0x00C0 | (1 << 20)), "bits above the mask must be ignored");
        assertFalse(HookFlags.matches(a, 0x00C1));
        assertFalse(HookFlags.matches(address(uint160(a) | 0x0001), 0x00C0));
    }

    function test_fromPermissions_ofTheHookIs0x00C0() public pure {
        Hooks.Permissions memory p;
        p.beforeSwap = true;
        p.afterSwap = true;
        assertEq(HookFlags.fromPermissions(p), 0x00C0);
    }

    function test_fromPermissions_everyFlag() public pure {
        Hooks.Permissions memory p =
            Hooks.Permissions(true, true, true, true, true, true, true, true, true, true, true, true, true, true);
        assertEq(HookFlags.fromPermissions(p), HookFlags.ALL);
    }

    /// @dev Mining is deterministic and the mined address really carries the bits, from any deployer.
    function testFuzz_mine_findsAnAddressCarryingTheFlags(address deployer) public pure {
        bytes memory creationCode =
            abi.encodePacked(type(CircuitBreakerHook).creationCode, abi.encode(IPoolManager(SEPOLIA_POOL_MANAGER)));
        (address hook, bytes32 salt) = HookFlags.mine(deployer, 0x00C0, creationCode, 1_000_000);
        assertEq(HookFlags.flagsOf(hook), 0x00C0);
        assertEq(HookFlags.computeAddress(deployer, salt, keccak256(creationCode)), hook);
        (address again, bytes32 saltAgain) = HookFlags.mine(deployer, 0x00C0, creationCode, 1_000_000);
        assertEq(again, hook);
        assertEq(saltAgain, salt);
    }

    function test_mine_revertsWhenTheBudgetRunsOut() public {
        bytes memory creationCode = hex"00";
        bytes32 h = keccak256(creationCode);
        // salt 0 is the only one tried; skip the astronomically unlikely case that it already matches
        vm.assume(!HookFlags.matches(HookFlags.computeAddress(address(this), bytes32(0), h), 0x00C0));
        vm.expectRevert(abi.encodeWithSelector(HookFlags.NoSaltFound.selector, address(this), 0x00C0, 1));
        this.mineExternally(address(this), 0x00C0, creationCode, 1);
    }

    function mineExternally(address deployer, uint160 flags, bytes memory code, uint256 max)
        external
        pure
        returns (address, bytes32)
    {
        return HookFlags.mine(deployer, flags, code, max);
    }
}
