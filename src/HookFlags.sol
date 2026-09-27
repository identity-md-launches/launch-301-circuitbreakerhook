// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @title HookFlags
/// @notice The 14 permission bits Uniswap v4 reads from a hook's address, plus the helpers a deployer
/// and a test need to mine an address that carries a given set of them.
/// @dev Every constant is an alias of the matching `Hooks` constant so the two can never drift apart.
library HookFlags {
    uint160 internal constant BEFORE_INITIALIZE = Hooks.BEFORE_INITIALIZE_FLAG;
    uint160 internal constant AFTER_INITIALIZE = Hooks.AFTER_INITIALIZE_FLAG;
    uint160 internal constant BEFORE_ADD_LIQUIDITY = Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
    uint160 internal constant AFTER_ADD_LIQUIDITY = Hooks.AFTER_ADD_LIQUIDITY_FLAG;
    uint160 internal constant BEFORE_REMOVE_LIQUIDITY = Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY = Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;
    uint160 internal constant BEFORE_SWAP = Hooks.BEFORE_SWAP_FLAG;
    uint160 internal constant AFTER_SWAP = Hooks.AFTER_SWAP_FLAG;
    uint160 internal constant BEFORE_DONATE = Hooks.BEFORE_DONATE_FLAG;
    uint160 internal constant AFTER_DONATE = Hooks.AFTER_DONATE_FLAG;
    uint160 internal constant BEFORE_SWAP_RETURN_DELTA = Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
    uint160 internal constant AFTER_SWAP_RETURN_DELTA = Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint160 internal constant AFTER_ADD_LIQUIDITY_RETURN_DELTA = Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY_RETURN_DELTA = Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;

    /// @notice Mask of all 14 permission bits (0x3FFF).
    uint160 internal constant ALL = Hooks.ALL_HOOK_MASK;

    /// @notice The permission bits carried by `hook`'s address.
    function flagsOf(address hook) internal pure returns (uint160) {
        return uint160(hook) & ALL;
    }

    /// @notice True when `hook`'s address carries exactly `flags` (ignoring bits outside the mask).
    function matches(address hook, uint160 flags) internal pure returns (bool) {
        return flagsOf(hook) == (flags & ALL);
    }

    /// @notice Packs a `Hooks.Permissions` struct into its address bits.
    function fromPermissions(Hooks.Permissions memory p) internal pure returns (uint160 flags) {
        if (p.beforeInitialize) flags |= BEFORE_INITIALIZE;
        if (p.afterInitialize) flags |= AFTER_INITIALIZE;
        if (p.beforeAddLiquidity) flags |= BEFORE_ADD_LIQUIDITY;
        if (p.afterAddLiquidity) flags |= AFTER_ADD_LIQUIDITY;
        if (p.beforeRemoveLiquidity) flags |= BEFORE_REMOVE_LIQUIDITY;
        if (p.afterRemoveLiquidity) flags |= AFTER_REMOVE_LIQUIDITY;
        if (p.beforeSwap) flags |= BEFORE_SWAP;
        if (p.afterSwap) flags |= AFTER_SWAP;
        if (p.beforeDonate) flags |= BEFORE_DONATE;
        if (p.afterDonate) flags |= AFTER_DONATE;
        if (p.beforeSwapReturnDelta) flags |= BEFORE_SWAP_RETURN_DELTA;
        if (p.afterSwapReturnDelta) flags |= AFTER_SWAP_RETURN_DELTA;
        if (p.afterAddLiquidityReturnDelta) flags |= AFTER_ADD_LIQUIDITY_RETURN_DELTA;
        if (p.afterRemoveLiquidityReturnDelta) flags |= AFTER_REMOVE_LIQUIDITY_RETURN_DELTA;
    }

    /// @notice The CREATE2 address `deployer` would produce for `initCodeHash` with `salt`.
    /// @dev Hashes in scratch space below the free-memory pointer instead of allocating, so a mining loop
    /// of tens of thousands of iterations does not pay quadratic memory-expansion gas. Same layout as
    /// OpenZeppelin's `Create2.computeAddress`: `0xff ++ deployer ++ salt ++ initCodeHash` (85 bytes).
    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash)
        internal
        pure
        returns (address predicted)
    {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(add(ptr, 0x40), initCodeHash)
            mstore(add(ptr, 0x20), salt)
            mstore(ptr, deployer)
            let start := add(ptr, 0x0b)
            mstore8(start, 0xff)
            predicted := and(keccak256(start, 85), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    /// @notice Searches salts `0, 1, 2, ...` until CREATE2 from `deployer` lands `creationCode` (constructor
    /// arguments already appended) on an address whose low bits equal `flags`.
    /// @dev Two set bits out of fourteen means one address in 16,384 matches; `maxIterations` bounds the
    /// search so a caller can fail loudly instead of running out of gas. Deterministic: the same inputs
    /// always give the same salt, which is what lets a reviewer recompute the address from the manifest.
    function mine(address deployer, uint160 flags, bytes memory creationCode, uint256 maxIterations)
        internal
        pure
        returns (address hook, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 i = 0; i < maxIterations; i++) {
            salt = bytes32(i);
            hook = computeAddress(deployer, salt, initCodeHash);
            if (matches(hook, flags)) return (hook, salt);
        }
        revert NoSaltFound(deployer, flags, maxIterations);
    }

    error NoSaltFound(address deployer, uint160 flags, uint256 iterations);
}
