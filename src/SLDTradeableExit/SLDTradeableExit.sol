// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {
    ITradeableExit,
    FastWithdrawalRequest,
    Position,
    FastWithdrawalRequestNotFound,
    ERC20TransferFailed,
    FundingTimeout,
    FundingAlreadyCompleted,
    NotEnoughBalanceToWithdrawal,
    FundingFastWithdrawal
} from "../TradeableExit/ITradeableExit.sol";

// ticket error
error TicketTransferFailed();
error NotEnoughTickets();

// Shared Liquidity Dynamic Tradeable Exit
abstract contract SLDTradeableExit is ITradeableExit {
    uint256 internal constant default_dispute_period = 604800; // one week

    mapping(address => FastWithdrawalRequest[]) internal dapp_requests;
    // {request_id: <request position in dapp requests>}
    mapping(bytes => Position) internal id_to_request_position;

    mapping(bytes => mapping(address => uint256)) internal tickets;
}
