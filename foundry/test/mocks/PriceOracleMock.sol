// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.19;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20CollateralWrapper, IERC20} from "src/helpers/ERC20/ERC20CollateralWrapper.sol";
import {IPriceOracle} from "src/helpers/interfaces/IPriceOracle.sol";

interface IERC20Extensions is IERC20 {
    function decimals() external view returns (uint8);
}

contract PriceOracleMock is IPriceOracle {
    uint256 internal constant ADDRESS_MASK = (1 << 160) - 1; // 0x000000000000000000000000ffffffffffffffffffffffffffffffffffffffff
    uint256 internal constant VAULT_MASK = 1 << 160; // 0x000000000000000000000001

    type AssetInfo is uint256;

    mapping(address asset => AssetInfo) public resolvedAssets;
    mapping(address base => mapping(address quote => uint256)) internal prices;

    function name() external pure returns (string memory) {
        return "PriceOracleMock";
    }

    function setResolvedAsset(
        address asset
    ) external {
        try IERC4626(asset).asset() returns (address underlying) {
            resolvedAssets[asset] = _setAssetInfo(underlying, true);
        } catch {
            resolvedAssets[asset] = _setAssetInfo(ERC20CollateralWrapper(asset).underlying(), false);
        }
    }

    function setPrice(address base, address quote, uint256 priceValue) external {
        prices[base][quote] = priceValue;
    }

    function getQuote(uint256 amount, address base, address quote) external view returns (uint256 out) {
        uint256 price;
        (amount, base, quote, price) = _resolveOracle(amount, base, quote);

        if (base == quote) {
            out = amount;
        } else {
            out = (price * amount) / 10 ** IERC20Extensions(base).decimals();
        }
    }

    function getQuotes(
        uint256 amount,
        address base,
        address quote
    ) external view returns (uint256 bidOut, uint256 askOut) {
        uint256 price;
        (amount, base, quote, price) = _resolveOracle(amount, base, quote);

        if (base == quote) {
            bidOut = amount;
        } else {
            bidOut = (price * amount) / 10 ** IERC20Extensions(base).decimals();
        }

        askOut = bidOut;
    }

    function _getAssetInfo(
        AssetInfo self
    ) internal pure returns (address, bool) {
        return (address(uint160(AssetInfo.unwrap(self) & ADDRESS_MASK)), AssetInfo.unwrap(self) & VAULT_MASK != 0);
    }

    function _setAssetInfo(address asset, bool isVault) internal pure returns (AssetInfo) {
        return AssetInfo.wrap(uint160(asset) | (isVault ? VAULT_MASK : 0));
    }

    function _resolveOracle(
        uint256 amount,
        address base,
        address quote
    ) internal view returns (uint256, address, address, uint256) {
        // check the base case
        if (base == quote) return (amount, base, quote, 0);

        // Check if base/quote is configured
        uint256 price = prices[base][quote];
        if (price > 0) return (amount, base, quote, price);

        // Recursively resolve `base`.
        (address underlying, bool isVault) = _getAssetInfo(resolvedAssets[base]);
        if (underlying != address(0)) {
            amount = isVault ? IERC4626(base).convertToAssets(amount) : amount;
            return _resolveOracle(amount, underlying, quote);
        }

        // Recursively resolve `quote`
        (underlying, isVault) = _getAssetInfo(resolvedAssets[quote]);
        if (underlying != address(0)) {
            amount = isVault ? IERC4626(quote).convertToShares(amount) : amount;
            return _resolveOracle(amount, base, underlying);
        }

        revert PO_NoPath();
    }
}
