// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "./IERC20.sol";

/// @notice The subset of Balancer V2's Vault this executor needs.
/// @dev The Vault is deployed at the SAME address on every chain Balancer V2
///      supports: 0xBA12222222228d8Ba445958a75a0704d566BF2C8
interface IBalancerVault {
    /// @notice Lends `amounts` of `tokens` to `recipient` for the length of one
    ///         call, then requires them back plus `feeAmounts`.
    /// @dev Balancer's flash loan fee is currently 0, set by governance via
    ///      ProtocolFeesCollector.getFlashLoanFeePercentage(). It is NOT
    ///      guaranteed to stay 0 — the executor must repay whatever
    ///      `feeAmounts` says at call time rather than assuming zero.
    function flashLoan(
        IFlashLoanRecipient recipient,
        IERC20[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;
}

interface IFlashLoanRecipient {
    /// @notice Called by the Vault once the borrowed tokens have been sent.
    /// @dev The recipient must transfer `amounts[i] + feeAmounts[i]` of each
    ///      token BACK to the Vault before this function returns. Balancer
    ///      verifies by balance, so a plain `transfer` is what settles it — an
    ///      `approve` does nothing here.
    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external;
}
