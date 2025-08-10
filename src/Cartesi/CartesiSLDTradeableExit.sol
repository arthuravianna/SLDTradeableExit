// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ICartesiDApp, Proof} from "@cartesi/rollups/contracts/dapp/ICartesiDApp.sol";
import {IConsensus} from "@cartesi/rollups/contracts/consensus/IConsensus.sol";
import "../SLDTradeableExit/SLDTradeableExit.sol";

error FastWithdrawalRequesterMismatch();
error VoucherIsNotAWithdrawal();
error FailedToExecuteVoucher();

// Shared Liquidity Dynamic Tradeable Exit
contract CartesiSLDTradeableExit is SLDTradeableExit {

    function requestFastWithdrawal(bytes calldata request_id, address token, uint256 amount, uint256 input_timestamp) external override {
        (address rollup, address requester,,) = abi.decode(request_id, (address, address, uint256, uint256));
        if (requester != msg.sender) revert FastWithdrawalRequesterMismatch();

        FastWithdrawalRequest memory request = FastWithdrawalRequest({
            id: request_id,
            token: token,
            amount: amount,
            tickets_bought: 0,
            redeemed: 0,
            timestamp: input_timestamp
        });

        FastWithdrawalRequest[] storage rollup_requests = dapp_requests[rollup];
        rollup_requests.push(request);

        unchecked {
            id_to_request_position[request_id] = Position(uint64(rollup_requests.length - 1), true);
        }

        tickets[request_id][msg.sender] = amount;
    }


    function getTickets(bytes calldata request_id, address account) public view returns (uint256) {
        return tickets[request_id][account];
    }
    function getRollupFastWithdrawalRequests(address rollup) external view override returns (FastWithdrawalRequest[] memory) {
        return dapp_requests[rollup];
    }

    function getFastWithdrawalRequest(bytes calldata request_id) external view override returns (FastWithdrawalRequest memory) {
        (address dapp,,,) = abi.decode(request_id, (address, address, uint256, uint256));
        Position memory position = id_to_request_position[request_id];

        if (!position.exists) {
            revert FastWithdrawalRequestNotFound();
        }

        return dapp_requests[dapp][position.pos];
    }

    function getFastWithdrawalRequestRemainingTicketsPrice(bytes calldata request_id)
        external
        view
        override
        returns (uint256, uint256, string memory)
    {
        (address dapp,,,) = abi.decode(request_id, (address, address, uint256, uint256));
        FastWithdrawalRequest memory request = _getFastWithdrawalRequest(dapp, request_id);

        ERC20 token = ERC20(request.token);

        uint256 remaining = request.amount - request.tickets_bought;
        uint256 ticket_proportion = _calculate_ticket_proportion(request.timestamp);
        uint256 token_to_ticket = remaining * ticket_proportion;

        return (remaining, token_to_ticket, token.symbol());
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

    // Tickets are exchange by an ERC20 token once the Rollup state is final.
    // The fee charged by the L2 validators are included in the ticket price,
    // tickets worth less than the actual token, initial proportion is 1.168:1.
    // With time the price of the ticket gets closer to the price of the token.
    uint256 internal constant INITIAL_PROPORTION = 1168e15;
    uint256 internal constant DECAY_PER_HOUR = 1e15;
    function _calculate_ticket_proportion(uint256 request_timestamp) internal view returns (uint256) {
        unchecked {
            uint256 hours_passed = (block.timestamp - request_timestamp) / 3600;
            uint256 decay = DECAY_PER_HOUR * hours_passed;
            if (decay >= INITIAL_PROPORTION) {
                return 0; // prevent underflow and represent proportion floor
            }
            return INITIAL_PROPORTION - decay;
        }
    }

    function fundFastWithdrawalRequest(bytes calldata request_id, IERC20 token, uint256 amount) external override {
        (address dapp, address requester,,) = abi.decode(request_id, (address, address, uint256, uint256));
        FastWithdrawalRequest storage request = _getFastWithdrawalRequest(dapp, request_id);
        uint256 ticket_amount_available = tickets[request_id][requester];

        if (ticket_amount_available == 0) {
            revert FundingAlreadyCompleted();
        }

        if (block.timestamp >= request.timestamp + default_dispute_period) {
            revert FundingTimeout();
        }

        // DYNAMIC PRICE
        uint256 ticket_proportion = _calculate_ticket_proportion(request.timestamp);
        uint256 token_to_ticket = (amount * ticket_proportion) / 1e18;
        uint256 transfer_amount;

        // verify the amount of tickets available
        if (token_to_ticket <= ticket_amount_available) {
            transfer_amount = amount;
        } else {
            transfer_amount = (ticket_amount_available * 1e18) / ticket_proportion;
            token_to_ticket = ticket_amount_available;
        }

        // send funds to Fast Withdrawal requester
        bool success = token.transferFrom(msg.sender, requester, transfer_amount);
        if (!success) {
            revert ERC20TransferFailed();
        }

        // transfer tickets from requester to liquidity provider
        tickets[request_id][requester] -= token_to_ticket;
        tickets[request_id][msg.sender] += token_to_ticket;

        request.tickets_bought += token_to_ticket;

        emit FundingFastWithdrawal(request_id, address(token), transfer_amount);
    }

    function withdraw(
        bytes calldata request_id,
        address destination,
        bytes calldata payload,
        Proof calldata proof
    ) external override {
        (address dapp,, uint256 input_index, uint256 voucher_index) =
            abi.decode(request_id, (address, address, uint256, uint256));
        FastWithdrawalRequest storage request = _getFastWithdrawalRequest(dapp, request_id);

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
        IERC20 token = IERC20(request.token);
        token.transfer(msg.sender, tickets[request_id][msg.sender]);

        request.redeemed += tickets[request_id][msg.sender];

        // 5) Delete request from list
        if (request.redeemed >= request.amount) {
            _removeFastWithdrawalRequest(dapp, request_id);
        }
    }

    function _decodeTransferPayload(bytes calldata payload) internal pure returns (address to, uint256 amount) {
        require(payload.length == 4 + 32 + 32, "Invalid payload length");

        bytes4 selector = bytes4(payload[:4]);
        require(selector == bytes4(keccak256("transfer(address,uint256)")), "Not a transfer() call");

        bytes memory params = payload[4:];
        (to, amount) = abi.decode(params, (address, uint256));
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
