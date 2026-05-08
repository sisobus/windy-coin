// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract Windy is ERC20, ERC20Burnable, AccessControl {
    uint256 public constant MAX_SUPPLY = 21_000_000 * 10 ** 18;
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    error MaxSupplyExceeded(uint256 attempted, uint256 cap);

    constructor() ERC20("Windy", "WNDY") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        uint256 attempted = totalSupply() + amount;
        if (attempted > MAX_SUPPLY) {
            revert MaxSupplyExceeded(attempted, MAX_SUPPLY);
        }
        _mint(to, amount);
    }
}
