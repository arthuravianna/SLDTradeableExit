// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {L1ArbitrumGatewayMock} from "./mocks/L1ArbitrumGatewayMock.sol";
import {ArbitrumTradeableExit, FastWithdrawalRequest} from "../src/Arbitrum/ArbitrumTradeableExit.sol";
import {MockERC20} from "./MockERC20.sol";

contract ArbitrumTradeableExitTest is Test {
    address FAST_WITHDRAWAL_REQUESTER = makeAddr("FastWithdrawalRequester");
    address VALIDATOR = makeAddr("Validator");
    uint256 constant VALIDATOR_MOCK_ERC20_INITIAL_BALANCE = 1e21; // 1000 tokens
    uint256 constant FAST_WITHDRAWAL_REQUEST_AMOUNT = 1e20; // 100 tokens
    uint256 constant FAST_WITHDRAWAL_TIMESTAMP = 0;
    bytes REQUEST_ID = abi.encode(FAST_WITHDRAWAL_REQUESTER, 0); // address, exitNum

    L1ArbitrumGatewayMock public arbitrumGateway;
    ArbitrumTradeableExit public tradeableExit;
    MockERC20 public mockERC20;

    function setUp() public {
        arbitrumGateway = new L1ArbitrumGatewayMock();
        tradeableExit = new ArbitrumTradeableExit(address(arbitrumGateway));
        mockERC20 = new MockERC20();
        mockERC20.mint(VALIDATOR, VALIDATOR_MOCK_ERC20_INITIAL_BALANCE);
        mockERC20.approve(
            VALIDATOR,
            address(tradeableExit),
            VALIDATOR_MOCK_ERC20_INITIAL_BALANCE
        );

        // give some ether to the requester to pay for the flat fee
        vm.deal(FAST_WITHDRAWAL_REQUESTER, 1 ether);
    }

    modifier requestFastWithdrawalModifier() {
        vm.startPrank(FAST_WITHDRAWAL_REQUESTER);
        vm.warp(FAST_WITHDRAWAL_TIMESTAMP);

        tradeableExit.requestFastWithdrawal{
            value: tradeableExit.DEFAULT_FLAT_FEE()
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
        tradeableExit.fundFastWithdrawalRequest(REQUEST_ID, mockERC20, 0);
        _;
    }

    function testFuzz_RequestFastWithdrawal(
        address token,
        uint256 amount,
        uint256 exitNum,
        uint256 inputTimestamp
    ) public {
        vm.startPrank(FAST_WITHDRAWAL_REQUESTER);
        // assume a "safe" value for amount
        vm.assume(amount < 1e36);

        bytes memory requestId = abi.encode(FAST_WITHDRAWAL_REQUESTER, exitNum);
        tradeableExit.requestFastWithdrawal{
            value: tradeableExit.DEFAULT_FLAT_FEE()
        }(requestId, token, amount, inputTimestamp);

        FastWithdrawalRequest memory requestExpected = FastWithdrawalRequest(
            requestId,
            token,
            inputTimestamp,
            amount,
            0
        );
        FastWithdrawalRequest memory requestActual = tradeableExit
            .getFastWithdrawalRequest(requestId);

        vm.stopPrank();

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
    }

    function test_FundFastWithdrawalRequestNotFound() public {
        vm.expectRevert();

        address randomRequester = makeAddr("RandomRequester");
        bytes memory requestId = abi.encode(randomRequester, 0);

        tradeableExit.fundFastWithdrawalRequest(requestId, mockERC20, 0);
    }

    function test_FundFastWithdrawalRequest0()
        public
        requestFastWithdrawalModifier
    {
        vm.prank(VALIDATOR);

        tradeableExit.fundFastWithdrawalRequest(REQUEST_ID, mockERC20, 0);

        // assert withdrawal recipient
        assertEq(
            tradeableExit.getRecipient(REQUEST_ID),
            VALIDATOR,
            "mismatch withdrawal recipient"
        );

        // assert request is funded
        assertEq(
            mockERC20.balanceOf(FAST_WITHDRAWAL_REQUESTER),
            tradeableExit.getWithdrawalPrice(
                FAST_WITHDRAWAL_REQUEST_AMOUNT,
                tradeableExit.BPS()
            ),
            "mismatch amount funded"
        );
    }

    function test_WithdrawFastWithdrawal0()
        public
        requestFastWithdrawalModifier
        fundFastWithdrawalModifier
    {
        uint256 withdrawalPrice = tradeableExit.getWithdrawalPrice(
            FAST_WITHDRAWAL_REQUEST_AMOUNT,
            tradeableExit.BPS()
        );
        assertEq(
            mockERC20.balanceOf(FAST_WITHDRAWAL_REQUESTER),
            withdrawalPrice,
            "1) mismatch FAST_WITHDRAWAL_REQUESTER mockERC20 balance AFTER funding"
        );
        assertEq(
            mockERC20.balanceOf(VALIDATOR),
            VALIDATOR_MOCK_ERC20_INITIAL_BALANCE - withdrawalPrice,
            "2) mismatch VALIDATOR mockERC20 balance BEFORE withdraw"
        );

        // execute delayed withdrawal on L1 to simulate the exit being ready for withdrawal
        arbitrumGateway.setWithdrawalInfo(
            0, // exitNum
            FAST_WITHDRAWAL_REQUESTER,
            address(mockERC20),
            FAST_WITHDRAWAL_REQUEST_AMOUNT,
            address(tradeableExit)
        );
        mockERC20.mint(address(tradeableExit), FAST_WITHDRAWAL_REQUEST_AMOUNT);

        // perform withdrawal
        vm.prank(VALIDATOR);
        tradeableExit.withdraw(REQUEST_ID, bytes(""));

        uint256 fee = FAST_WITHDRAWAL_REQUEST_AMOUNT - withdrawalPrice;
        assertEq(
            mockERC20.balanceOf(VALIDATOR),
            VALIDATOR_MOCK_ERC20_INITIAL_BALANCE + fee,
            "3) mismatch VALIDATOR mockERC20 balance AFTER withdraw"
        );
    }
}
