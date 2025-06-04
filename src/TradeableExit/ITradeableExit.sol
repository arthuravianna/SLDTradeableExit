// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ICartesiDApp, Proof} from "@arthuravianna/cartesi-rollups/contracts/dapp/ICartesiDApp.sol";
import {IConsensus} from "@arthuravianna/cartesi-rollups/contracts/consensus/IConsensus.sol";

struct FastWithdrawalRequest {
    bytes id;
    uint256 timestamp;
    address token;
    uint256 amount;
    uint256 tickets_bought;
    uint256 redeemed;
}

struct Position {
    uint256 pos;
    bool exists;
}

// Request Errors
error FastWithdrawalRequestNotFound();

// Funding Errors
error ERC20TransferFailed();
error FundingTimeout();
error FundingAlreadyCompleted();

// Withdrawal Errors
error NotEnoughBalanceToWithdrawal();

// Events
event FundingFastWithdrawal(bytes request_id, address token, uint256 amount);

// Shared Liquidity Dynamic Tradeable Exit Interface
interface ITradeableExit {
    function requestFastWithdrawal(bytes calldata request_id, address token, uint256 amount, uint256 input_timestamp)
        external;

    function fundFastWithdrawalRequest(bytes calldata request_id, IERC20 token, uint256 amount) external;

    function withdraw(
        bytes calldata request_id,
        uint256 withdraw_amount,
        address destination,
        bytes calldata payload,
        Proof calldata proof
    ) external;

    function getRollupFastWithdrawalRequests(address rollup) external view returns (FastWithdrawalRequest[] memory);

    function getFastWithdrawalRequest(bytes calldata request_id) external view returns (FastWithdrawalRequest memory);

    function getFastWithdrawalRequestRemainingTicketsPrice(bytes memory request_id)
        external
        view
        returns (uint256, string memory, uint256, string memory);
}
