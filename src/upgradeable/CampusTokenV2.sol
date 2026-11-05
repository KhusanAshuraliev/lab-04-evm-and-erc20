// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CampusTokenUpgradeable} from "./CampusTokenUpgradeable.sol";

/// @title CampusTokenV2
/// @notice Bonus E4. Adds one state variable, `maxTransfer`, and one function,
///         `setMaxTransfer`. Because V2 inherits V1, the new variable is
///         appended after every slot of V1 (it lands in slot 61) and no
///         existing slot moves.
contract CampusTokenV2 is CampusTokenUpgradeable {
    /// @notice Largest amount one ordinary transfer may move; 0 = no limit.
    uint256 public maxTransfer;

    event MaxTransferUpdated(uint256 previous, uint256 current);

    error TransferTooLarge(uint256 value, uint256 maxTransfer);

    function setMaxTransfer(uint256 newMax) external onlyRole(CONFIG_ROLE) {
        emit MaxTransferUpdated(maxTransfer, newMax);
        maxTransfer = newMax;
    }

    function version() external pure override returns (uint256) {
        return 2;
    }

    /// @dev Mint and burn are not transfers and are not limited.
    function _update(address from, address to, uint256 value) internal override {
        uint256 max = maxTransfer;
        if (max != 0 && from != address(0) && to != address(0) && value > max) {
            revert TransferTooLarge(value, max);
        }
        super._update(from, to, value);
    }
}
