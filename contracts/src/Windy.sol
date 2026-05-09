// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title  Windy (WNDY) — fixed-cap, role-gated ERC-20
/// @notice The token side of the windy-coin "Proof-of-Windy" system.
///         WNDY is a standard ERC-20 with a hard 21,000,000-token supply
///         cap (Bitcoin homage), zero pre-mine, and role-gated minting.
/// @dev    The trust model is intentionally minimal:
///         1. The 21M cap is a `constant` in code — no admin path can
///            change it.
///         2. The deployer holds only `DEFAULT_ADMIN_ROLE` and *never*
///            `MINTER_ROLE`, so the deployer cannot mint to themselves.
///         3. `MINTER_ROLE` is intended to be granted only to dedicated
///            minter contracts (e.g. `ZkExecutionMinter`) that gate
///            issuance behind a cryptographic proof.
///         4. `ERC20Burnable` lets holders burn their own balance —
///            useful for Phase 2 deflationary pressure designs and for
///            anyone wanting to retire tokens.
///         5. The deployer is expected to migrate `DEFAULT_ADMIN_ROLE`
///            to a multisig, then eventually `renounceRole(...)` to
///            reach a fully ungoverned state.
contract Windy is ERC20, ERC20Burnable, AccessControl {
    /// @notice Hard cap on `totalSupply()`, denominated in WNDY base units
    ///         (`1e18` per whole WNDY). Mirrors Bitcoin's 21M supply.
    uint256 public constant MAX_SUPPLY = 21_000_000 * 10 ** 18;

    /// @notice Identifier for the role allowed to call `mint`.
    /// @dev Computed as `keccak256("MINTER_ROLE")`.
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Reverted by `mint` when issuing `amount` more tokens would
    ///         push `totalSupply()` beyond `MAX_SUPPLY`.
    /// @param attempted The post-mint supply that would have resulted.
    /// @param cap       The immutable supply ceiling (`MAX_SUPPLY`).
    error MaxSupplyExceeded(uint256 attempted, uint256 cap);

    /// @notice Deploy WNDY with name "Windy" and symbol "WNDY". Total
    ///         supply starts at zero. The deployer receives
    ///         `DEFAULT_ADMIN_ROLE` only — no `MINTER_ROLE`.
    constructor() ERC20("Windy", "WNDY") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @notice Mint `amount` WNDY to `to`. Restricted to holders of
    ///         `MINTER_ROLE`. Reverts with `MaxSupplyExceeded` if the
    ///         resulting supply would exceed the immutable 21M cap.
    /// @param to     Recipient of the freshly minted WNDY.
    /// @param amount Amount in base units (`1e18` per whole WNDY).
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        uint256 attempted = totalSupply() + amount;
        if (attempted > MAX_SUPPLY) {
            revert MaxSupplyExceeded(attempted, MAX_SUPPLY);
        }
        _mint(to, amount);
    }
}
