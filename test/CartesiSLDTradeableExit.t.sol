// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CartesiSLDTradeableExit, FastWithdrawalRequest} from "../src/Cartesi/CartesiSLDTradeableExit.sol";
import {MockERC20} from "./MockERC20.sol";
import {CartesiDappMock} from "./CartesiDappMock.sol";
import {Proof, OutputValidityProof} from "@cartesi/rollups/contracts/dapp/ICartesiDApp.sol";
import {InputBox} from "@cartesi/rollups/contracts/inputs/InputBox.sol";
import {LibInput} from "@cartesi/rollups/contracts/library/LibInput.sol";

contract SLDTradeableExitTest is Test, CartesiSLDTradeableExit {
    CartesiSLDTradeableExit public sldTradeableExit =
        new CartesiSLDTradeableExit();
    MockERC20 public mockERC20;
    CartesiDappMock public cartesiDappMock = new CartesiDappMock();

    address FAST_WITHDRAWAL_REQUESTER = makeAddr("FastWithdrawalRequester");
    address VALIDATOR = makeAddr("Validator");
    address VALIDATOR_1 = makeAddr("Validator1");
    uint256 constant FAST_WITHDRAWAL_TIMESTAMP = 0;
    uint256 constant FAST_WITHDRAWAL_REQUEST_AMOUNT = 1e20; // 100 tokens
    uint256 constant INPUT_INDEX = 0;
    uint256 constant VOUCHER_INDEX = 0;
    uint256 constant FAST_WITHDRAWAL_REQUESTER_BALANCE_AFTER_FUNDING_5MIN =
        85616438356164383561; //  85.616 tokens
    uint256 constant VALIDATOR_MOCK_ERC20_INITIAL_BALANCE = 1e21; // 1000 tokens
    uint256 constant VALIDATOR_MOCK_ERC20_BALANCE_AFTER_FUNDING_5MIN =
        914383561643835616439; // 1000 tokens - 85.616 tokens

    bytes REQUEST_ID =
        abi.encode(
            address(cartesiDappMock),
            FAST_WITHDRAWAL_REQUESTER,
            INPUT_INDEX,
            VOUCHER_INDEX
        );
    uint256 constant BLOCK_NUMBER = 0;
    address constant INPUT_BOX_ADDRESS =
        0x59b22D57D4f067708AB0c00552767405926dc768;
    bytes constant WITHDRAWAL_INPUT =
        "0x7b226f70223a20227769746864726177616c222c2022746f6b656e223a2022307864323463326265333865363333343236356362653134623637643533333566363431653539623639222c2022616d6f756e74223a203130303030303030303030303030303030303030307d";

    function setUp() public {
        mockERC20 = new MockERC20();
        mockERC20.mint(VALIDATOR, VALIDATOR_MOCK_ERC20_INITIAL_BALANCE);
        mockERC20.approve(
            VALIDATOR,
            address(sldTradeableExit),
            VALIDATOR_MOCK_ERC20_INITIAL_BALANCE
        );

        mockERC20.mint(VALIDATOR_1, VALIDATOR_MOCK_ERC20_INITIAL_BALANCE);
        mockERC20.approve(
            VALIDATOR_1,
            address(sldTradeableExit),
            VALIDATOR_MOCK_ERC20_INITIAL_BALANCE
        );

        mockERC20.mint(
            address(sldTradeableExit),
            2 * FAST_WITHDRAWAL_REQUEST_AMOUNT
        ); // sldTradeableExit needs balance to test withdrawal

        console.log("SLDTradeableExit:", address(sldTradeableExit));
        console.log("MockERC20:", address(mockERC20));
        console.log("CartesiDappMock:", address(cartesiDappMock));
    }

    modifier requestFastWithdrawalModifier() {
        vm.startPrank(FAST_WITHDRAWAL_REQUESTER);
        vm.warp(FAST_WITHDRAWAL_TIMESTAMP);
        vm.roll(BLOCK_NUMBER);
        // 1) addInput to Cartesi DApp's InputBox
        bytes memory bytecode = vm.getDeployedCode(
            "@cartesi/rollups/contracts/inputs/InputBox.sol:InputBox"
        );
        vm.etch(INPUT_BOX_ADDRESS, bytecode);
        InputBox inputBox = InputBox(INPUT_BOX_ADDRESS);
        inputBox.addInput(address(cartesiDappMock), WITHDRAWAL_INPUT);

        // 2) request fast withdrawal
        sldTradeableExit.requestFastWithdrawal(
            REQUEST_ID,
            address(mockERC20),
            FAST_WITHDRAWAL_REQUEST_AMOUNT,
            FAST_WITHDRAWAL_TIMESTAMP
        );
        vm.stopPrank();
        _;
    }

    modifier fundFastWithdrawalModifier() {
        vm.prank(VALIDATOR);
        uint256 fakeTime = FAST_WITHDRAWAL_TIMESTAMP + 300; // 5 minutes later
        vm.warp(fakeTime);
        sldTradeableExit.fundFastWithdrawalRequest(
            REQUEST_ID,
            mockERC20,
            FAST_WITHDRAWAL_REQUEST_AMOUNT
        );
        _;
    }

    function test_CalculateTicketProportion() public {
        uint256 requestTimestamp = 0;

        // Set the block timestamp to a specific time
        uint256 fakeTime = 3600; // 1 hour
        vm.warp(fakeTime);

        uint256 actualProportion = _calculateTicketProportion(requestTimestamp);
        uint256 initialProportion = 1168000000000000000; // 1.168;
        uint256 proportionDecayPerHour = 1000000000000000; // 0.001
        uint256 expectedProportion = initialProportion - proportionDecayPerHour; // 1.168 - 0.001

        assertEq(expectedProportion, actualProportion);
    }

    function testFuzz_RequestFastWithdrawal(
        address token,
        uint256 amount,
        address dapp,
        uint256 inputIndex,
        uint256 voucherIndex,
        uint256 inputTimestamp
    ) public {
        vm.prank(FAST_WITHDRAWAL_REQUESTER);
        // assume a "safe" value for amount
        vm.assume(amount < 1e36);

        bytes memory requestId = abi.encode(
            dapp,
            FAST_WITHDRAWAL_REQUESTER,
            inputIndex,
            voucherIndex
        );
        sldTradeableExit.requestFastWithdrawal(
            requestId,
            token,
            amount,
            inputTimestamp
        );

        FastWithdrawalRequest memory requestExpected = FastWithdrawalRequest(
            requestId,
            token,
            inputTimestamp,
            amount,
            0,
            0
        );
        FastWithdrawalRequest memory requestActual = sldTradeableExit
            .getFastWithdrawalRequest(requestId);

        assertEq(requestActual.id, requestId, "requestId mismatch");
        assertEq(
            requestActual.timestamp,
            requestExpected.timestamp,
            "timestamp mismatch"
        );
        assertEq(requestActual.token, requestExpected.token, "token mismatch");
        assertEq(
            requestActual.amount,
            requestExpected.amount,
            "amount mismatch"
        );

        uint256 ticketsActualBalance = sldTradeableExit.getTickets(
            requestId,
            FAST_WITHDRAWAL_REQUESTER
        );
        assertEq(ticketsActualBalance, amount, "balance mismatch");
    }

    function test_FundFastWithdrawalRequestNotFound() public {
        vm.expectRevert();

        bytes memory requestId = abi.encode(
            address(0),
            FAST_WITHDRAWAL_REQUESTER,
            0,
            0
        );
        sldTradeableExit.fundFastWithdrawalRequest(
            requestId,
            mockERC20,
            FAST_WITHDRAWAL_REQUEST_AMOUNT
        );
    }

    // A single validator funds the request
    function test_FundFastWithdrawalRequest0()
        public
        requestFastWithdrawalModifier
    {
        uint256 fakeTime = FAST_WITHDRAWAL_TIMESTAMP + 3600; // one hour later
        vm.warp(fakeTime);
        vm.prank(VALIDATOR);

        sldTradeableExit.fundFastWithdrawalRequest(
            REQUEST_ID,
            mockERC20,
            FAST_WITHDRAWAL_REQUEST_AMOUNT
        );

        // assert requester tickets balance
        assertEq(
            sldTradeableExit.getTickets(REQUEST_ID, FAST_WITHDRAWAL_REQUESTER),
            0,
            "mismatch requester ticket balance"
        );

        // assert requester MockERC20 balance
        uint256 expectedFastWithdrawalRequesterBalance = 85689802913453299057;
        assertEq(
            mockERC20.balanceOf(FAST_WITHDRAWAL_REQUESTER),
            expectedFastWithdrawalRequesterBalance
        );

        // assert validator tickets balance
        assertEq(
            sldTradeableExit.getTickets(REQUEST_ID, VALIDATOR),
            FAST_WITHDRAWAL_REQUEST_AMOUNT
        );
    }

    // 2 validators fund the same request
    function test_FundFastWithdrawalRequest1()
        public
        requestFastWithdrawalModifier
    {
        uint256 fakeTime = FAST_WITHDRAWAL_TIMESTAMP + 3600; // one hour after the request
        vm.warp(fakeTime);

        uint256 fundingAmount = FAST_WITHDRAWAL_REQUEST_AMOUNT / 2;

        // Validator 0 funding
        vm.prank(VALIDATOR);
        sldTradeableExit.fundFastWithdrawalRequest(
            REQUEST_ID,
            mockERC20,
            fundingAmount
        );

        // assert requester tickets balance
        uint256 expectedRequesterTicketsAfterFirstFunding = 41650000000000000000;
        assertEq(
            sldTradeableExit.getTickets(REQUEST_ID, FAST_WITHDRAWAL_REQUESTER),
            expectedRequesterTicketsAfterFirstFunding,
            "1) mismatch requester tickets balance"
        );

        // assert requester MockERC20 balance
        uint256 expectedRequesterMockERC20BalanceAfterFirstFunding = 50000000000000000000;
        assertEq(
            mockERC20.balanceOf(FAST_WITHDRAWAL_REQUESTER),
            expectedRequesterMockERC20BalanceAfterFirstFunding,
            "1) mismatch requester mockERC20 balance"
        );

        // assert validator tickets balance
        uint256 expectedValidatorTicketsAfterFirstFunding = 58350000000000000000;
        assertEq(
            sldTradeableExit.getTickets(REQUEST_ID, VALIDATOR),
            expectedValidatorTicketsAfterFirstFunding,
            "1) mismatch VALIDATOR tickets balance"
        );

        // Validator 1 funding (this validator will pay more for the funding due to time)
        fakeTime = FAST_WITHDRAWAL_TIMESTAMP + (3600 * 48); // 48 hours after the request
        vm.warp(fakeTime);
        vm.prank(VALIDATOR_1);
        sldTradeableExit.fundFastWithdrawalRequest(
            REQUEST_ID,
            mockERC20,
            fundingAmount
        );

        // assert requester tickets balance
        assertEq(
            sldTradeableExit.getTickets(REQUEST_ID, FAST_WITHDRAWAL_REQUESTER),
            0,
            "2) mismatch requester tickets balance"
        );

        // assert requester MockERC20 balance
        uint256 expectedRequesterMockERC20BalanceAfterSecondFunding = 87187500000000000000;
        assertEq(
            mockERC20.balanceOf(FAST_WITHDRAWAL_REQUESTER),
            expectedRequesterMockERC20BalanceAfterSecondFunding,
            "2) mismatch requester mockERC20 balance"
        );

        // assert validator tickets balance
        uint256 expectedValidator1TicketsAfterSecondFunding = 41650000000000000000;
        assertEq(
            sldTradeableExit.getTickets(REQUEST_ID, VALIDATOR_1),
            expectedValidator1TicketsAfterSecondFunding,
            "2) mismatch VALIDATOR_1 tickets balance"
        );

        FastWithdrawalRequest memory request = sldTradeableExit
            .getFastWithdrawalRequest(REQUEST_ID);
        assertEq(
            request.tickets_bought,
            FAST_WITHDRAWAL_REQUEST_AMOUNT,
            "mismatch tickets bought"
        );
    }

    function test_WithdrawFastWithdrawal0()
        public
        requestFastWithdrawalModifier
        fundFastWithdrawalModifier
    {
        bytes
            memory voucher_payload = hex"a9059cbb0000000000000000000000005615deb798bb3e4dfa0139dfa1b3d433cc23b72f0000000000000000000000000000000000000000000000056bc75e2d63100000";
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

        bytes32 keccakInput = keccak256(WITHDRAWAL_INPUT);
        bytes memory data = abi.encode(
            address(mockERC20),
            voucher_payload,
            voucher_proof,
            keccakInput,
            BLOCK_NUMBER
        );

        assertEq(
            mockERC20.balanceOf(FAST_WITHDRAWAL_REQUESTER),
            FAST_WITHDRAWAL_REQUESTER_BALANCE_AFTER_FUNDING_5MIN,
            "1) mismatch FAST_WITHDRAWAL_REQUESTER mockERC20 balance AFTER funding"
        );
        assertEq(
            mockERC20.balanceOf(VALIDATOR),
            VALIDATOR_MOCK_ERC20_BALANCE_AFTER_FUNDING_5MIN,
            "2) mismatch VALIDATOR mockERC20 balance BEFORE withdraw"
        );
        vm.prank(VALIDATOR);
        sldTradeableExit.withdraw(REQUEST_ID, data);

        uint256 fee = FAST_WITHDRAWAL_REQUEST_AMOUNT -
            FAST_WITHDRAWAL_REQUESTER_BALANCE_AFTER_FUNDING_5MIN;
        assertEq(
            mockERC20.balanceOf(VALIDATOR),
            VALIDATOR_MOCK_ERC20_INITIAL_BALANCE + fee,
            "3) mismatch VALIDATOR mockERC20 balance AFTER withdraw"
        );
    }
}
