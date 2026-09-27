// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {CBRK} from "../src/CBRK.sol";
import {CircuitBreakerHook} from "../src/CircuitBreakerHook.sol";
import {HookFlags} from "../src/HookFlags.sol";

/// @title Deploy
/// @notice Reference deployment of CBRK and CircuitBreakerHook. The launch itself goes through the
/// factory after this stage; this script exists so a reviewer can reproduce the exact creation code,
/// salt and address the manifest will carry, and so the deployment path is covered by a test.
///
/// Configuration is constants only. `run()` reads no environment variables and does not depend on who
/// broadcasts; pass the sender on the command line:
///
///   forge script script/Deploy.s.sol --rpc-url <sepolia> --sender <addr> --broadcast [--ledger|--account ...]
///
/// This script never holds keys and never funds anything. It is not authorised to launch on its own.
contract Deploy is Script {
    /// @notice The Uniswap v4 PoolManager on Sepolia (chain id 11155111), the hook's only constructor argument.
    address public constant SEPOLIA_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

    /// @notice The deterministic CREATE2 deployer Foundry routes `new C{salt: s}()` through when
    /// broadcasting. The mined salt is only valid for this deployer.
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice Upper bound on salts tried. With two flag bits one address in 16,384 matches, so this is
    /// hundreds of times more than a search ever needs.
    uint256 public constant MAX_SALT_ITERATIONS = 5_000_000;

    function run() external returns (CBRK token, CircuitBreakerHook hook, bytes32 salt) {
        vm.startBroadcast();
        (token, hook, salt) = deploy(IPoolManager(SEPOLIA_POOL_MANAGER), CREATE2_DEPLOYER);
        vm.stopBroadcast();

        console.log("CBRK token:            ", address(token));
        console.log("CircuitBreakerHook:    ", address(hook));
        console.log("hook salt:");
        console.logBytes32(salt);
        console.log("hook flags (expect 192):", uint256(HookFlags.flagsOf(address(hook))));
    }

    /// @notice Deploys the token with `new` (minted to the caller) and the hook with CREATE2 at the mined
    /// address. `create2Deployer` is the address the CREATE2 will actually originate from: the Foundry
    /// deployer proxy in a broadcast, or the calling contract in a test.
    function deploy(IPoolManager poolManager, address create2Deployer)
        public
        returns (CBRK token, CircuitBreakerHook hook, bytes32 salt)
    {
        token = new CBRK();
        address predicted;
        (predicted, salt) = mineHookSalt(poolManager, create2Deployer);
        hook = new CircuitBreakerHook{salt: salt}(poolManager);
        require(address(hook) == predicted, "hook landed on an unexpected address");
    }

    /// @notice The creation code the manifest attests: runtime + constructor with the PoolManager appended.
    function hookCreationCode(IPoolManager poolManager) public pure returns (bytes memory) {
        return abi.encodePacked(type(CircuitBreakerHook).creationCode, abi.encode(poolManager));
    }

    /// @notice The first salt from which `create2Deployer` lands the hook on an address ending in 0x00C0.
    function mineHookSalt(IPoolManager poolManager, address create2Deployer)
        public
        pure
        returns (address predicted, bytes32 salt)
    {
        return HookFlags.mine(
            create2Deployer,
            (HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP),
            hookCreationCode(poolManager),
            MAX_SALT_ITERATIONS
        );
    }
}
