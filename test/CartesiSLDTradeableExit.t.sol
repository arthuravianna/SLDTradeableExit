// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    CartesiSLDTradeableExit, FastWithdrawalRequest
} from "../src/CartesiSLDTradeableExit/CartesiSLDTradeableExit.sol";
import {MockERC20} from "./MockERC20.sol";
import {CartesiDappMock} from "./CartesiDappMock.sol";
import {Proof, OutputValidityProof} from "@cartesi/rollups/contracts/dapp/ICartesiDApp.sol";

contract SLDTradeableExitTest is Test, CartesiSLDTradeableExit {
    CartesiSLDTradeableExit public sld_tradeable_exit = new CartesiSLDTradeableExit();
    MockERC20 public mockERC20;
    CartesiDappMock public cartesiDappMock;

    address requester0 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address requester1 = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address requester2 = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;

    // validators
    address validator0 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address validator1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address validator2 = 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc;

    // fast withdrawal request info
    uint256 fw_amount = 100000000000000000000;
    uint256 validatorMockERC20InitialBalance = 2 * fw_amount;
    bytes request0_id;
    uint256 fw_request0_timestamp = 0;
    bytes request1_id;
    uint256 fw_request1_timestamp = 3600;
    bytes request2_id;
    uint256 fw_request2_timestamp = 0;

    function setUp() public {
        mockERC20 = new MockERC20();
        mockERC20.mint(validator0, validatorMockERC20InitialBalance);
        mockERC20.mint(validator1, validatorMockERC20InitialBalance);
        mockERC20.mint(validator2, validatorMockERC20InitialBalance);
        mockERC20.mint(address(sld_tradeable_exit), 2 * fw_amount); // sld_tradeable_exit needs balance to test withdrawal

        mockERC20.approve(validator0, address(sld_tradeable_exit), validatorMockERC20InitialBalance);
        mockERC20.approve(validator1, address(sld_tradeable_exit), validatorMockERC20InitialBalance);
        mockERC20.approve(validator2, address(sld_tradeable_exit), validatorMockERC20InitialBalance);

        cartesiDappMock = new CartesiDappMock();

        request0_id = abi.encode(address(cartesiDappMock), requester0, uint256(0), uint256(0));
        request1_id = abi.encode(address(cartesiDappMock), requester1, uint256(1), uint256(0));
        request2_id = abi.encode(address(cartesiDappMock), requester2, uint256(1), uint256(0));

        // setup a fastWithdrawalRequest (used to test the funding and withdraw)
        vm.prank(requester0);
        sld_tradeable_exit.requestFastWithdrawal(request0_id, address(mockERC20), fw_amount, fw_request0_timestamp);

        vm.prank(requester1);
        sld_tradeable_exit.requestFastWithdrawal(request1_id, address(mockERC20), fw_amount, fw_request1_timestamp);

        vm.prank(requester2);
        sld_tradeable_exit.requestFastWithdrawal(request2_id, address(mockERC20), fw_amount, fw_request2_timestamp);
        vm.prank(validator2);
        uint256 fakeTime = fw_request2_timestamp + 300; // 5 minutes later
        vm.warp(fakeTime);
        sld_tradeable_exit.fundFastWithdrawalRequest(request2_id, mockERC20, fw_amount);

        console.log("SLDTradeableExit:", address(sld_tradeable_exit));
        console.log("MockERC20:", address(mockERC20));
        console.log("CartesiDappMock:", address(cartesiDappMock));
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

        bytes memory request_id = abi.encode(dapp, requester1, input_index, voucher_index);
        sld_tradeable_exit.requestFastWithdrawal(request_id, token, amount, input_timestamp);

        FastWithdrawalRequest memory requestExpected =
            FastWithdrawalRequest(request_id, token, input_timestamp, amount, 0, 0);
        FastWithdrawalRequest memory requestActual = sld_tradeable_exit.getFastWithdrawalRequest(request_id);

        assertEq(requestActual.id, request_id, "request_id mismatch");
        assertEq(requestActual.timestamp, requestExpected.timestamp, "timestamp mismatch");
        assertEq(requestActual.token, requestExpected.token, "token mismatch");
        assertEq(requestActual.amount, requestExpected.amount, "amount mismatch");

        uint256 ticketsActualBalance = sld_tradeable_exit.getTickets(request_id, requester1);
        assertEq(ticketsActualBalance, amount, "balance mismatch");
    }

    function test_FundFastWithdrawalRequestNotFound() public {
        vm.expectRevert();

        bytes memory request_id = abi.encode(address(0), requester0, 0, 0);
        sld_tradeable_exit.fundFastWithdrawalRequest(request_id, mockERC20, fw_amount);
    }

    // A single validator funds the request
    function test_FundFastWithdrawalRequest0() public {
        uint256 fakeTime = fw_request0_timestamp + 3600; // one hour later
        vm.warp(fakeTime);
        vm.prank(validator0);

        sld_tradeable_exit.fundFastWithdrawalRequest(request0_id, mockERC20, fw_amount);

        // assert requester tickets balance
        assertEq(sld_tradeable_exit.getTickets(request0_id, requester0), 0, "mismatch requester ticket balance");

        // assert requester MockERC20 balance
        assertEq(mockERC20.balanceOf(requester0), 85689802913453299057);

        // assert validator tickets balance
        assertEq(sld_tradeable_exit.getTickets(request0_id, validator0), fw_amount);
    }

    // 2 validators fund the same request
    function test_FundFastWithdrawalRequest1() public {
        uint256 fakeTime = fw_request1_timestamp + 3600; // one hour after the request
        vm.warp(fakeTime);

        uint256 funding_amount = fw_amount / 2;

        // Validator 0 funding
        vm.prank(validator0);
        sld_tradeable_exit.fundFastWithdrawalRequest(request1_id, mockERC20, funding_amount);

        // assert requester tickets balance
        assertEq(
            sld_tradeable_exit.getTickets(request1_id, requester1), 41650000000000000000, "1) mismatch requester1 tickets balance"
        );

        // assert requester MockERC20 balance
        assertEq(mockERC20.balanceOf(requester1), 50000000000000000000, "1) mismatch requester1 mockERC20 balance");

        // assert validator tickets balance
        assertEq(
            sld_tradeable_exit.getTickets(request1_id, validator0), 58350000000000000000, "1) mismatch validator0 tickets balance"
        );

        // Validator 1 funding (this validator will pay more for the funding due to time)
        fakeTime = fw_request1_timestamp + (3600 * 48); // 48 hours after the request
        vm.warp(fakeTime);
        vm.prank(validator1);
        sld_tradeable_exit.fundFastWithdrawalRequest(request1_id, mockERC20, funding_amount);

        // assert requester tickets balance
        assertEq(sld_tradeable_exit.getTickets(request1_id, requester1), 0, "2) mismatch requester1 tickets balance");

        // assert requester MockERC20 balance
        assertEq(mockERC20.balanceOf(requester1), 87187500000000000000, "2) mismatch requester1 mockERC20 balance");

        // assert validator tickets balance
        assertEq(
            sld_tradeable_exit.getTickets(request1_id, validator1), 41650000000000000000, "2) mismatch validator0 tickets balance"
        );

        FastWithdrawalRequest memory request = sld_tradeable_exit.getFastWithdrawalRequest(request1_id);
        assertEq(request.tickets_bought, fw_amount, "mismatch tickets bought");
    }

    function test_WithdrawFastWithdrawal0() public {
        bytes memory voucher_payload = hex"a9059cbb0000000000000000000000005615deb798bb3e4dfa0139dfa1b3d433cc23b72f0000000000000000000000000000000000000000000000056bc75e2d63100000";
        // empty voucher proof
        Proof memory voucher_proof = Proof({
            validity: OutputValidityProof({
                inputIndexWithinEpoch: 0,
                outputIndexWithinInput: 0,
                outputHashesRootHash: bytes32(0),
                vouchersEpochRootHash: bytes32(0),
                noticesEpochRootHash: bytes32(0),
                machineStateHash: bytes32(0),
                outputHashInOutputHashesSiblings: new bytes32[](0),
                outputHashesInEpochSiblings: new bytes32[](0)
            }),
            context: ""
        });

        assertEq(mockERC20.balanceOf(requester2), 85616438356164383561, "1) mismatch requester2 mockERC20 balance AFTER funding");
        assertEq(mockERC20.balanceOf(validator2), 114383561643835616439, "2) mismatch validator2 mockERC20 balance BEFORE withdraw");
        vm.prank(validator2);
        sld_tradeable_exit.withdraw(
            request2_id, 
            fw_amount, 
            address(mockERC20), 
            voucher_payload,
            voucher_proof
        );

        uint256 fee = fw_amount-85616438356164383561;
        assertEq(mockERC20.balanceOf(validator2), validatorMockERC20InitialBalance+fee, "3) mismatch validator2 mockERC20 balance AFTER withdraw");
    }
}