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
event FundingFastWithdrawal(bytes requestId, address token, uint256 amount);

// Shared Liquidity Dynamic Tradeable Exit Interface
abstract contract TradeableExit {
    uint256 internal constant DEFAULT_DISPUTE_PERIOD = 604800; // one week

    mapping(address => FastWithdrawalRequest[]) internal dappRequests;
    // {_requestId: <request position in dapp/rollup requests>}
    mapping(bytes => Position) internal idToRequestPosition;

    function requestFastWithdrawal(bytes calldata _requestId, address _token, uint256 _amount, uint256 _inputTimestamp)
        external virtual;

    function fundFastWithdrawalRequest(bytes calldata _requestId, IERC20 _token, uint256 _amount) external virtual;

    function withdraw(
        bytes calldata _requestId,
        bytes calldata _data
    ) external virtual;

    function getRollupFastWithdrawalRequests(address _rollup) external view virtual returns (FastWithdrawalRequest[] memory);

    function getFastWithdrawalRequest(bytes calldata _requestId) external view virtual returns (FastWithdrawalRequest memory);
}
