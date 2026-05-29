// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

struct FastWithdrawalRequest {
    bytes id;
    address token;
    uint256 timestamp;
    uint256 amount;
    uint256 amountRedeemed; // amount redeemed by the liquidity providers after the dispute period
}

struct Position {
    uint64 pos;
    bool exists;
}

// Request Errors
error FastWithdrawalRequestNotFound(bytes requestId);
error FastWithdrawalRequestFeeNotPaid(bytes requestId, uint256 requiredFee);

// Funding Errors
error ERC20TransferFailed();
error FundingTimeout();
error FundingAlreadyCompleted();

// Withdrawal Errors
error NotEnoughBalanceToWithdrawal();

// Events
event FundingFastWithdrawal(bytes requestId, address token, uint256 amount);

// Tradeable Exit Interface
abstract contract TradeableExit {
    uint256 internal constant DEFAULT_DISPUTE_PERIOD = 604800; // one week
    
    // We have two types of fees: a flat fee and a variable fee. 
    // The flat fee is a fixed amount that is paid regardless of the withdrawal amount with the native token. 
    // The variable fee is calculated as a percentage of the amount to be withdrawn. 
    // The total fee is the sum of the flat fee and the variable fee.
    // reference: https://docs.debridge.com/dln-details/overview/fee-structure
    uint256 public constant DEFAULT_FLAT_FEE = 1 * 10 ** 15; // 0.001 Native Token
    uint256 internal constant DEFAULT_BASIS_POINTS_FACTOR = 100000000; // 100000000 = 100%

    mapping(address => FastWithdrawalRequest[]) internal dappRequests;
    // {_requestId: <request position in dapp/rollup requests>}
    mapping(bytes => Position) internal idToRequestPosition;

    // must be payable to receive the flat fee in native token
    // the fees are paid by the requester of the fast withdrawal request when they create the request 
    // and are used to incentivize liquidity providers to fund the request
    function requestFastWithdrawal(bytes calldata _requestId, address _token, uint256 _amount, uint256 _inputTimestamp)
        external virtual payable;

    function fundFastWithdrawalRequest(bytes calldata _requestId, IERC20 _token, uint256 _amount) external virtual;

    function withdraw(
        bytes calldata _requestId,
        bytes calldata _data
    ) external virtual;

    function getRollupFastWithdrawalRequests(
        address _rollup
    ) external view virtual returns (FastWithdrawalRequest[] memory) {
        return dappRequests[_rollup];
    }

    function getWithdrawalPrice(uint256 _amount, uint256 bps) public pure returns (uint256) {
        uint256 variableFee = _calculateVariableFee(_amount, bps);
        return _amount - variableFee;
    }

    // Internal functions
    function _calculateVariableFee(uint256 _amount, uint256 bps) internal pure returns (uint256) {
        return (_amount * bps) / DEFAULT_BASIS_POINTS_FACTOR;
    }

    function _getFastWithdrawalRequest(
        address dapp,
        bytes memory _requestId
    ) internal view returns (FastWithdrawalRequest storage) {
        Position memory position = idToRequestPosition[_requestId];
        if (!position.exists) {
            revert FastWithdrawalRequestNotFound(_requestId);
        }

        return dappRequests[dapp][position.pos];
    }

    function _removeFastWithdrawalRequest(
        address _dapp,
        bytes memory _requestId
    ) internal virtual {
        Position storage position = idToRequestPosition[_requestId];

        if (!position.exists) {
            revert FastWithdrawalRequestNotFound(_requestId);
        }

        uint256 len = dappRequests[_dapp].length;

        require(position.pos < len);

        //delete idToRequestPosition[request_id];
        position.exists = false;

        // replace item in "pos" by the last item
        FastWithdrawalRequest memory lastRequest = dappRequests[_dapp][len - 1];
        idToRequestPosition[lastRequest.id] = Position(position.pos, true);
        dappRequests[_dapp][position.pos] = lastRequest;
        dappRequests[_dapp].pop();
    }
}
