// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ICartesiDApp, Proof} from "@cartesi/rollups/contracts/dapp/ICartesiDApp.sol";
import {IConsensus} from "@cartesi/rollups/contracts/consensus/IConsensus.sol";
import {InputBox} from "@cartesi/rollups/contracts/inputs/InputBox.sol";
import "../SLDTradeableExit/SLDTradeableExit.sol";

error FastWithdrawalRequesterMismatch(address, address);
error VoucherIsNotAWithdrawal();
error FailedToExecuteVoucher();
error InvalidWithdrawalRequest(bytes32 expected, bytes32 actual);

// Shared Liquidity Dynamic Tradeable Exit
contract CartesiSLDTradeableExit is SLDTradeableExit {
    using SafeERC20 for IERC20;

    InputBox private immutable INPUT_BOX =
        InputBox(0x59b22D57D4f067708AB0c00552767405926dc768);
    uint256 private immutable PRECISION = 1e18;
    uint256 public constant DYNAMIC_FEE_INITIAL_BPS = 400000; // 0.004 = %0.04 variable fee
    uint256 public constant DYNAMIC_FEE_DECAY_PER_HOUR_BPS = 2381; // 0.00002381 = %0.0002381 fee decrease every hour, in 7 days it will be 0%

    function requestFastWithdrawal(
        bytes calldata _requestId,
        address _token,
        uint256 _amount,
        uint256 _inputTimestamp
    ) external payable override {
        (address rollup, address requester, , ) = _decodeRequestId(_requestId);
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

        FastWithdrawalRequest[] storage rollup_requests = dappRequests[rollup];
        rollup_requests.push(request);

        unchecked {
            idToRequestPosition[_requestId] = Position(
                uint64(rollup_requests.length - 1),
                true
            );
        }

        recipients[_requestId][msg.sender] = _amount;
    }

    function fundFastWithdrawal(
        bytes calldata _requestId,
        IERC20 _token,
        uint256 _amount
    ) external override {
        (address dapp, address requester, , ) = _decodeRequestId(_requestId);
        FastWithdrawalRequest storage request = _getFastWithdrawalRequest(
            dapp,
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

    /**
     *
     * @param _requestId requestId abi encodes
     * dapp address, fast withdrawal requester adderss,
     * inputIndex, and voucherIndex
     * @param _data data abi encodes
     * voucher's destination address, payload, and proof.
     * It also encodes inputKeccak and blockNumber
     */
    function withdrawFastWithdrawal(
        bytes calldata _requestId,
        bytes calldata _data
    ) external override {
        (
            address dapp,
            address requester,
            uint256 inputIndex,
            uint256 voucherIndex
        ) = _decodeRequestId(_requestId);
        FastWithdrawalRequest storage request = _getFastWithdrawalRequest(
            dapp,
            _requestId
        );

        // 0) Verify if fast withdrawal request is legit
        _validateWithdrawalRequest(
            dapp,
            requester,
            request.timestamp,
            inputIndex,
            _data // inputKeccak and blockNumber are inside _data
        );

        (
            address destination,
            bytes memory payload,
            Proof memory proof,
            ,

        ) = abi.decode(_data, (address, bytes, Proof, bytes32, uint256));

        require(destination == request.token, "Invalid voucher destination");

        bool success;
        {
            // scope to avoid stack too deep errors
            // 1) Verify voucher payload
            (address to, uint256 to_amount) = _decodeTransferPayload(payload);
            require(to == address(this), "Invalid voucher payload: 'to'");
            require(
                to_amount == request.amount,
                "Invalid voucher payload: 'to_amount'"
            );

            // 2) Was voucher executed?
            ICartesiDApp cartesi_dapp = ICartesiDApp(dapp);
            if (!cartesi_dapp.wasVoucherExecuted(inputIndex, voucherIndex)) {
                success = cartesi_dapp.executeVoucher(
                    destination,
                    payload,
                    proof
                );

                if (!success) {
                    revert FailedToExecuteVoucher();
                }
            }
        }

        // 3) Proceeds to withdraw
        // 3.1) ERC20 withdrawal
        request.amountRedeemed += recipients[_requestId][msg.sender];
        IERC20(request.token).safeTransfer(
            msg.sender,
            recipients[_requestId][msg.sender]
        );

        // 3.2) Native token (flat fee) withdrawal
        uint256 nativeTokenReward = (request.amount /
            recipients[_requestId][msg.sender]) * DEFAULT_FLAT_FEE;
        require(
            nativeTokenReward <= address(this).balance,
            "Insufficient balance in contract"
        );

        (success, ) = msg.sender.call{value: nativeTokenReward}("");
        require(success, "Failed to send native token");

        // 4) Delete request from list
        if (request.amountRedeemed >= request.amount) {
            _removeFastWithdrawalRequest(dapp, _requestId);
        }
    }

    function getFastWithdrawalRemainingAmountPrice(
        bytes memory _requestId
    ) external view override returns (uint256, uint256, string memory) {
        (address dapp, address requester, , ) = _decodeRequestId(_requestId);
        FastWithdrawalRequest memory request = _getFastWithdrawalRequest(
            dapp,
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
        (address dapp, , , ) = _decodeRequestId(_requestId);
        Position memory position = idToRequestPosition[_requestId];

        if (!position.exists) {
            revert FastWithdrawalRequestNotFound(_requestId);
        }

        return dappRequests[dapp][position.pos];
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

    function _decodeRequestId(
        bytes memory _requestId
    )
        internal
        pure
        returns (
            address dapp,
            address requester,
            uint256 inputIndex,
            uint256 voucherIndex
        )
    {
        (dapp, requester, inputIndex, voucherIndex) = abi.decode(
            _requestId,
            (address, address, uint256, uint256)
        );
    }

    /**
     *
     * @param _dapp rollup address
     * @param _requester withdrawal owner
     * @param _requestTimestamp L2 withdrawal request timestamp (block.timestamp)
     * @param _inputIndex index of the input (L2 withdrawal) in the input box
     * @param _data _data contains the inputKeccak and blockNumber used to
     *              reconstruct the input hash and compare it to the one stored
     *              in the input box
     * @notice Cartesi Rollups constructs an input hash from the input data
     *         (inputKeccak), the block number, timestamp, sender address and
     *         input index. This function reconstructs the input hash and
     *         compares it to the one stored in the input box to validate the
     *         owner of the withdrawal request. If someone tries to request a
     *         fast withdrawal on behalf of another user, the input hash will
     *         not match and the function will revert.
     */
    function _validateWithdrawalRequest(
        address _dapp,
        address _requester,
        uint256 _requestTimestamp,
        uint256 _inputIndex,
        bytes calldata _data
    ) internal view {
        (, , , bytes32 inputKeccak, uint256 blockNumber) = abi.decode(
            _data,
            (address, bytes, Proof, bytes32, uint256)
        );

        bytes32 metadataKeccak = keccak256(
            abi.encode(
                _requester,
                blockNumber,
                _requestTimestamp,
                0,
                _inputIndex
            )
        );

        bytes32 inputHash = keccak256(abi.encode(metadataKeccak, inputKeccak));
        bytes32 storedInputHash = INPUT_BOX.getInputHash(_dapp, _inputIndex);
        if (inputHash != storedInputHash) {
            revert InvalidWithdrawalRequest(storedInputHash, inputHash);
        }
    }

    function _decodeTransferPayload(
        bytes memory _payload
    ) internal pure returns (address to, uint256 amount) {
        require(_payload.length == 4 + 32 + 32, "Invalid payload length");

        bytes4 selector;
        assembly {
            selector := mload(add(_payload, 32))
        }
        require(
            selector == bytes4(keccak256("transfer(address,uint256)")),
            "Not a transfer() call"
        );

        assembly {
            to := mload(add(_payload, 36)) // selector(4 bytes) + address(32 bytes)
            amount := mload(add(_payload, 68))
        }
    }
}
