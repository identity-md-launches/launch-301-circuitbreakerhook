// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {CBRK} from "../src/CBRK.sol";
import {CircuitBreakerHook} from "../src/CircuitBreakerHook.sol";
import {HookFlags} from "../src/HookFlags.sol";

/// @notice Drives the deploy function directly, with the test's own manager and the script contract as
/// the CREATE2 origin. No environment, no broadcast.
contract DeployTest is Test {
    function test_deploy_producesTokenAndHookAtMinedAddress() public {
        PoolManager manager = new PoolManager(address(this));
        Deploy script = new Deploy();

        (CBRK token, CircuitBreakerHook hook, bytes32 salt) = script.deploy(manager, address(script));

        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(
            token.balanceOf(address(script)), token.totalSupply(), "token minted to someone other than the deployer"
        );

        assertEq(HookFlags.flagsOf(address(hook)), 0x00C0);
        assertEq(address(hook.POOL_MANAGER()), address(manager));
        (address predicted, bytes32 minedSalt) = script.mineHookSalt(manager, address(script));
        assertEq(predicted, address(hook));
        assertEq(minedSalt, salt);
    }

    /// @dev The salt and address for the real Sepolia deployment are a pure function of the source, the
    /// PoolManager address and the CREATE2 deployer: anyone can recompute them from the manifest.
    function test_sepoliaSaltIsDeterministic() public {
        Deploy script = new Deploy();
        IPoolManager pm = IPoolManager(script.SEPOLIA_POOL_MANAGER());
        (address a1, bytes32 s1) = script.mineHookSalt(pm, script.CREATE2_DEPLOYER());
        (address a2, bytes32 s2) = script.mineHookSalt(pm, script.CREATE2_DEPLOYER());
        assertEq(a1, a2);
        assertEq(s1, s2);
        assertEq(HookFlags.flagsOf(a1), 0x00C0);
        assertEq(HookFlags.computeAddress(script.CREATE2_DEPLOYER(), s1, keccak256(script.hookCreationCode(pm))), a1);
    }
}
