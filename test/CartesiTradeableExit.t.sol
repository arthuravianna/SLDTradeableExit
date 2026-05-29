// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CartesiTradeableExit, FastWithdrawalRequest} from "../src/Cartesi/CartesiTradeableExit.sol";
import {MockERC20} from "./MockERC20.sol";
import {CartesiDappMock} from "./CartesiDappMock.sol";
import {Proof, OutputValidityProof} from "@cartesi/rollups/contracts/dapp/ICartesiDApp.sol";
import {InputBox} from "@cartesi/rollups/contracts/inputs/InputBox.sol";

contract CartesiTradeableExitTest is Test {
    CartesiTradeableExit public tradeableExit = new CartesiTradeableExit();
    MockERC20 public mockERC20;
    CartesiDappMock public cartesiDappMock = new CartesiDappMock();

    address FAST_WITHDRAWAL_REQUESTER = makeAddr("FastWithdrawalRequester");
    address VALIDATOR = makeAddr("Validator");
    uint256 constant VALIDATOR_MOCK_ERC20_INITIAL_BALANCE = 1e21; // 1000 tokens
    uint256 constant FAST_WITHDRAWAL_REQUEST_AMOUNT = 1e20; // 100 tokens
    uint256 constant FAST_WITHDRAWAL_TIMESTAMP = 0;
    uint256 constant INPUT_INDEX = 0;
    uint256 constant VOUCHER_INDEX = 0;
    bytes REQUEST_ID =
        abi.encode(
            address(cartesiDappMock),
            FAST_WITHDRAWAL_REQUESTER,
            INPUT_INDEX,
            VOUCHER_INDEX
        );
    address constant INPUT_BOX_ADDRESS =
        0x59b22D57D4f067708AB0c00552767405926dc768;
    uint256 constant BLOCK_NUMBER = 0;
    bytes constant WITHDRAWAL_INPUT =
        "0x7b226f70223a20227769746864726177616c222c2022746f6b656e223a2022307864323463326265333865363333343236356362653134623637643533333566363431653539623639222c2022616d6f756e74223a203130303030303030303030303030303030303030307d";

    function setUp() public {
        mockERC20 = new MockERC20();
        mockERC20.mint(VALIDATOR, VALIDATOR_MOCK_ERC20_INITIAL_BALANCE);
        mockERC20.approve(
            VALIDATOR,
            address(tradeableExit),
            VALIDATOR_MOCK_ERC20_INITIAL_BALANCE
        );
        // give some ether to the requester to pay for the flat fee
        vm.deal(FAST_WITHDRAWAL_REQUESTER, 1 ether);

        // tradeableExit needs balance to test withdrawal
        // this is the value available in the contract after the delayed withdrawal is executed,
        // so we mint this amount to the contract before testing the withdrawal
        mockERC20.mint(address(tradeableExit), FAST_WITHDRAWAL_REQUEST_AMOUNT);

        console.log("TradeableExit:", address(tradeableExit));
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
        tradeableExit.fundFastWithdrawal(REQUEST_ID, mockERC20, 0);
        _;
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
        bytes memory requestId = abi.encode(address(0), randomRequester, 0, 0);

        tradeableExit.fundFastWithdrawal(requestId, mockERC20, 0);
    }

    function test_FundFastWithdrawalRequest0()
        public
        requestFastWithdrawalModifier
    {
        vm.prank(VALIDATOR);

        tradeableExit.fundFastWithdrawal(REQUEST_ID, mockERC20, 0);

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

        vm.prank(VALIDATOR);
        tradeableExit.withdrawFastWithdrawal(REQUEST_ID, data);

        uint256 fee = FAST_WITHDRAWAL_REQUEST_AMOUNT - withdrawalPrice;
        assertEq(
            mockERC20.balanceOf(VALIDATOR),
            VALIDATOR_MOCK_ERC20_INITIAL_BALANCE + fee,
            "3) mismatch VALIDATOR mockERC20 balance AFTER withdraw"
        );
    }
}
