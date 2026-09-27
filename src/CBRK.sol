// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Breaker (CBRK)
/// @notice Fixed-supply ERC-20. The whole supply is minted once, in the constructor, to whoever deploys
/// the contract (the launch factory). There is no owner, minter, pauser, blocklist, fee or upgrade path:
/// the only state-changing functions are the plain ERC-20 `transfer`, `approve` and `transferFrom`.
/// @dev Zero constructor arguments on purpose: the factory deploys the token with no configuration and
/// checks that `balanceOf(factory) == totalSupply()` afterwards.
contract CBRK is ERC20 {
    /// @notice 1,000,000,000 CBRK with 18 decimals. Never changes after deployment.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    constructor() ERC20("Breaker", "CBRK") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
