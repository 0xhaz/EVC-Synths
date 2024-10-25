// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.19;

import {IMinimalVault} from "src/balancer-adapter/interfaces/IMinimalVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EVCUtil} from "evc/utils/EVCUtil.sol";
import {console} from "forge-std/console.sol";

contract MockVault is IMinimalVault, EVCUtil {
    error Reentrancy();

    address public immutable ASSET;
    uint256 private constant REENTRANCY_LOCKED = 1;
    uint256 private constant REENTRANCY_UNLOCKED = 2;

    uint256 private reentrancyLock;
    bytes private snapshot;

    mapping(address => uint256) public userShares;

    constructor(address asset, address evc) EVCUtil(evc) {
        ASSET = asset;
        reentrancyLock = REENTRANCY_UNLOCKED;
    }

    /// @notice prevent reentrancy
    modifier nonReentrant() virtual {
        if (reentrancyLock != REENTRANCY_UNLOCKED) {
            revert Reentrancy();
        }

        reentrancyLock = REENTRANCY_LOCKED;

        _;

        reentrancyLock = REENTRANCY_UNLOCKED;
    }

    function deposit(
        uint256 assets,
        address receiver
    ) external override callThroughEVC nonReentrant returns (uint256) {
        address sender = EVCUtil._msgSender();
        IERC20(ASSET).transferFrom(sender, address(this), assets);
        userShares[receiver] = assets;
        return assets;
    }

    function shares(
        address user
    ) external view returns (uint256) {
        return userShares[user];
    }
}
