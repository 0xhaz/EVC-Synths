// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.19;

import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "openzeppelin/token/ERC20/extensions/ERC20Burnable.sol";
import {ReentrancyGuard} from "openzeppelin/utils/ReentrancyGuard.sol";
import {Ownable} from "openzeppelin/access/Ownable.sol";

/**
 * @title ERC20Collateral
 * @notice It extends the ERC20 token standard to add the EVC authentication and account status checks so that
 * the token contract can be used as collateral in the EVC ecosystem.
 */
contract ERC20Mintable is ERC20, Ownable {
    uint8 private decimal;

    constructor(string memory name_, string memory symbol_, uint8 decimal_) ERC20(name_, symbol_) Ownable(msg.sender) {
        decimal = decimal_;
    }

    /**
     * @dev Extensions of {ERC20} that adds a set of accounts with the {OwnerRole},
     * which have permission to mint (create) new tokens as they see fit.
     */
    function mint(address account, uint256 amount) public onlyOwner returns (bool) {
        _mint(account, amount);
        return true;
    }

    function burn(address from, uint256 value) public onlyOwner {
        _burn(from, value);
    }

    function burnFrom(address account, uint256 value) public onlyOwner {
        _spendAllowance(account, _msgSender(), value);
        _burn(account, value);
    }

    function decimals() public view override returns (uint8) {
        return decimal;
    }
}
