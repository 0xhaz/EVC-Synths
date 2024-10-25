// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.19;

interface IIRM {
    /**
     * @notice Computes the interest rate for a given vault, asset and utilization
     * @param vault The address of the vault
     * @param asset The address of the asset
     * @param utilization The utilization of the vault
     * @return The computed interest rate in SPY (Second Percentage Yield)
     */
    function computeInterestRate(address vault, address asset, uint32 utilization) external returns (uint96);
}
