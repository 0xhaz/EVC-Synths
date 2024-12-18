// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.19;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20Collateral, IEVC} from "../ERC20/ERC20Collateral.sol";

/**
 * @title ERC20CollateralWrapper
 * @notice It extends the ERC20Collateral contract so that any ERC20 token can be wrapped and used as collateral
 * in the EVC ecosystem.
 */
contract ERC20CollateralWrapper is ERC20Collateral {
    error ERC20CollateralWrapper_InvalidAddress();

    IERC20 private immutable _underlying;
    uint8 private immutable _decimals;

    constructor(
        IEVC evc_,
        IERC20 underlying_,
        string memory name_,
        string memory symbol_
    ) ERC20Collateral(evc_, name_, symbol_) {
        if (address(underlying_) == address(this)) {
            revert ERC20CollateralWrapper_InvalidAddress();
        }

        _underlying = underlying_;
        _decimals = IERC20Metadata(address(underlying_)).decimals();
    }

    /**
     * @notice Returns the address of the underlying ERC20 token
     * @return The address of the underlying ERC20 token
     */
    function underlying() external view returns (address) {
        return address(_underlying);
    }

    /**
     * @notice Returns the number of decimals of the wrapper token
     * @dev The number of decimals of the wrapper token is the same as the number of decimals of the underlying token
     * @return The number of decimals of the wrapper token
     */
    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    /**
     * @notice Wraps the specified amount of the underlying token into this ERC20 token
     * @param amount The amount of the underlying token to wrap
     * @param receiver The address to receive the wrapped tokens
     * @return True if the operation was successful
     */
    function wrap(uint256 amount, address receiver) public virtual nonReentrant returns (bool) {
        if (receiver == address(this)) {
            revert ERC20CollateralWrapper_InvalidAddress();
        }

        SafeERC20.safeTransferFrom(IERC20(_underlying), _msgSender(), address(this), amount);
        _mint(receiver, amount);

        return true;
    }

    /**
     * @notice Unwraps the specified amount of this ERC20 token into the underlying token
     * @param amount The amount of this ERC20 token to unwrap
     * @param receiver The address to receive the unwrapped tokens
     * @return True if the operation was successful
     */
    function unwrap(uint256 amount, address receiver) public virtual nonReentrant onlyEVCAccountOwner returns (bool) {
        if (receiver == address(this)) {
            revert ERC20CollateralWrapper_InvalidAddress();
        }

        address sender = _msgSender();
        _burn(sender, amount);
        SafeERC20.safeTransfer(IERC20(_underlying), receiver, amount);
        evc.requireAccountStatusCheck(sender);

        return true;
    }
}
