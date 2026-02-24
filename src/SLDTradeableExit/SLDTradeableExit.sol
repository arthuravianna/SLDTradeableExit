// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {TradeableExit, FastWithdrawalRequest, Position, FastWithdrawalRequestNotFound, ERC20TransferFailed, FundingTimeout, FundingAlreadyCompleted, NotEnoughBalanceToWithdrawal, FundingFastWithdrawal} from "../TradeableExit/TradeableExit.sol";

// ticket error
error TicketTransferFailed();
error NotEnoughTickets();

// Shared Liquidity Dynamic Tradeable Exit
abstract contract SLDTradeableExit is TradeableExit {
    mapping(bytes requestId => mapping(address recipient => uint256 amount))
        internal recipients;

    function getFastWithdrawalRequestRemainingTicketsPrice(
        bytes memory _requestId
    ) external view virtual returns (uint256, uint256, string memory);
}
