// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {
    TradeableExit,
    FastWithdrawalRequest,
    Position,
    FastWithdrawalRequestNotFound,
    ERC20TransferFailed,
    FundingTimeout,
    FundingAlreadyCompleted,
    NotEnoughBalanceToWithdrawal,
    FundingFastWithdrawal
} from "../TradeableExit/TradeableExit.sol";

// ticket error
error TicketTransferFailed();
error NotEnoughTickets();

// Shared Liquidity Dynamic Tradeable Exit
abstract contract SLDTradeableExit is TradeableExit {
    mapping(bytes => mapping(address => uint256)) internal tickets;

    function getFastWithdrawalRequestRemainingTicketsPrice(bytes memory request_id)
    external
    view
    virtual
    returns (uint256, uint256, string memory);

}
