// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {SLDTradeableExitFactory} from "../src/SLDTradeableExitFactory.sol";
import {FastWithdrawalTicket} from "../src/FastWithdrawalTicket.sol";
import {SLDTradeableExit, FastWithdrawalRequest} from "../src/SLDTradeableExit.sol";

contract SLDTradeableExitTest is Test {
    SLDTradeableExit public sld_tradeable_exit;
    FastWithdrawalTicket public tickets;

    function setUp() public {
        SLDTradeableExitFactory factory = new SLDTradeableExitFactory();
        address ticketTokenAddress;
        address sldTradeableExitAddress;
        (ticketTokenAddress, sldTradeableExitAddress) = factory.deploy();

        sld_tradeable_exit = SLDTradeableExit(sldTradeableExitAddress);
        tickets = FastWithdrawalTicket(ticketTokenAddress);
    }

    function testFuzz_RequestFastWithdrawal(
        address token,
        uint256 amount,
        address dapp,
        uint256 input_index,
        uint256 voucher_index,
        uint256 input_timestamp
    ) public {
        // on forge-std tests the msg.sender is this contract
        address sender = address(this);

        sld_tradeable_exit.requestFastWithdrawal(token, amount, dapp, input_index, voucher_index, input_timestamp);

        FastWithdrawalRequest memory requestExpected =
            FastWithdrawalRequest(sender, input_index, voucher_index, input_timestamp, token, amount);
        FastWithdrawalRequest memory requestActual =
            sld_tradeable_exit.getFastWithdrawalRequest(dapp, input_index, voucher_index);

        assertEq(requestActual.requester, requestExpected.requester, "requester mismatch");
        assertEq(requestActual.input_index, requestExpected.input_index, "input_index mismatch");
        assertEq(requestActual.voucher_index, requestExpected.voucher_index, "voucher_index mismatch");
        assertEq(requestActual.timestamp, requestExpected.timestamp, "timestamp mismatch");
        assertEq(requestActual.token, requestExpected.token, "token mismatch");
        assertEq(requestActual.amount, requestExpected.amount, "amount mismatch");

        bytes memory request_id = abi.encode(dapp, input_index, voucher_index);
        uint256 ticketsActualBalance = tickets.balanceOf(request_id, sender);
        assertEq(ticketsActualBalance, amount, "balance mismatch");
    }
}
