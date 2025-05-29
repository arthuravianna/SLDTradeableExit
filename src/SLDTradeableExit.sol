// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ICartesiDApp, Proof} from "@arthuravianna/cartesi-rollups/contracts/dapp/ICartesiDApp.sol";
//import {OutputValidityProof} from "@cartesi/rollups/contracts/library/LibOutputValidation.sol";
import {IConsensus} from "@arthuravianna/cartesi-rollups/contracts/consensus/IConsensus.sol";
import {FastWithdrawalTicket} from "./FastWithdrawalTicket.sol";

struct FastWithdrawalRequest {
    address requester;
    uint256 input_index;
    uint256 voucher_index;
    uint256 timestamp;
    address token;
    uint256 amount;
}

// Funding Errors
error ERC20TransferFailed();
error TicketTransferFailed();

// Withdrawal Errors
error VoucherIsNotAWithdrawal();
error FailedToExecuteVoucher();
error NotEnoughTickets();

// Events
event FundingFastWithdrawal(address dapp, uint256 input_index, uint256 voucher_index, address token, uint256 amount);

// Shared Liquidity Dynamic Tradeable Exit
contract SLDTradeableExit {
    FastWithdrawalTicket public ticket;
    uint256 constant default_dispute_period = 604800; // one week

    mapping(address => FastWithdrawalRequest[]) private dapp_requests;
    // {request_id: <request position in dapp requests>}
    mapping(bytes => uint256) private id_to_request_position;

    constructor(address tokenAddress) {
        ticket = FastWithdrawalTicket(tokenAddress);
    }

    function _removeFastWithdrawalRequest(address dapp, bytes memory request_id) private {
        uint256 pos = id_to_request_position[request_id];
        uint256 len = dapp_requests[dapp].length;

        require(pos < len);

        delete id_to_request_position[request_id];

        // replace item in "pos" by the last item
        bytes memory aux_request_id =
            abi.encode(dapp, dapp_requests[dapp][len - 1].input_index, dapp_requests[dapp][len - 1].voucher_index);
        id_to_request_position[aux_request_id] = pos;
        dapp_requests[dapp][pos] = dapp_requests[dapp][len - 1];

        dapp_requests[dapp].pop();
    }

    function requestFastWithdrawal(
        address token,
        uint256 amount,
        address dapp,
        uint256 input_index,
        uint256 voucher_index,
        uint256 input_timestamp
    ) public {
        // register fast withdrawal request
        FastWithdrawalRequest memory request;
        request.requester = msg.sender;
        request.token = token;
        request.input_index = input_index;
        request.voucher_index = voucher_index;
        request.amount = amount;
        request.timestamp = input_timestamp;

        dapp_requests[dapp].push(request);
        bytes memory request_id = abi.encode(dapp, input_index, voucher_index);
        id_to_request_position[request_id] = dapp_requests[dapp].length - 1;

        ticket.mint(request_id, msg.sender, amount);
    }

    function getDappFastWithdrawalRequests(address dapp) public view returns (FastWithdrawalRequest[] memory) {
        return dapp_requests[dapp];
    }

    function getFastWithdrawalRequest(address dapp, uint256 input_index, uint256 voucher_index)
        public
        view
        returns (FastWithdrawalRequest memory)
    {
        bytes memory request_id = abi.encode(dapp, input_index, voucher_index);
        uint256 pos = id_to_request_position[request_id];

        return dapp_requests[dapp][pos];
    }

    function getFastWithdrawalRequestPrice(address dapp, uint256 input_index, uint256 voucher_index)
        public
        view
        returns (uint256, string memory)
    {
        bytes memory request_id = abi.encode(dapp, input_index, voucher_index);
        FastWithdrawalRequest memory request = _getFastWithdrawalRequest(dapp, request_id);

        ERC20 token = ERC20(request.token);
        uint256 ticket_proportion = _calculate_ticket_proportion(request.timestamp);

        return (ticket_proportion, token.symbol());
    }

    function _getFastWithdrawalRequest(address dapp, bytes memory request_id)
        private
        view
        returns (FastWithdrawalRequest memory)
    {
        uint256 pos = id_to_request_position[request_id];

        return dapp_requests[dapp][pos];
    }

    // Tickets are exchange by an ERC20 token once the Rollup state is final.
    // The fee charged by the L2 validators are included in the ticket price,
    // tickets worth less than the actual token, initial proportion is 1.168:1.
    // With time the price of the ticket gets closer to the price of the token.
    function _calculate_ticket_proportion(uint256 request_timestamp) private view returns (uint256) {
        uint256 initial_value = 1168000000000000000; // 1.168 * 1e18
        uint256 x = block.timestamp - request_timestamp;

        return initial_value - (1000000000000000) * (x / 3600);
    }

    function fundFastWithdrawalRequest(
        address dapp,
        uint256 input_index,
        uint256 voucher_index,
        IERC20 token,
        uint256 amount
    ) public {
        bytes memory request_id = abi.encode(dapp, input_index, voucher_index);
        FastWithdrawalRequest memory request = _getFastWithdrawalRequest(dapp, request_id);

        if (block.timestamp >= request.timestamp + default_dispute_period) {
            revert("FAST_WITHDRAWAL_TIMEOUT");
        }

        // DYNAMIC PRICE
        uint256 ticket_proportion = _calculate_ticket_proportion(request.timestamp);
        uint256 ticket_to_token = amount / ticket_proportion;
        uint256 ticket_amount_available = ticket.balanceOf(request_id, request.requester);
        uint256 transfer_amount;

        // verify the amount of tickets available
        if (ticket_to_token <= ticket_amount_available) {
            transfer_amount = amount;
        } else {
            transfer_amount = ticket_amount_available / ticket_proportion;
            ticket_to_token = transfer_amount / ticket_proportion;
            //_removeFastWithdrawalRequest(dapp, request_id);
        }

        // send funds to Fast Withdrawal requester
        bool success = token.transferFrom(msg.sender, request.requester, transfer_amount);
        if (!success) {
            revert ERC20TransferFailed();
        }

        // transfer tickets from requester to liquidity provider
        success = ticket.transferFrom(request.requester, msg.sender, ticket_to_token);
        if (!success) {
            revert TicketTransferFailed();
        }

        emit FundingFastWithdrawal(dapp, input_index, voucher_index, address(token), transfer_amount);
    }

    function withdraw(
        address dapp,
        uint256 input_index,
        uint256 voucher_index,
        uint256 withdraw_amount,
        address destination,
        bytes calldata payload,
        Proof calldata proof
    ) public {
        bytes memory request_id = abi.encode(dapp, input_index, voucher_index);
        FastWithdrawalRequest memory request = _getFastWithdrawalRequest(dapp, request_id);

        // 1) Verify voucher payload
        assert(destination == request.token);

        (address to, uint256 to_amount) = _decodeTransferPayload(payload);
        assert(to == address(this));
        assert(to_amount == request.amount);
        // 2) Validate voucher
        ICartesiDApp cartesi_dapp = ICartesiDApp(dapp);
        // IConsensus consensus = cartesi_dapp.getConsensus();
        // (bytes32 epochHash, ,) = consensus.getClaim(dapp, proof.context);
        // proof.validity.validateVoucher(destination, payload, epochHash);

        // reverts if proof isn't valid
        cartesi_dapp.validateVoucher(destination, payload, proof);

        // 3) Was voucher executed?
        if (!cartesi_dapp.wasVoucherExecuted(input_index, voucher_index)) {
            bool success = cartesi_dapp.executeVoucher(destination, payload, proof);

            if (!success) {
                revert FailedToExecuteVoucher();
            }
        }
        // Proceeds to withdraw
        uint256 balance = ticket.balanceOf(request_id, msg.sender);
        if (withdraw_amount > balance) {
            revert NotEnoughTickets();
        }

        IERC20 token = IERC20(request.token);
        token.transfer(msg.sender, withdraw_amount);
        ticket.burn(request_id, msg.sender, withdraw_amount);

        // 4) Request exists?
        // YES
        // Delete request from list
    }

    function _decodeTransferPayload(bytes calldata payload) private pure returns (address to, uint256 amount) {
        require(payload.length == 4 + 32 + 32, "Invalid payload length");

        // Skip the first 4 bytes (function selector)
        bytes calldata data = payload[4:];

        (to, amount) = abi.decode(data, (address, uint256));
    }
}
