// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Proof} from "@cartesi/rollups/contracts/dapp/ICartesiDApp.sol";

struct FastWithdrawalRequest {
    bytes id;
    address token;
    uint256 timestamp;
    uint256 amount;
    uint256 tickets_bought;
    uint256 redeemed;
}

struct Position {
    uint64 pos;
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
abstract contract TradeableExit {
    uint256 internal constant default_dispute_period = 604800; // one week

    mapping(address => FastWithdrawalRequest[]) internal dapp_requests;
    // {request_id: <request position in dapp/rollup requests>}
    mapping(bytes => Position) internal id_to_request_position;

    function requestFastWithdrawal(bytes calldata request_id, address token, uint256 amount, uint256 input_timestamp)
        external virtual;

    function fundFastWithdrawalRequest(bytes calldata request_id, IERC20 token, uint256 amount) external virtual;

    function withdraw(
        bytes calldata request_id,
        address destination,
        bytes calldata payload,
        Proof calldata proof
    ) external virtual;

    function getRollupFastWithdrawalRequests(address rollup) external view virtual returns (FastWithdrawalRequest[] memory);

    function getFastWithdrawalRequest(bytes calldata request_id) external view virtual returns (FastWithdrawalRequest memory);
}
