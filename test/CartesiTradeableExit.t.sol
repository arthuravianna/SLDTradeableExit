// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    CartesiTradeableExit, FastWithdrawalRequest
} from "../src/Cartesi/CartesiTradeableExit.sol";
import {MockERC20} from "./MockERC20.sol";
import {CartesiDappMock} from "./CartesiDappMock.sol";
import {Proof, OutputValidityProof} from "@cartesi/rollups/contracts/dapp/ICartesiDApp.sol";

contract SLDTradeableExitTest is Test {
    CartesiTradeableExit public tradeable_exit = new CartesiTradeableExit();
    MockERC20 public mockERC20;
    CartesiDappMock public cartesiDappMock;

    address requester0 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address requester1 = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;

    // validators
    address validator0 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address validator1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

    // fast withdrawal request info
    uint256 fw_amount = 100000000000000000000;
    uint256 fw_price =   90000000000000000000;
    uint256 fw_request_timestamp = 0;
    uint256 validatorMockERC20InitialBalance = 2 * fw_amount;
    bytes request0_id;
    bytes request1_id;

    function setUp() public {
        mockERC20 = new MockERC20();
        mockERC20.mint(validator0, validatorMockERC20InitialBalance);
        mockERC20.mint(validator1, validatorMockERC20InitialBalance);
        mockERC20.mint(address(tradeable_exit), 2 * fw_amount); // tradeable_exit needs balance to test withdrawal

        mockERC20.approve(validator0, address(tradeable_exit), validatorMockERC20InitialBalance);
        mockERC20.approve(validator1, address(tradeable_exit), validatorMockERC20InitialBalance);

        cartesiDappMock = new CartesiDappMock();

        request0_id = abi.encode(address(cartesiDappMock), requester0, fw_price, uint256(0), uint256(0));
        request1_id = abi.encode(address(cartesiDappMock), requester1, fw_price, uint256(1), uint256(0));

        // setup a fastWithdrawalRequest (used to test the funding and withdraw)
        vm.prank(requester0);
        tradeable_exit.requestFastWithdrawal(request0_id, address(mockERC20), fw_amount, fw_request_timestamp);

        vm.prank(requester1);
        tradeable_exit.requestFastWithdrawal(request1_id, address(mockERC20), fw_amount, fw_request_timestamp);

        vm.prank(validator1);
        tradeable_exit.fundFastWithdrawalRequest(request1_id, mockERC20, 0);

        console.log("SLDTradeableExit:", address(tradeable_exit));
        console.log("MockERC20:", address(mockERC20));
        console.log("CartesiDappMock:", address(cartesiDappMock));
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

        bytes memory request_id = abi.encode(dapp, requester1, fw_price, input_index, voucher_index);
        tradeable_exit.requestFastWithdrawal(request_id, token, amount, input_timestamp);

        FastWithdrawalRequest memory requestExpected =
            FastWithdrawalRequest(request_id, token, input_timestamp, amount, 0, 0);
        FastWithdrawalRequest memory requestActual = tradeable_exit.getFastWithdrawalRequest(request_id);

        assertEq(requestActual.id, request_id, "request_id mismatch");
        assertEq(requestActual.timestamp, requestExpected.timestamp, "timestamp mismatch");
        assertEq(requestActual.token, requestExpected.token, "token mismatch");
        assertEq(requestActual.amount, requestExpected.amount, "amount mismatch");
    }

    function test_FundFastWithdrawalRequestNotFound() public {
        vm.expectRevert();

        bytes memory request_id = abi.encode(address(0), requester0, 0, 0);
        tradeable_exit.fundFastWithdrawalRequest(request_id, mockERC20, fw_amount);
    }

    // A single validator funds the request
    function test_FundFastWithdrawalRequest0() public {
        vm.prank(validator0);

        tradeable_exit.fundFastWithdrawalRequest(request0_id, mockERC20, fw_amount);

        // assert withdrawal recipient
        assertEq(tradeable_exit.getRecipient(request0_id), validator0, "mismatch withdrawal recipient");

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

        assertEq(mockERC20.balanceOf(requester1), fw_price, "1) mismatch requester1 mockERC20 balance AFTER funding");
        assertEq(mockERC20.balanceOf(validator1), validatorMockERC20InitialBalance-fw_price, "2) mismatch validator1 mockERC20 balance BEFORE withdraw");
        
        vm.prank(validator1);
        tradeable_exit.withdraw(
            request1_id, 
            address(mockERC20), 
            voucher_payload,
            voucher_proof
        );

        uint256 fee = fw_amount-fw_price;
        assertEq(mockERC20.balanceOf(validator1), validatorMockERC20InitialBalance+fee, "3) mismatch validator1 mockERC20 balance AFTER withdraw");
    }
}