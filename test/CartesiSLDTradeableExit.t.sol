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
        996*1e17; //  99.6 tokens
    uint256 constant VALIDATOR_MOCK_ERC20_INITIAL_BALANCE = 1e21; // 1000 tokens
    uint256 constant VALIDATOR_MOCK_ERC20_BALANCE_AFTER_FUNDING_5MIN =
        VALIDATOR_MOCK_ERC20_INITIAL_BALANCE - FAST_WITHDRAWAL_REQUESTER_BALANCE_AFTER_FUNDING_5MIN; // 1000 tokens - 99.6 token tokens

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
        // give some ether to the requester to pay for the flat fee
        vm.deal(FAST_WITHDRAWAL_REQUESTER, 1 ether);

        // sldTradeableExit needs balance to test withdrawal
        // this is the value available in the contract after the delayed withdrawal is executed,
        // so we mint this amount to the contract before testing the withdrawal
        mockERC20.mint(
            address(sldTradeableExit),
            FAST_WITHDRAWAL_REQUEST_AMOUNT
        );

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
        sldTradeableExit.requestFastWithdrawal{
            value: sldTradeableExit.DEFAULT_FLAT_FEE()
        }(
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

    function test_CalculateFee0() public {
        uint256 requestTimestamp = 0;

        // Set the block timestamp to a specific time
        uint256 fakeTime = 3600; // 1 hour
        vm.warp(fakeTime);

        uint256 fee = _calculateFee(FAST_WITHDRAWAL_REQUEST_AMOUNT, requestTimestamp);
        // FAST_WITHDRAWAL_REQUEST_AMOUNT * 0.00397619 (0.0397619%)
        uint256 expectedFee = 397619*1e12; // 0.397619 token

        assertEq(fee, expectedFee);
    }

    function test_CalculateFee1() public {
        uint256 requestTimestamp = 0;

        // Set the block timestamp to a specific time
        uint256 fakeTime = 3600*84; // 84 hours (half a week)
        vm.warp(fakeTime);

        uint256 fee = _calculateFee(FAST_WITHDRAWAL_REQUEST_AMOUNT, requestTimestamp);
        // FAST_WITHDRAWAL_REQUEST_AMOUNT * 0,00199996 (0,0199996%)
        uint256 expectedFee = 199996*1e12; // 0.199996 token

        assertEq(fee, expectedFee);
    }

    function testFuzz_RequestFastWithdrawal(
        address token,
        uint256 amount,
        address dapp,
        uint256 inputIndex,
        uint256 voucherIndex,
        uint256 inputTimestamp
    ) public {
        vm.startPrank(FAST_WITHDRAWAL_REQUESTER);
        // assume a "safe" value for amount
        vm.assume(amount < 1e36);

        bytes memory requestId = abi.encode(
            dapp,
            FAST_WITHDRAWAL_REQUESTER,
            inputIndex,
            voucherIndex
        );
        sldTradeableExit.requestFastWithdrawal{
            value: sldTradeableExit.DEFAULT_FLAT_FEE()
        }(
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

        uint256 delayedWithdrawalAmount = sldTradeableExit.getUserDelayedWithdrawalAmount(
            requestId,
            FAST_WITHDRAWAL_REQUESTER
        );
        assertEq(delayedWithdrawalAmount, amount, "delayed withdrawal amount mismatch");

        vm.stopPrank();
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

        // assert requester delayed withdrawal amount
        uint256 delayedWithdrawalAmount = sldTradeableExit.getUserDelayedWithdrawalAmount(
            REQUEST_ID,
            FAST_WITHDRAWAL_REQUESTER
        );
        assertEq(delayedWithdrawalAmount, 0, "requester delayed withdrawal amount mismatch");

        // assert requester MockERC20 balance
        uint256 feeAfterOneHour = _calculateFee(FAST_WITHDRAWAL_REQUEST_AMOUNT, FAST_WITHDRAWAL_TIMESTAMP);
        uint256 expectedFastWithdrawalRequesterBalance = FAST_WITHDRAWAL_REQUEST_AMOUNT - feeAfterOneHour;
        assertEq(
            mockERC20.balanceOf(FAST_WITHDRAWAL_REQUESTER),
            expectedFastWithdrawalRequesterBalance
        );

        // assert validator delayed withdrawal amount
        delayedWithdrawalAmount = sldTradeableExit.getUserDelayedWithdrawalAmount(
            REQUEST_ID,
            VALIDATOR
        );
        assertEq(
            delayedWithdrawalAmount, 
            FAST_WITHDRAWAL_REQUEST_AMOUNT, 
            "validator delayed withdrawal amount mismatch"
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

        // assert requester delayed withdrawal amount
        uint256 firstFundingFee = _calculateFee(fundingAmount, FAST_WITHDRAWAL_TIMESTAMP);
        uint256 expectedRequesterDelayedWithdrawalAmountAfterFirstFunding = FAST_WITHDRAWAL_REQUEST_AMOUNT - fundingAmount - firstFundingFee;
        assertEq(
            sldTradeableExit.getUserDelayedWithdrawalAmount(REQUEST_ID, FAST_WITHDRAWAL_REQUESTER),
            expectedRequesterDelayedWithdrawalAmountAfterFirstFunding,
            "1) mismatch requester delayed withdrawal amount"
        );

        // assert requester MockERC20 balance
        assertEq(
            mockERC20.balanceOf(FAST_WITHDRAWAL_REQUESTER),
            fundingAmount,
            "1) mismatch requester mockERC20 balance"
        );

        // assert validator delayed withdrawal amount
        uint256 expectedValidatorDelayedWithdrawalAmountAfterFirstFunding = fundingAmount + firstFundingFee;
        assertEq(
            sldTradeableExit.getUserDelayedWithdrawalAmount(REQUEST_ID, VALIDATOR),
            expectedValidatorDelayedWithdrawalAmountAfterFirstFunding,
            "1) mismatch VALIDATOR delayed withdrawal amount"
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

        // assert requester delayed withdrawal amount
        assertEq(
            sldTradeableExit.getUserDelayedWithdrawalAmount(REQUEST_ID, FAST_WITHDRAWAL_REQUESTER),
            0,
            "2) mismatch requester delayed withdrawal amount"
        );


        uint256 secondFundingFee = _calculateFee(expectedRequesterDelayedWithdrawalAmountAfterFirstFunding, FAST_WITHDRAWAL_TIMESTAMP);
        // assert requester MockERC20 balance
        uint256 expectedRequesterMockERC20BalanceAfterSecondFunding = FAST_WITHDRAWAL_REQUEST_AMOUNT - firstFundingFee - secondFundingFee;
        assertEq(
            mockERC20.balanceOf(FAST_WITHDRAWAL_REQUESTER),
            expectedRequesterMockERC20BalanceAfterSecondFunding,
            "2) mismatch requester mockERC20 balance"
        );

        // assert validator delayed withdrawal amount
        // should receives the remaining
        uint256 expectedValidator1DelayedWithdrawalAmountAfterSecondFunding = expectedRequesterDelayedWithdrawalAmountAfterFirstFunding;
        assertEq(
            sldTradeableExit.getUserDelayedWithdrawalAmount(REQUEST_ID, VALIDATOR_1),
            expectedValidator1DelayedWithdrawalAmountAfterSecondFunding,
            "2) mismatch VALIDATOR_1 delayed withdrawal amount"
        );
    }

    function test_WithdrawFastWithdrawal0()
        public
        requestFastWithdrawalModifier
        fundFastWithdrawalModifier
    {
        bytes
            memory voucherPayload = hex"a9059cbb0000000000000000000000005615deb798bb3e4dfa0139dfa1b3d433cc23b72f0000000000000000000000000000000000000000000000056bc75e2d63100000";
        // empty voucher proof
        Proof memory voucherProof = Proof({
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
            voucherPayload,
            voucherProof,
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

        assertEq(
            VALIDATOR.balance,
            sldTradeableExit.DEFAULT_FLAT_FEE(),
            "4) mismatch VALIDATOR flat fee reward"
        );
    }
}
