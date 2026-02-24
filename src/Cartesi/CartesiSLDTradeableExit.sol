// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ICartesiDApp, Proof} from "@cartesi/rollups/contracts/dapp/ICartesiDApp.sol";
import {IConsensus} from "@cartesi/rollups/contracts/consensus/IConsensus.sol";
import {InputBox} from "@cartesi/rollups/contracts/inputs/InputBox.sol";
import "../SLDTradeableExit/SLDTradeableExit.sol";

error FastWithdrawalRequesterMismatch();
error VoucherIsNotAWithdrawal();
error FailedToExecuteVoucher();
error InvalidWithdrawalRequest(bytes32 expected, bytes32 actual);

// Shared Liquidity Dynamic Tradeable Exit
contract CartesiSLDTradeableExit is SLDTradeableExit {
    using SafeERC20 for IERC20;

    InputBox private immutable INPUT_BOX =
        InputBox(0x59b22D57D4f067708AB0c00552767405926dc768);

    function requestFastWithdrawal(
        bytes calldata _requestId,
        address _token,
        uint256 _amount,
        uint256 _inputTimestamp
    ) external payable override {
        (address rollup, address requester, , ) = abi.decode(
            _requestId,
            (address, address, uint256, uint256)
        );
        if (requester != msg.sender) revert FastWithdrawalRequesterMismatch();

        FastWithdrawalRequest memory request = FastWithdrawalRequest({
            id: _requestId,
            token: _token,
            amount: _amount,
            amount_funded: 0,
            amount_redeemed: 0,
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

    function getTickets(
        bytes calldata _requestId,
        address _account
    ) public view returns (uint256) {
        return recipients[_requestId][_account];
    }

    function getRollupFastWithdrawalRequests(
        address _rollup
    ) external view override returns (FastWithdrawalRequest[] memory) {
        return dappRequests[_rollup];
    }

    function getFastWithdrawalRequest(
        bytes calldata _requestId
    ) external view returns (FastWithdrawalRequest memory) {
        (address dapp, , , ) = abi.decode(
            _requestId,
            (address, address, uint256, uint256)
        );
        Position memory position = idToRequestPosition[_requestId];

        if (!position.exists) {
            revert FastWithdrawalRequestNotFound(_requestId);
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

        uint256 remaining = request.amount - request.amount_funded;
        uint256 ticket_proportion = _calculateDecaying(request.timestamp);
        uint256 token_to_ticket = remaining * ticket_proportion;

        return (remaining, token_to_ticket, token.symbol());
    }

    // Tickets are exchange by an ERC20 token once the Rollup state is final.
    // The fee charged by the L2 validators are included in the ticket price,
    // recipients worth less than the actual token, initial proportion is 1.168:1.
    // With time the price of the ticket gets closer to the price of the token.
    uint256 internal constant INITIAL_PROPORTION = 1168e15;
    uint256 internal constant DECAY_PER_HOUR = 1e15;

    function _calculateDecaying(
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
        uint256 ticketAmountAvailable = recipients[_requestId][requester];

        if (ticketAmountAvailable == 0) {
            revert FundingAlreadyCompleted();
        }

        if (block.timestamp >= request.timestamp + DEFAULT_DISPUTE_PERIOD) {
            revert FundingTimeout();
        }

        // DYNAMIC PRICE
        uint256 decayingProportion = _calculateDecaying(request.timestamp);
        uint256 amountFunded = (_amount * decayingProportion) / 1e18;
        uint256 transferAmount;

        // verify the amount of recipients available
        if (amountFunded <= ticketAmountAvailable) {
            transferAmount = _amount;
        } else {
            transferAmount =
                (ticketAmountAvailable * 1e18) /
                decayingProportion;
            amountFunded = ticketAmountAvailable;
        }

        // send funds to Fast Withdrawal requester
        recipients[_requestId][requester] -= amountFunded;
        recipients[_requestId][msg.sender] += amountFunded;
        request.amount_funded += amountFunded;

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
    function withdraw(
        bytes calldata _requestId,
        bytes calldata _data
    ) external override {
        (
            address dapp,
            address requester,
            uint256 inputIndex,
            uint256 voucherIndex
        ) = abi.decode(_requestId, (address, address, uint256, uint256));
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
        uint256 ticketAmount = recipients[_requestId][msg.sender];
        request.amount_redeemed += ticketAmount;
        token.safeTransfer(msg.sender, ticketAmount);

        // 4) Delete request from list
        if (request.amount_redeemed >= request.amount) {
            _removeFastWithdrawalRequest(dapp, _requestId);
        }
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
