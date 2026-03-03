// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/IL1ArbitrumGateway.sol";
import "../SLDTradeableExit/SLDTradeableExit.sol";

error FastWithdrawalRequesterMismatch(address, address);

contract ArbitrumSLDTradeableExit is SLDTradeableExit {
    using SafeERC20 for IERC20;

    // Arbitrum is not an app-specific rollup, so we use a single rollup address for all requests
    address private immutable ARBITRUM_ROLLUP =
        0x4DCeB440657f21083db8aDd07665f8ddBe1DCfc0; // Arbitrum Rollup contract address on Ethereum mainnet
    uint256 public constant DYNAMIC_FEE_INITIAL_BPS = 400000; // 0.004 = %0.04 variable fee
    uint256 public constant DYNAMIC_FEE_DECAY_PER_HOUR_BPS = 2381; // 0.00002381 = %0.0002381 fee decrease every hour, in 7 days it will be 0%

    IL1ArbitrumGateway private immutable l1ArbitrumGateway;

    constructor(address _l1ArbitrumGateway) {
        l1ArbitrumGateway = IL1ArbitrumGateway(_l1ArbitrumGateway);
    }

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
            amountRedeemed: 0,
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

        recipients[_requestId][msg.sender] = _amount;
    }

    function fundFastWithdrawalRequest(
        bytes calldata _requestId,
        IERC20 _token,
        uint256 _amount
    ) external virtual override {
        (address requester, ) = _decodeRequestId(_requestId);
        FastWithdrawalRequest storage request = _getFastWithdrawalRequest(
            ARBITRUM_ROLLUP,
            _requestId
        );
        uint256 remainingAmountToFund = recipients[_requestId][requester];

        if (remainingAmountToFund == 0) {
            revert FundingAlreadyCompleted();
        }

        if (block.timestamp >= request.timestamp + DEFAULT_DISPUTE_PERIOD) {
            revert FundingTimeout();
        }

        // DYNAMIC PRICE
        uint256 delayedWithdrawalAmount = _amount +
            _calculateFee(_amount, request.timestamp);
        uint256 transferAmount;

        if (delayedWithdrawalAmount <= remainingAmountToFund) {
            transferAmount = _amount;
        } else {
            // if the liquidity provider wants to fund more than the remaining amount.
            // He provides the equivalent considering the fee.
            transferAmount =
                remainingAmountToFund -
                _calculateFee(remainingAmountToFund, request.timestamp);
            delayedWithdrawalAmount = remainingAmountToFund;
        }

        // send funds to Fast Withdrawal requester
        recipients[_requestId][requester] -= delayedWithdrawalAmount;
        recipients[_requestId][msg.sender] += delayedWithdrawalAmount;

        _token.safeTransferFrom(msg.sender, requester, transferAmount);

        emit FundingFastWithdrawal(_requestId, address(_token), transferAmount);
    }

    function withdraw(
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
        request.amountRedeemed += recipients[_requestId][msg.sender];
        IERC20(request.token).safeTransfer(
            msg.sender,
            recipients[_requestId][msg.sender]
        );

        // 2.2) Native token fee
        uint256 nativeTokenReward = (request.amount /
            recipients[_requestId][msg.sender]) * DEFAULT_FLAT_FEE;
        require(
            nativeTokenReward <= address(this).balance,
            "Insufficient balance in contract"
        );

        (bool success, ) = msg.sender.call{value: nativeTokenReward}("");
        require(success, "Failed to send native token");

        // 3) Delete request from list
        if (request.amountRedeemed >= request.amount) {
            _removeFastWithdrawalRequest(ARBITRUM_ROLLUP, _requestId);
        }
    }

    function getFastWithdrawalRemainingAmountPrice(
        bytes calldata _requestId
    ) external view virtual override returns (uint256, uint256, string memory) {
        (address requester, ) = _decodeRequestId(_requestId);
        FastWithdrawalRequest memory request = _getFastWithdrawalRequest(
            ARBITRUM_ROLLUP,
            _requestId
        );

        ERC20 token = ERC20(request.token);

        // every time the request is funded
        // the value to be received by the requester in the delayed withdrawal decreases.
        // So the remaining amount to be funded is the amount that the requester will receive
        // in a delayed withdrawal
        uint256 remainingAmount = recipients[_requestId][requester];
        uint256 remainingAmountPrice = remainingAmount -
            _calculateFee(remainingAmount, request.timestamp);

        return (remainingAmount, remainingAmountPrice, token.symbol());
    }

    function getFastWithdrawalRequest(
        bytes calldata _requestId
    ) external view returns (FastWithdrawalRequest memory) {
        return _getFastWithdrawalRequest(ARBITRUM_ROLLUP, _requestId);
    }

    function _decodeRequestId(
        bytes calldata _requestId
    ) internal pure returns (address requester, uint256 exitNum) {
        return abi.decode(_requestId, (address, uint256));
    }

    /**
     * @dev Calculates the current basis points (bps) for a given request timestamp.
     * @param _requestTimestamp The timestamp of the withdrawal request
     * @return The current basis points (bps) considering the dynamic fee decay
     */
    function _calculateBps(
        uint256 _requestTimestamp
    ) internal view returns (uint256) {
        uint256 bpsDecrease = ((block.timestamp - _requestTimestamp) / 3600) *
            DYNAMIC_FEE_DECAY_PER_HOUR_BPS;
        // verify if the current fee is already 0
        if (bpsDecrease >= DYNAMIC_FEE_INITIAL_BPS) {
            return 0;
        }
        return DYNAMIC_FEE_INITIAL_BPS - bpsDecrease;
    }

    /**
     * @dev Calculates the fee for a given amount and request timestamp.
     * @param _amount The amount for which the fee is calculated
     * @param _requestTimestamp The timestamp of the withdrawal request
     * @return The calculated fee considering the dynamic fee decay
     * @notice The initial fee is set at DYNAMIC_FEE_INITIAL_BPS and decays by DYNAMIC_FEE_DECAY_PER_HOUR_BPS every hour,
     * reaching 0% after 7 days.
     */
    function _calculateFee(
        uint256 _amount,
        uint256 _requestTimestamp
    ) internal view returns (uint256) {
        uint256 bps = _calculateBps(_requestTimestamp);
        return _calculateVariableFee(_amount, bps);
    }
}
