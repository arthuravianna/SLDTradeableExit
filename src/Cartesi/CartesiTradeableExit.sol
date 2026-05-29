// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICartesiDApp, Proof} from "@cartesi/rollups/contracts/dapp/ICartesiDApp.sol";
import {InputBox} from "@cartesi/rollups/contracts/inputs/InputBox.sol";
import "../TradeableExit/TradeableExit.sol";

error FastWithdrawalRequesterMismatch(address, address);
error VoucherIsNotAWithdrawal();
error FailedToExecuteVoucher();
error InvalidWithdrawalRequest(bytes32 expected, bytes32 actual);

contract CartesiTradeableExit is TradeableExit {
    using SafeERC20 for IERC20;

    InputBox private immutable INPUT_BOX =
        InputBox(0x59b22D57D4f067708AB0c00552767405926dc768);
    uint256 public constant BPS = 4; // %0.04 variable fee

    constructor() {}

    // recipient of the delayed withdrawal with request_id identifier
    // once a request is traded, we update the recipient to the liquidity provider
    // that funded the request
    mapping(bytes request_id => address recipient) internal recipients;

    function requestFastWithdrawal(
        bytes calldata _requestId,
        address _token,
        uint256 _amount,
        uint256 _inputTimestamp
    ) external payable virtual override {
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
            amountRedeemed: 0, // unused on Tradeable Exit
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

        recipients[_requestId] = msg.sender;
    }

    function fundFastWithdrawalRequest(
        bytes calldata _requestId,
        IERC20 _token,
        uint256 _amount // unused
    ) external virtual override {
        (address dapp, address requester, , ) = _decodeRequestId(_requestId);
        FastWithdrawalRequest storage request = _getFastWithdrawalRequest(
            dapp,
            _requestId
        );

        if (block.timestamp >= request.timestamp + DEFAULT_DISPUTE_PERIOD) {
            revert FundingTimeout();
        }

        uint256 price = request.amount -
            _calculateVariableFee(request.amount, BPS);
        // send funds to Fast Withdrawal requester
        _token.safeTransferFrom(msg.sender, requester, price);

        // transfer tickets from requester to liquidity provider
        recipients[_requestId] = msg.sender;

        emit FundingFastWithdrawal(_requestId, address(_token), price);
    }

    /**
     *
     * @param _requestId requestId abi encodes
     * dapp address, fast withdrawal requester adderss,
     * fast withdrawal price, inputIndex, and voucherIndex
     * @param _data data abi encodes
     * voucher's destination address, payload, and proof.
     * It also encodes inputKeccak and blockNumber
     */
    function withdraw(
        bytes calldata _requestId,
        bytes calldata _data
    ) external virtual override {
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

        (address destination, bytes memory payload, Proof memory proof) = abi
            .decode(_data, (address, bytes, Proof));

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
        // 3.1) ERC20 token
        require(
            recipients[_requestId] == msg.sender,
            "Not the withdrawal recipient"
        );

        IERC20 token = IERC20(request.token);
        token.safeTransfer(msg.sender, request.amount);

        // 3.2) Native token fee
        require(
            DEFAULT_FLAT_FEE <= address(this).balance,
            "Insufficient balance in contract"
        );

        (success, ) = msg.sender.call{value: DEFAULT_FLAT_FEE}("");
        require(success, "Failed to send native token");

        // 4) Delete request from list
        _removeFastWithdrawalRequest(dapp, _requestId);
    }

    function getFastWithdrawalRequest(
        bytes calldata _requestId
    ) external view virtual returns (FastWithdrawalRequest memory) {
        (address dapp, , , ) = _decodeRequestId(_requestId);
        Position memory position = idToRequestPosition[_requestId];

        if (!position.exists) {
            revert FastWithdrawalRequestNotFound(_requestId);
        }

        return dappRequests[dapp][position.pos];
    }

    function getRecipient(
        bytes calldata _requestId
    ) public view returns (address) {
        return recipients[_requestId];
    }

    function _decodeRequestId(
        bytes calldata _requestId
    )
        internal
        pure
        returns (
            address rollup,
            address requester,
            uint256 inputIndex,
            uint256 voucherIndex
        )
    {
        return abi.decode(_requestId, (address, address, uint256, uint256));
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
     *         withdrawal on behalf of another user, the input hash will not
     *         match and the function will revert.
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
