// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TradeableExit} from "../src/TradeableExit/TradeableExit.sol";
import {MockERC20} from "./MockERC20.sol";
import {CartesiDappMock} from "./CartesiDappMock.sol";
import {Proof, OutputValidityProof} from "@cartesi/rollups/contracts/dapp/ICartesiDApp.sol";
import {InputBox} from "@cartesi/rollups/contracts/inputs/InputBox.sol";

contract TradeableExitTest is Test, TradeableExit {
    uint256 constant FAST_WITHDRAWAL_REQUEST_AMOUNT = 100*1e18; // 100 tokens
    uint256 constant FAST_WITHDRAWAL_TIMESTAMP = 0;
    uint256 constant INPUT_INDEX = 0;
    uint256 constant VOUCHER_INDEX = 0;

    function setUp() public {}

    function requestFastWithdrawal(bytes calldata _requestId, address _token, uint256 _amount, uint256 _inputTimestamp)
        external virtual payable override {
            return;
    }

    function fundFastWithdrawalRequest(bytes calldata _requestId, IERC20 _token, uint256 _amount) external virtual override {
        return;
    }

    function withdraw(
        bytes calldata _requestId,
        bytes calldata _data
    ) external virtual override {
        return;
    }
    
    function test_CalculateVariableFee() public {
        uint256 bps = 1000000; // 1%
        uint256 fee = _calculateVariableFee(FAST_WITHDRAWAL_REQUEST_AMOUNT, bps);

        uint256 expectedFee = 1e18; // 1 token
        assertEq(fee, expectedFee, "Mismatch Expected Fee");
    }
}
