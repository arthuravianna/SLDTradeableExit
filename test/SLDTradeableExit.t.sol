// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SLDTradeableExitFactory} from "../src/SLDTradeableExitFactory.sol";
import {FastWithdrawalTicket} from "../src/FastWithdrawalTicket.sol";
import {SLDTradeableExit, FastWithdrawalRequest} from "../src/SLDTradeableExit.sol";
import {MockERC20} from './MockERC20.sol';

contract SLDTradeableExitTest is Test, SLDTradeableExit {
    SLDTradeableExit public sld_tradeable_exit;
    FastWithdrawalTicket public tickets;
    MockERC20 public mockERC20;

    address requester0 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address requester1 = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;

    // validators
    address validator0 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address validator1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

    // fast withdrawal request info
    address fw_dapp = 0xECB28678045a94F8b96EdE1c8203aDEa81F8AAe3;
    uint256 fw_amount = 100000000000000000000;

    uint256 fw_request0_input_index = 0;
    uint256 fw_request0_voucher_index = 0;
    uint256 fw_request0_timestamp = 0;

    uint256 fw_request1_input_index = 1;
    uint256 fw_request1_voucher_index = 0;
    uint256 fw_request1_timestamp = 3600;

    constructor() SLDTradeableExit(address(0)) {}

    function setUp() public {
        SLDTradeableExitFactory factory = new SLDTradeableExitFactory();
        address ticketTokenAddress;
        address sldTradeableExitAddress;
        (ticketTokenAddress, sldTradeableExitAddress) = factory.deploy();

        sld_tradeable_exit = SLDTradeableExit(sldTradeableExitAddress);
        tickets = FastWithdrawalTicket(ticketTokenAddress);

        mockERC20 = new MockERC20();
        mockERC20.mint(validator0, 2*fw_amount);
        mockERC20.mint(validator1, 2*fw_amount);

        mockERC20.approve(validator0, address(sld_tradeable_exit), 2*fw_amount);
        mockERC20.approve(validator1, address(sld_tradeable_exit), 2*fw_amount);

        // setup a fastWithdrawalRequest (used to test the funding)
        vm.prank(requester0);
        sld_tradeable_exit.requestFastWithdrawal(
            address(mockERC20), fw_amount, fw_dapp,
            fw_request0_input_index, fw_request0_voucher_index, fw_request0_timestamp
        );

        vm.prank(requester1);
        // sld_tradeable_exit.requestFastWithdrawal(
        //     address(mockERC20), fw_amount, fw_dapp,
        //     fw_request1_input_index, fw_request1_voucher_index, fw_request1_timestamp
        // );
        sld_tradeable_exit.requestFastWithdrawal(
            address(mockERC20), fw_amount, fw_dapp,
            fw_request1_input_index, fw_request1_voucher_index, fw_request1_timestamp
        );
        console.log("SLDTradeableExit:", address(sld_tradeable_exit));
        console.log("FastWithdrawalTicket:", address(tickets));
        console.log("MockERC20:", address(mockERC20));
    }

    function test_CalculateTicketProportion() public {
        uint256 request_timestamp = 0;

        // Set the block timestamp to a specific time
        uint256 fakeTime = 3600;
        vm.warp(fakeTime);

        uint256 actualProportion = _calculate_ticket_proportion(request_timestamp);
        uint256 expectedProportion = 1168000000000000000 - 1000000000000000; // 1.168 - 0.001

        assertEq(expectedProportion, actualProportion);
    }

    function testFuzz_RequestFastWithdrawal(
        address token,
        uint256 amount,
        address dapp,
        uint256 input_index,
        uint256 voucher_index,
        uint256 input_timestamp
    ) public {
        vm.prank(requester1);
        // assume a "safe" value for amount
        vm.assume(amount < 1e36);

        sld_tradeable_exit.requestFastWithdrawal(token, amount, dapp, input_index, voucher_index, input_timestamp);

        FastWithdrawalRequest memory requestExpected =
            FastWithdrawalRequest(requester1, input_index, voucher_index, input_timestamp, token, amount, 0, 0);
        FastWithdrawalRequest memory requestActual =
            sld_tradeable_exit.getFastWithdrawalRequest(dapp, requester1, input_index, voucher_index);

        assertEq(requestActual.requester, requestExpected.requester, "requester mismatch");
        assertEq(requestActual.input_index, requestExpected.input_index, "input_index mismatch");
        assertEq(requestActual.voucher_index, requestExpected.voucher_index, "voucher_index mismatch");
        assertEq(requestActual.timestamp, requestExpected.timestamp, "timestamp mismatch");
        assertEq(requestActual.token, requestExpected.token, "token mismatch");
        assertEq(requestActual.withdraw_value, requestExpected.withdraw_value, "withdraw_value mismatch");

        bytes memory request_id = abi.encode(dapp, requester1, input_index, voucher_index);
        uint256 ticketsActualBalance = tickets.balanceOf(request_id, requester1);
        assertEq(ticketsActualBalance, amount, "balance mismatch");
    }

    function test_FundFastWithdrawalRequestNotFound() public {
        vm.expectRevert();

        sld_tradeable_exit.fundFastWithdrawalRequest(
            address(0),
            requester0,
            fw_request0_input_index,
            fw_request0_voucher_index,
            mockERC20,
            fw_amount
        );
    }

    // A single validator funds the request
    function test_FundFastWithdrawalRequest0() public {
        uint256 fakeTime = fw_request0_timestamp + 3600; // one hour later
        vm.warp(fakeTime);
        vm.prank(validator0);

        sld_tradeable_exit.fundFastWithdrawalRequest(
            fw_dapp,
            requester0,
            fw_request0_input_index,
            fw_request0_voucher_index,
            mockERC20,
            fw_amount
        );

        bytes memory request_id = abi.encode(fw_dapp, requester0, fw_request0_input_index, fw_request0_voucher_index);
        // assert requester tickets balance
        assertEq(tickets.balanceOf(request_id, requester0), 0, "mismatch requester ticket balance");

        // assert requester MockERC20 balance
        assertEq(mockERC20.balanceOf(requester0), 85689802913453299057);

        // assert validator tickets balance
        assertEq(tickets.balanceOf(request_id, validator0), fw_amount);
    }

    // 2 validators fund the same request
    function test_FundFastWithdrawalRequest1() public {
        uint256 fakeTime = fw_request1_timestamp + 3600; // one hour after the request
        vm.warp(fakeTime);

        uint256 funding_amount = fw_amount / 2;

        // Validator 0 funding
        vm.prank(validator0);
        sld_tradeable_exit.fundFastWithdrawalRequest(
            fw_dapp,
            requester1,
            fw_request1_input_index,
            fw_request1_voucher_index,
            mockERC20,
            funding_amount
        );

        bytes memory request_id = abi.encode(fw_dapp, requester1, fw_request1_input_index, fw_request1_voucher_index);
        // assert requester tickets balance
        assertEq(tickets.balanceOf(request_id, requester1), 41650000000000000000, "1) mismatch requester1 tickets balance");

        // assert requester MockERC20 balance
        assertEq(mockERC20.balanceOf(requester1), 50000000000000000000, "1) mismatch requester1 mockERC20 balance");

        // assert validator tickets balance
        assertEq(tickets.balanceOf(request_id, validator0), 58350000000000000000, "1) mismatch validator0 tickets balance");


        // Validator 1 funding (this validator will pay more for the funding due to time)
        fakeTime = fw_request1_timestamp + (3600*48); // 48 hours after the request
        vm.warp(fakeTime);
        vm.prank(validator1);
        sld_tradeable_exit.fundFastWithdrawalRequest(
            fw_dapp,
            requester1,
            fw_request1_input_index,
            fw_request1_voucher_index,
            mockERC20,
            funding_amount
        );
        
        // assert requester tickets balance
        assertEq(tickets.balanceOf(request_id, requester1), 0, "2) mismatch requester1 tickets balance");

        // assert requester MockERC20 balance
        assertEq(mockERC20.balanceOf(requester1), 87187500000000000000, "2) mismatch requester1 mockERC20 balance");

        // assert validator tickets balance
        assertEq(tickets.balanceOf(request_id, validator1), 41650000000000000000, "2) mismatch validator0 tickets balance");

        FastWithdrawalRequest memory request =
            sld_tradeable_exit.getFastWithdrawalRequest(fw_dapp, requester1, fw_request1_input_index, fw_request1_voucher_index);
        assertEq(request.tickets_bought, fw_amount, "mismatch tickets bought");
    }
}
