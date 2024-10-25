// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.19;

interface IMinimalVault {
    /**
     * @notice Deposits a certain amount of assets for a receiver
     * @param assets The assets to deposit
     * @param receiver The receiver of the assets
     * @return shares The shares equivalent of the deposited assets
     */
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
}
