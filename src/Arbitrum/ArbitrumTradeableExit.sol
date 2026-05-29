// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/IL1ArbitrumGateway.sol";
import "../TradeableExit/TradeableExit.sol";

error FastWithdrawalRequesterMismatch(address, address);

contract ArbitrumTradeableExit is TradeableExit {
    using SafeERC20 for IERC20;

    // Arbitrum is not an app-specific rollup, so we use a single rollup address for all requests
    address private immutable ARBITRUM_ROLLUP =
        0x4DCeB440657f21083db8aDd07665f8ddBe1DCfc0; // Arbitrum Rollup contract address on Ethereum mainnet
    uint256 public constant BPS = 400000; // 0.004 = %0.04 variable fee

    IL1ArbitrumGateway private immutable l1ArbitrumGateway;

    constructor(address _l1ArbitrumGateway) {
        l1ArbitrumGateway = IL1ArbitrumGateway(_l1ArbitrumGateway);
    }

    mapping(bytes request_id => address recipient) internal recipients;

    function requestFastWithdrawal(
        bytes calldata _requestId,
        address _token,
        uint256 _amount,
        uint256 _inputTimestamp
    ) external payable virtual override {
        (address requester, ) = _decodeRequestId(_requestId);
        if (requester != msg.sender)
            revert FastWithdrawalRequesterMismatch(requester, msg.sender);
        if (msg.value < DEFAULT_FLAT_FEE) {
            revert FastWithdrawalRequestFeeNotPaid(
                _requestId,
                DEFAULT_FLAT_FEE
            );
        }

        FastWithdrawalRequest memory request = FastWithdrawalRequest({
            id: _requestId,
            token: _token,
            amount: _amount,
            amountRedeemed: 0, // unused on Tradeable Exit
            timestamp: _inputTimestamp
        });

        FastWithdrawalRequest[] storage rollup_requests = dappRequests[
            ARBITRUM_ROLLUP
        ];
        rollup_requests.push(request);

        unchecked {
            idToRequestPosition[_requestId] = Position(
                uint64(rollup_requests.length - 1),
                true
            );
        }

        recipients[_requestId] = msg.sender;
    }

    function fundFastWithdrawal(
        bytes calldata _requestId,
        IERC20 _token,
        uint256 _amount
    ) external virtual override {
        (address requester, ) = _decodeRequestId(_requestId);
        FastWithdrawalRequest storage request = _getFastWithdrawalRequest(
            ARBITRUM_ROLLUP,
            _requestId
        );

        if (block.timestamp >= request.timestamp + DEFAULT_DISPUTE_PERIOD) {
            revert FundingTimeout();
        }

        uint256 price = request.amount -
            _calculateVariableFee(request.amount, BPS);
        // send funds to Fast Withdrawal requester
        _token.safeTransferFrom(msg.sender, requester, price);

        // transfer delayed withdrawal from requester to liquidity provider
        recipients[_requestId] = msg.sender;

        emit FundingFastWithdrawal(_requestId, address(_token), price);
    }

    function withdrawFastWithdrawal(
        bytes calldata _requestId,
        bytes calldata _data
    ) external virtual override {
        // 1) validates the withdrawal:
        // 1.1) The delayed withdrawal requester must be the same address that requested the fast withdrawal.
        // 1.2) The value of the delayed withdrawal must match that of the fast withdrawal.
        // 1.3) The target (“to”) of the delayed withdrawal must be the TradeableExit contract.
        // 1.4) The token of the delayed withdrawal must be the same as that of the fast withdrawal.

        (address requester, uint256 exitNum) = _decodeRequestId(_requestId);
        FastWithdrawalRequest storage request = _getFastWithdrawalRequest(
            ARBITRUM_ROLLUP,
            _requestId
        );
        IL1ArbitrumGateway.WithdrawalInfo
            memory withdrawalInfo = l1ArbitrumGateway.getWithdrawalInfo(
                exitNum
            );

        require(
            withdrawalInfo.from == requester,
            "Delayed withdrawal requester does not match fast withdrawal requester"
        );
        require(
            withdrawalInfo.amount == request.amount,
            "Delayed withdrawal amount does not match fast withdrawal amount"
        );
        require(
            withdrawalInfo.to == address(this),
            "Delayed withdrawal target is not the TradeableExit contract"
        );
        require(
            withdrawalInfo.l1Token == request.token,
            "Delayed withdrawal token does not match fast withdrawal token"
        );

        // 2) Proceeds to withdraw
        // 2.1) ERC20 token
        require(
            recipients[_requestId] == msg.sender,
            "Not the withdrawal recipient"
        );

        IERC20(request.token).safeTransfer(msg.sender, request.amount);

        // 2.2) Native token fee
        require(
            DEFAULT_FLAT_FEE <= address(this).balance,
            "Insufficient balance in contract"
        );

        (bool success, ) = msg.sender.call{value: DEFAULT_FLAT_FEE}("");
        require(success, "Failed to send native token");

        // 3) Delete request from list
        _removeFastWithdrawalRequest(ARBITRUM_ROLLUP, _requestId);
    }

    function getRecipient(
        bytes calldata _requestId
    ) public view returns (address) {
        return recipients[_requestId];
    }

    function _decodeRequestId(
        bytes calldata _requestId
    ) internal pure returns (address requester, uint256 exitNum) {
        return abi.decode(_requestId, (address, uint256));
    }

    function getFastWithdrawalRequest(
        bytes calldata _requestId
    ) external view returns (FastWithdrawalRequest memory) {
        return _getFastWithdrawalRequest(ARBITRUM_ROLLUP, _requestId);
    }
}
