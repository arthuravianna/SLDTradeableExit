// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../TradeableExit/TradeableExit.sol";
import {ICartesiDApp, Proof} from "@cartesi/rollups/contracts/dapp/ICartesiDApp.sol";


error FastWithdrawalRequesterMismatch();
error VoucherIsNotAWithdrawal();
error FailedToExecuteVoucher();



contract CartesiTradeableExit is TradeableExit {
    constructor() {}
    // Tradeable Exit request_id = abi.encode(rollup, requester, price, input_index, voucher_index)

    // request_id -> recipient address
    // recipient of the withdrawal with request_id identifier
    mapping(bytes => address) internal recipients;

    function requestFastWithdrawal(
        bytes calldata request_id,
        address token,
        uint256 amount,
        uint256 input_timestamp
    ) external virtual override {
        (address rollup, address requester,,,) = abi.decode(request_id, (address, address, uint256, uint256, uint256));
        if (requester != msg.sender) revert FastWithdrawalRequesterMismatch();

        FastWithdrawalRequest memory request = FastWithdrawalRequest({
            id: request_id,
            token: token,
            amount: amount,
            tickets_bought: 0,  // unused on Tradeable Exit
            redeemed: 0,        // unused on Tradeable Exit
            timestamp: input_timestamp
        });

        FastWithdrawalRequest[] storage rollup_requests = dapp_requests[rollup];
        rollup_requests.push(request);

        unchecked {
            id_to_request_position[request_id] = Position(uint64(rollup_requests.length - 1), true);
        }

        recipients[request_id] = msg.sender;
    }

    function fundFastWithdrawalRequest(
        bytes calldata request_id,
        IERC20 token,
        uint256 amount
    ) external virtual override {
        (address dapp, address requester, uint256 price,,) = abi.decode(request_id, (address, address, uint256, uint256, uint256));
        FastWithdrawalRequest storage request = _getFastWithdrawalRequest(dapp, request_id);

        if (block.timestamp >= request.timestamp + default_dispute_period) {
            revert FundingTimeout();
        }

        // send funds to Fast Withdrawal requester
        bool success = token.transferFrom(msg.sender, requester, price);
        if (!success) {
            revert ERC20TransferFailed();
        }

        // transfer tickets from requester to liquidity provider
        recipients[request_id] = msg.sender;

        emit FundingFastWithdrawal(request_id, address(token), price);
    }

    function withdraw(
        bytes calldata request_id,
        bytes calldata data
    ) external virtual override {
        (address dapp,,, uint256 input_index, uint256 voucher_index) =
            abi.decode(request_id, (address, address, uint256, uint256, uint256));
        FastWithdrawalRequest storage request = _getFastWithdrawalRequest(dapp, request_id);

        (address destination, bytes memory payload, Proof memory proof) =
            abi.decode(data, (address, bytes, Proof));

        // 1) Verify voucher payload
        require(destination == request.token, "Invalid voucher destination");

        {
            // scope to avoid stack too deep errors
            (address to, uint256 to_amount) = _decodeTransferPayload(payload);
            require(to == address(this), "Invalid voucher payload: 'to'");
            require(to_amount == request.amount, "Invalid voucher payload: 'to_amount'");

            // 2) Was voucher executed?
            ICartesiDApp cartesi_dapp = ICartesiDApp(dapp);
            if (!cartesi_dapp.wasVoucherExecuted(input_index, voucher_index)) {
                bool success = cartesi_dapp.executeVoucher(destination, payload, proof);

                if (!success) {
                    revert FailedToExecuteVoucher();
                }
            }
        }

        // 3) Proceeds to withdraw
        require(recipients[request_id] == msg.sender, "Not the withdrawal recipient");

        IERC20 token = IERC20(request.token);
        token.transfer(msg.sender, request.amount);

        // 5) Delete request from list
        _removeFastWithdrawalRequest(dapp, request_id);
    }

    function getRollupFastWithdrawalRequests(
        address rollup
    ) external view virtual override returns (FastWithdrawalRequest[] memory) {
        return dapp_requests[rollup];
    }

    function getFastWithdrawalRequest(
        bytes calldata request_id
    ) external view virtual override returns (FastWithdrawalRequest memory) {
        (address dapp,,,,) = abi.decode(request_id, (address, address, uint256, uint256, uint256));
        Position memory position = id_to_request_position[request_id];

        if (!position.exists) {
            revert FastWithdrawalRequestNotFound();
        }

        return dapp_requests[dapp][position.pos];
    }




    function getRecipient(bytes calldata request_id) public view returns (address) {
        return recipients[request_id];
    }

    function _getFastWithdrawalRequest(address dapp, bytes memory request_id)
        private
        view
        returns (FastWithdrawalRequest storage)
    {
        Position memory position = id_to_request_position[request_id];
        if (!position.exists) {
            revert FastWithdrawalRequestNotFound();
        }

        return dapp_requests[dapp][position.pos];
    }

    function _decodeTransferPayload(bytes memory payload) internal pure returns (address to, uint256 amount) {
        require(payload.length == 4 + 32 + 32, "Invalid payload length");

        bytes4 selector;
        assembly {
            selector := mload(add(payload, 32))
        }
        require(selector == bytes4(keccak256("transfer(address,uint256)")), "Not a transfer() call");

        assembly {
            to := mload(add(payload, 36)) // selector(4 bytes) + address(32 bytes)
            amount := mload(add(payload, 68))
        }
    }

    function _removeFastWithdrawalRequest(address dapp, bytes memory request_id) internal {
        Position storage position = id_to_request_position[request_id];

        if (!position.exists) {
            revert FastWithdrawalRequestNotFound();
        }

        uint256 len = dapp_requests[dapp].length;

        require(position.pos < len);

        //delete id_to_request_position[request_id];
        position.exists = false;

        // replace item in "pos" by the last item
        FastWithdrawalRequest memory last_request = dapp_requests[dapp][len - 1];
        id_to_request_position[last_request.id] = Position(position.pos, true);
        dapp_requests[dapp][position.pos] = last_request;

        dapp_requests[dapp].pop();
    }
}