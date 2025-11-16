// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../TradeableExit/TradeableExit.sol";
import {ICartesiDApp, Proof} from "@cartesi/rollups/contracts/dapp/ICartesiDApp.sol";

error FastWithdrawalRequesterMismatch();
error VoucherIsNotAWithdrawal();
error FailedToExecuteVoucher();

contract CartesiTradeableExit is TradeableExit {
    using SafeERC20 for IERC20;

    constructor() {}

    // Tradeable Exit request_id = abi.encode(rollup, requester, price, input_index, voucher_index)

    // request_id -> recipient address
    // recipient of the withdrawal with request_id identifier
    mapping(bytes request_id => address recipient) internal recipients;

    function requestFastWithdrawal(
        bytes calldata _requestId,
        address _token,
        uint256 _amount,
        uint256 _inputTimestamp
    ) external virtual override {
        (address rollup, address requester, , , ) = abi.decode(
            _requestId,
            (address, address, uint256, uint256, uint256)
        );
        if (requester != msg.sender) revert FastWithdrawalRequesterMismatch();

        FastWithdrawalRequest memory request = FastWithdrawalRequest({
            id: _requestId,
            token: _token,
            amount: _amount,
            tickets_bought: 0, // unused on Tradeable Exit
            redeemed: 0, // unused on Tradeable Exit
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
        uint256 _amount
    ) external virtual override {
        (address dapp, address requester, uint256 price, , ) = abi.decode(
            _requestId,
            (address, address, uint256, uint256, uint256)
        );
        FastWithdrawalRequest storage request = _getFastWithdrawalRequest(
            dapp,
            _requestId
        );

        if (block.timestamp >= request.timestamp + DEFAULT_DISPUTE_PERIOD) {
            revert FundingTimeout();
        }

        // send funds to Fast Withdrawal requester
        _token.safeTransferFrom(msg.sender, requester, price);

        // transfer tickets from requester to liquidity provider
        recipients[_requestId] = msg.sender;

        emit FundingFastWithdrawal(_requestId, address(_token), price);
    }

    function withdraw(
        bytes calldata _requestId,
        bytes calldata _data
    ) external virtual override {
        (address dapp, , , uint256 input_index, uint256 voucher_index) = abi
            .decode(_requestId, (address, address, uint256, uint256, uint256));
        FastWithdrawalRequest storage request = _getFastWithdrawalRequest(
            dapp,
            _requestId
        );

        (address destination, bytes memory payload, Proof memory proof) = abi
            .decode(_data, (address, bytes, Proof));

        // 1) Verify voucher payload
        require(destination == request.token, "Invalid voucher destination");

        {
            // scope to avoid stack too deep errors
            (address to, uint256 to_amount) = _decodeTransferPayload(payload);
            require(to == address(this), "Invalid voucher payload: 'to'");
            require(
                to_amount == request.amount,
                "Invalid voucher payload: 'to_amount'"
            );

            // 2) Was voucher executed?
            ICartesiDApp cartesi_dapp = ICartesiDApp(dapp);
            if (!cartesi_dapp.wasVoucherExecuted(input_index, voucher_index)) {
                bool success = cartesi_dapp.executeVoucher(
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
        require(
            recipients[_requestId] == msg.sender,
            "Not the withdrawal recipient"
        );

        IERC20 token = IERC20(request.token);
        token.safeTransfer(msg.sender, request.amount);

        // 5) Delete request from list
        _removeFastWithdrawalRequest(dapp, _requestId);
    }

    function getRollupFastWithdrawalRequests(
        address _rollup
    ) external view virtual override returns (FastWithdrawalRequest[] memory) {
        return dappRequests[_rollup];
    }

    function getFastWithdrawalRequest(
        bytes calldata _requestId
    ) external view virtual override returns (FastWithdrawalRequest memory) {
        (address dapp, , , , ) = abi.decode(
            _requestId,
            (address, address, uint256, uint256, uint256)
        );
        Position memory position = idToRequestPosition[_requestId];

        if (!position.exists) {
            revert FastWithdrawalRequestNotFound();
        }

        return dappRequests[dapp][position.pos];
    }

    function getRecipient(
        bytes calldata _requestId
    ) public view returns (address) {
        return recipients[_requestId];
    }

    function _getFastWithdrawalRequest(
        address dapp,
        bytes memory _requestId
    ) private view returns (FastWithdrawalRequest storage) {
        Position memory position = idToRequestPosition[_requestId];
        if (!position.exists) {
            revert FastWithdrawalRequestNotFound();
        }

        return dappRequests[dapp][position.pos];
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

    function _removeFastWithdrawalRequest(
        address _dapp,
        bytes memory _requestId
    ) internal {
        Position storage position = idToRequestPosition[_requestId];

        if (!position.exists) {
            revert FastWithdrawalRequestNotFound();
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
