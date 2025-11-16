// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ICartesiDApp, Proof} from "@cartesi/rollups/contracts/dapp/ICartesiDApp.sol";
import {IConsensus} from "@cartesi/rollups/contracts/consensus/IConsensus.sol";
import "../SLDTradeableExit/SLDTradeableExit.sol";

error FastWithdrawalRequesterMismatch();
error VoucherIsNotAWithdrawal();
error FailedToExecuteVoucher();

// Shared Liquidity Dynamic Tradeable Exit
contract CartesiSLDTradeableExit is SLDTradeableExit {
    using SafeERC20 for IERC20;

    function requestFastWithdrawal(
        bytes calldata _requestId,
        address _token,
        uint256 _amount,
        uint256 _inputTimestamp
    ) external override {
        (address rollup, address requester, , ) = abi.decode(
            _requestId,
            (address, address, uint256, uint256)
        );
        if (requester != msg.sender) revert FastWithdrawalRequesterMismatch();

        FastWithdrawalRequest memory request = FastWithdrawalRequest({
            id: _requestId,
            token: _token,
            amount: _amount,
            tickets_bought: 0,
            redeemed: 0,
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

        tickets[_requestId][msg.sender] = _amount;
    }

    function getTickets(
        bytes calldata _requestId,
        address _account
    ) public view returns (uint256) {
        return tickets[_requestId][_account];
    }

    function getRollupFastWithdrawalRequests(
        address _rollup
    ) external view override returns (FastWithdrawalRequest[] memory) {
        return dappRequests[_rollup];
    }

    function getFastWithdrawalRequest(
        bytes calldata _requestId
    ) external view override returns (FastWithdrawalRequest memory) {
        (address dapp, , , ) = abi.decode(
            _requestId,
            (address, address, uint256, uint256)
        );
        Position memory position = idToRequestPosition[_requestId];

        if (!position.exists) {
            revert FastWithdrawalRequestNotFound();
        }

        return dappRequests[dapp][position.pos];
    }

    function getFastWithdrawalRequestRemainingTicketsPrice(
        bytes memory _requestId
    ) external view override returns (uint256, uint256, string memory) {
        (address dapp, , , ) = abi.decode(
            _requestId,
            (address, address, uint256, uint256)
        );
        FastWithdrawalRequest memory request = _getFastWithdrawalRequest(
            dapp,
            _requestId
        );

        ERC20 token = ERC20(request.token);

        uint256 remaining = request.amount - request.tickets_bought;
        uint256 ticket_proportion = _calculateTicketProportion(
            request.timestamp
        );
        uint256 token_to_ticket = remaining * ticket_proportion;

        return (remaining, token_to_ticket, token.symbol());
    }

    function _getFastWithdrawalRequest(
        address dapp,
        bytes memory request_id
    ) private view returns (FastWithdrawalRequest storage) {
        Position memory position = idToRequestPosition[request_id];
        if (!position.exists) {
            revert FastWithdrawalRequestNotFound();
        }

        return dappRequests[dapp][position.pos];
    }

    // Tickets are exchange by an ERC20 token once the Rollup state is final.
    // The fee charged by the L2 validators are included in the ticket price,
    // tickets worth less than the actual token, initial proportion is 1.168:1.
    // With time the price of the ticket gets closer to the price of the token.
    uint256 internal constant INITIAL_PROPORTION = 1168e15;
    uint256 internal constant DECAY_PER_HOUR = 1e15;

    function _calculateTicketProportion(
        uint256 request_timestamp
    ) internal view returns (uint256) {
        unchecked {
            uint256 hours_passed = (block.timestamp - request_timestamp) / 3600;
            uint256 decay = DECAY_PER_HOUR * hours_passed;
            if (decay >= INITIAL_PROPORTION) {
                return 0; // prevent underflow and represent proportion floor
            }
            return INITIAL_PROPORTION - decay;
        }
    }

    function fundFastWithdrawalRequest(
        bytes calldata _requestId,
        IERC20 _token,
        uint256 _amount
    ) external override {
        (address dapp, address requester, , ) = abi.decode(
            _requestId,
            (address, address, uint256, uint256)
        );
        FastWithdrawalRequest storage request = _getFastWithdrawalRequest(
            dapp,
            _requestId
        );
        uint256 ticketAmountAvailable = tickets[_requestId][requester];

        if (ticketAmountAvailable == 0) {
            revert FundingAlreadyCompleted();
        }

        if (block.timestamp >= request.timestamp + DEFAULT_DISPUTE_PERIOD) {
            revert FundingTimeout();
        }

        // DYNAMIC PRICE
        uint256 ticketProportion = _calculateTicketProportion(
            request.timestamp
        );
        uint256 tokenToTicket = (_amount * ticketProportion) / 1e18;
        uint256 transferAmount;

        // verify the amount of tickets available
        if (tokenToTicket <= ticketAmountAvailable) {
            transferAmount = _amount;
        } else {
            transferAmount = (ticketAmountAvailable * 1e18) / ticketProportion;
            tokenToTicket = ticketAmountAvailable;
        }

        // send funds to Fast Withdrawal requester
        tickets[_requestId][requester] -= tokenToTicket;
        tickets[_requestId][msg.sender] += tokenToTicket;
        request.tickets_bought += tokenToTicket;

        _token.safeTransferFrom(msg.sender, requester, transferAmount);

        emit FundingFastWithdrawal(_requestId, address(_token), transferAmount);
    }

    function withdraw(
        bytes calldata _requestId,
        bytes calldata _data
    ) external override {
        (address dapp, , uint256 input_index, uint256 voucher_index) = abi
            .decode(_requestId, (address, address, uint256, uint256));
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
        IERC20 token = IERC20(request.token);
        uint256 ticketAmount = tickets[_requestId][msg.sender];
        request.redeemed += ticketAmount;
        token.safeTransfer(msg.sender, ticketAmount);

        // 4) Delete request from list
        if (request.redeemed >= request.amount) {
            _removeFastWithdrawalRequest(dapp, _requestId);
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
        FastWithdrawalRequest memory last_request = dappRequests[_dapp][
            len - 1
        ];
        idToRequestPosition[last_request.id] = Position(position.pos, true);
        dappRequests[_dapp][position.pos] = last_request;

        dappRequests[_dapp].pop();
    }
}
