// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArbitrumSLDTradeableExit, FastWithdrawalRequest, WithdrawalAlreadyProcessed} from "../src/Arbitrum/ArbitrumSLDTradeableExit.sol";
import {MockERC20} from "./MockERC20.sol";
import {L1ArbitrumGatewayMock} from "./mocks/L1ArbitrumGatewayMock.sol";

contract ArbitrumSLDTradeableExitTest is Test, ArbitrumSLDTradeableExit {
    address FAST_WITHDRAWAL_REQUESTER = makeAddr("FastWithdrawalRequester");
    address VALIDATOR = makeAddr("Validator");
    address VALIDATOR_1 = makeAddr("Validator1");
    uint256 constant VALIDATOR_MOCK_ERC20_INITIAL_BALANCE = 1e21; // 1000 tokens
    uint256 constant FAST_WITHDRAWAL_REQUEST_AMOUNT = 1e20; // 100 tokens
    uint256 constant FAST_WITHDRAWAL_REQUESTER_BALANCE_AFTER_FUNDING_5MIN =
        996 * 1e17; //  99.6 tokens
    uint256 constant VALIDATOR_MOCK_ERC20_BALANCE_AFTER_FUNDING_5MIN =
        VALIDATOR_MOCK_ERC20_INITIAL_BALANCE -
            FAST_WITHDRAWAL_REQUESTER_BALANCE_AFTER_FUNDING_5MIN; // 1000 tokens - 99.6 token tokens
    uint256 constant FAST_WITHDRAWAL_TIMESTAMP = 0;
    bytes REQUEST_ID = abi.encode(FAST_WITHDRAWAL_REQUESTER, 0); // address, exitNum

    L1ArbitrumGatewayMock public arbitrumGateway;
    ArbitrumSLDTradeableExit public sldTradeableExit;
    MockERC20 public mockERC20;

    constructor() ArbitrumSLDTradeableExit(address(0)) {}

    function setUp() public {
        arbitrumGateway = new L1ArbitrumGatewayMock();
        sldTradeableExit = new ArbitrumSLDTradeableExit(
            address(arbitrumGateway)
        );
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
    }

    modifier requestFastWithdrawalModifier() {
        vm.startPrank(FAST_WITHDRAWAL_REQUESTER);
        vm.warp(FAST_WITHDRAWAL_TIMESTAMP);

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

        uint256 fee = _calculateFee(
            FAST_WITHDRAWAL_REQUEST_AMOUNT,
            requestTimestamp
        );
        // FAST_WITHDRAWAL_REQUEST_AMOUNT * 0.00397619 (0.0397619%)
        uint256 expectedFee = 397619 * 1e12; // 0.397619 token

        assertEq(fee, expectedFee);
    }

    function test_CalculateFee1() public {
        uint256 requestTimestamp = 0;

        // Set the block timestamp to a specific time
        uint256 fakeTime = 3600 * 84; // 84 hours (half a week)
        vm.warp(fakeTime);

        uint256 fee = _calculateFee(
            FAST_WITHDRAWAL_REQUEST_AMOUNT,
            requestTimestamp
        );
        // FAST_WITHDRAWAL_REQUEST_AMOUNT * 0,00199996 (0,0199996%)
        uint256 expectedFee = 199996 * 1e12; // 0.199996 token

        assertEq(fee, expectedFee);
    }

    function testFuzz_RequestFastWithdrawal(
        uint256 exitNum,
        address token,
        uint256 amount,
        uint256 inputTimestamp
    ) public {
        vm.startPrank(FAST_WITHDRAWAL_REQUESTER);
        // assume a "safe" value for amount
        vm.assume(amount < 1e36);

        bytes memory requestId = abi.encode(FAST_WITHDRAWAL_REQUESTER, exitNum);
        sldTradeableExit.requestFastWithdrawal{
            value: sldTradeableExit.DEFAULT_FLAT_FEE()
        }(requestId, token, amount, inputTimestamp);

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

        uint256 delayedWithdrawalAmount = sldTradeableExit
            .getUserDelayedWithdrawalAmount(
                requestId,
                FAST_WITHDRAWAL_REQUESTER
            );
        assertEq(
            delayedWithdrawalAmount,
            amount,
            "delayed withdrawal amount mismatch"
        );

        vm.stopPrank();
    }

    function test_RequestFastWithdrawalAlreadyProcessed() public {
        vm.startPrank(FAST_WITHDRAWAL_REQUESTER);
        vm.warp(FAST_WITHDRAWAL_TIMESTAMP);

        // execute delayed withdrawal on L1 to simulate the exit being ready for withdrawal
        arbitrumGateway.setWithdrawalInfo(
            0, // exitNum
            FAST_WITHDRAWAL_REQUESTER,
            address(mockERC20),
            FAST_WITHDRAWAL_REQUEST_AMOUNT,
            address(sldTradeableExit)
        );

        uint256 flatFee = sldTradeableExit.DEFAULT_FLAT_FEE();
        vm.expectRevert(
            abi.encodeWithSelector(
                WithdrawalAlreadyProcessed.selector,
                REQUEST_ID
            )
        );

        // request fast withdrawal, should revert because the withdrawal is already processed on L1
        sldTradeableExit.requestFastWithdrawal{value: flatFee}(
            REQUEST_ID,
            address(mockERC20),
            FAST_WITHDRAWAL_REQUEST_AMOUNT,
            FAST_WITHDRAWAL_TIMESTAMP
        );

        vm.stopPrank();
    }

    function test_FundFastWithdrawalRequestNotFound() public {
        vm.expectRevert();

        bytes memory requestId = abi.encode(address(0), 0);
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
        uint256 delayedWithdrawalAmount = sldTradeableExit
            .getUserDelayedWithdrawalAmount(
                REQUEST_ID,
                FAST_WITHDRAWAL_REQUESTER
            );
        assertEq(
            delayedWithdrawalAmount,
            0,
            "requester delayed withdrawal amount mismatch"
        );

        // assert requester MockERC20 balance
        uint256 feeAfterOneHour = _calculateFee(
            FAST_WITHDRAWAL_REQUEST_AMOUNT,
            FAST_WITHDRAWAL_TIMESTAMP
        );
        uint256 expectedFastWithdrawalRequesterBalance = FAST_WITHDRAWAL_REQUEST_AMOUNT -
                feeAfterOneHour;
        assertEq(
            mockERC20.balanceOf(FAST_WITHDRAWAL_REQUESTER),
            expectedFastWithdrawalRequesterBalance
        );

        // assert validator delayed withdrawal amount
        delayedWithdrawalAmount = sldTradeableExit
            .getUserDelayedWithdrawalAmount(REQUEST_ID, VALIDATOR);
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
        uint256 firstFundingFee = _calculateFee(
            fundingAmount,
            FAST_WITHDRAWAL_TIMESTAMP
        );
        uint256 expectedRequesterDelayedWithdrawalAmountAfterFirstFunding = FAST_WITHDRAWAL_REQUEST_AMOUNT -
                fundingAmount -
                firstFundingFee;
        assertEq(
            sldTradeableExit.getUserDelayedWithdrawalAmount(
                REQUEST_ID,
                FAST_WITHDRAWAL_REQUESTER
            ),
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
        uint256 expectedValidatorDelayedWithdrawalAmountAfterFirstFunding = fundingAmount +
                firstFundingFee;
        assertEq(
            sldTradeableExit.getUserDelayedWithdrawalAmount(
                REQUEST_ID,
                VALIDATOR
            ),
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
            sldTradeableExit.getUserDelayedWithdrawalAmount(
                REQUEST_ID,
                FAST_WITHDRAWAL_REQUESTER
            ),
            0,
            "2) mismatch requester delayed withdrawal amount"
        );

        uint256 secondFundingFee = _calculateFee(
            expectedRequesterDelayedWithdrawalAmountAfterFirstFunding,
            FAST_WITHDRAWAL_TIMESTAMP
        );
        // assert requester MockERC20 balance
        uint256 expectedRequesterMockERC20BalanceAfterSecondFunding = FAST_WITHDRAWAL_REQUEST_AMOUNT -
                firstFundingFee -
                secondFundingFee;
        assertEq(
            mockERC20.balanceOf(FAST_WITHDRAWAL_REQUESTER),
            expectedRequesterMockERC20BalanceAfterSecondFunding,
            "2) mismatch requester mockERC20 balance"
        );

        // assert validator delayed withdrawal amount
        // should receives the remaining
        uint256 expectedValidator1DelayedWithdrawalAmountAfterSecondFunding = expectedRequesterDelayedWithdrawalAmountAfterFirstFunding;
        assertEq(
            sldTradeableExit.getUserDelayedWithdrawalAmount(
                REQUEST_ID,
                VALIDATOR_1
            ),
            expectedValidator1DelayedWithdrawalAmountAfterSecondFunding,
            "2) mismatch VALIDATOR_1 delayed withdrawal amount"
        );
    }

    function test_WithdrawFastWithdrawal0()
        public
        requestFastWithdrawalModifier
        fundFastWithdrawalModifier
    {
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

        // execute delayed withdrawal on L1 to simulate the exit being ready for withdrawal
        arbitrumGateway.setWithdrawalInfo(
            0, // exitNum
            FAST_WITHDRAWAL_REQUESTER,
            address(mockERC20),
            FAST_WITHDRAWAL_REQUEST_AMOUNT,
            address(sldTradeableExit)
        );

        vm.prank(VALIDATOR);
        sldTradeableExit.withdraw(REQUEST_ID, "");

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
