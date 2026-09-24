// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

pragma experimental ABIEncoderV2;

interface IMockERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function mint(address, uint256) external;
}

interface IFlashLoanRecipientLike {
    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external;
}

/// @notice Stands in for Balancer V2's Vault. Etched at the real Vault address
///         because the contract under test hardcodes it as a constant.
/// @dev Mirrors the two behaviours the executor actually depends on: tokens are
///      sent BEFORE the callback, and settlement is verified by balance delta
///      afterwards — not by allowance. The fee is configurable so the harness
///      can exercise the non-zero-fee path Balancer governance could enable.
contract MockVault {
    /// The executor probes this at construction to confirm it is really
    /// talking to Balancer and not to an unrelated contract that happens to
    /// occupy the address on this chain.
    function getProtocolFeesCollector() external pure returns (address) {
        return 0xce88686553686DA562CE7Cea497CE749DA109f9F;
    }
    uint256 public feeBps;

    function setFeeBps(uint256 bps) external {
        feeBps = bps > 100 ? 100 : bps; // cap at 1%, well above anything realistic
    }

    function flashLoan(
        address recipient,
        address[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external {
        uint256[] memory fees = new uint256[](tokens.length);
        uint256[] memory pre = new uint256[](tokens.length);

        for (uint256 i; i < tokens.length; ++i) {
            pre[i] = IMockERC20(tokens[i]).balanceOf(address(this));
            fees[i] = (amounts[i] * feeBps) / 10_000;
            IMockERC20(tokens[i]).transfer(recipient, amounts[i]);
        }

        IFlashLoanRecipientLike(recipient).receiveFlashLoan(tokens, amounts, fees, userData);

        for (uint256 i; i < tokens.length; ++i) {
            require(
                IMockERC20(tokens[i]).balanceOf(address(this)) >= pre[i] + fees[i],
                "FLASH_LOAN_NOT_REPAID"
            );
        }
    }
}

/// @notice A one-way swap venue: pulls `tokenIn` via transferFrom, pays out
///         `tokenOut` at a settable rate. The rate is what the fuzzer moves to
///         simulate an adversary shifting a pool between quote and execution.
contract MockRouter {
    address public immutable tokenIn;
    address public immutable tokenOut;
    uint256 public rateBps = 10_000; // 10_000 = 1:1

    constructor(address _in, address _out) {
        tokenIn = _in;
        tokenOut = _out;
    }

    function setRate(uint256 bps) external {
        rateBps = bps;
    }

    function swap(uint256 amountIn) external {
        IMockERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = (amountIn * rateBps) / 10_000;
        if (out > 0) IMockERC20(tokenOut).transfer(msg.sender, out);
    }

    /// A leg that pays out nothing — models a route hop that fails to deliver.
    function swapNoOutput(uint256 amountIn) external {
        IMockERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
    }
}
