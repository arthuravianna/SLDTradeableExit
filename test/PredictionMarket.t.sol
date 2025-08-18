// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {PredictionMarket, Market} from "../src/PredictionMarket/PredictionMarket.sol";
import {MockERC20} from "./MockERC20.sol";



contract PredictionMarketTest is Test {
    using MessageHashUtils for bytes32;
    
    PredictionMarket predictionMarket = new PredictionMarket();
    MockERC20 erc20 = new MockERC20();

    uint256 constant market_duration = 604800; // one week
    address seller = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    uint256 sellerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address buyer = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 erc20Balance = 10000*10**18;

    function setUp() public {
        erc20.mint(seller, erc20Balance);
        erc20.mint(buyer, erc20Balance);

        erc20.approve(seller, address(predictionMarket), erc20Balance);
        erc20.approve(buyer, address(predictionMarket), erc20Balance);

        console.log("Prediction Market: ", address(predictionMarket));
        console.log("MockERC20: ", address(erc20));
    }


    function testFuzz_OpenMarket(bytes calldata market_id, address token) public {
        vm.warp(0);
        predictionMarket.openMarket(market_id, token);

        (uint8 market_open, address market_token, 
        uint256 market_timeout, uint256 seller_okBalance, 
        uint256 seller_failBalance) = predictionMarket.getMarketInfo(market_id, seller);

        assertEq(market_open, 1, "Error: market_open mismatch!");
        assertEq(market_token, token, "Error: market_token mismatch!");
        assertEq(market_duration, market_timeout, "Error: market_timeout mismatch!");
        assertEq(seller_okBalance, 0, "Error: okBalance mismatch!");
        assertEq(seller_failBalance, 0, "Error: failBalance mismatch!");
    }

    function testFuzz_BuyCompleteSets(bytes calldata market_id) public {
        predictionMarket.openMarket(market_id, address(erc20));

        vm.prank(buyer);
        predictionMarket.buyCompleteSets(market_id, 1000);

        assertEq(erc20.balanceOf(address(predictionMarket)), 1000, "Error: ERC20 Prediction Market balance mismatch!");

        (,,, 
        uint256 buyer_okBalance, uint256 buyer_failBalance) = predictionMarket.getMarketInfo(market_id, buyer);

        assertEq(buyer_okBalance, 1000, "Error: CompleteSet buyer okBalance mismatch!");
        assertEq(buyer_failBalance, 1000, "Error: CompleteSet buyer failBalance mismatch!");
    }

    function testFuzz_SellCompleteSets(bytes calldata market_id) public {
        predictionMarket.openMarket(market_id, address(erc20));

        vm.startPrank(seller);
        predictionMarket.buyCompleteSets(market_id, 1000);
        predictionMarket.sellCompleteSets(market_id, 1000);
        vm.stopPrank();

        assertEq(erc20.balanceOf(address(predictionMarket)), 0, "Error: ERC20 Prediction Market balance mismatch!");
        assertEq(erc20.balanceOf(seller), erc20Balance, "Error: ERC20 seller balance mismatch!");

        (,,, 
        uint256 seller_okBalance, uint256 seller_failBalance) = predictionMarket.getMarketInfo(market_id, seller);

        assertEq(seller_okBalance, 0, "Error: CompleteSet seller okBalance mismatch!");
        assertEq(seller_failBalance, 0, "Error: CompleteSet seller failBalance mismatch!");
    }

    function test_Exchange(bytes calldata market_id) public {
        predictionMarket.openMarket(market_id, address(erc20));
        uint8 set_id = 1; // fail
        uint256 volume = 1000;
        uint256 payment = 1000;

        vm.prank(seller);
        predictionMarket.buyCompleteSets(market_id, volume);

        vm.prank(buyer);
        // seller intention message && signature
        bytes32 sellIntentionMessage = keccak256(abi.encodePacked(set_id, volume, payment)).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sellerPrivateKey, sellIntentionMessage);
        bytes memory sellIntentionSignature = abi.encodePacked(r, s, v);

        predictionMarket.exchange(market_id, set_id, seller, volume, payment, sellIntentionSignature);

        (,,,uint256 seller_okBalance, uint256 seller_failBalance) = predictionMarket.getMarketInfo(market_id, seller);
        (,,,uint256 buyer_okBalance, uint256 buyer_failBalance) = predictionMarket.getMarketInfo(market_id, buyer);
        assertEq(seller_okBalance, volume, "Error: seller okBalance mismatch!");
        assertEq(seller_failBalance, 0, "Error: seller failBalance mismatch!");
        assertEq(buyer_okBalance, 0, "Error: buyer okBalance mismatch!");
        assertEq(buyer_failBalance, volume, "Error: buyer failBalance mismatch!");
    }

    function test_CloseMarket() public {
        address rollup = address(0);
        address requester = address(0);
        uint256 price = 0;
        uint256 input_index = 0;
        uint256 voucher_index = 0;
        bytes memory market_id = abi.encode(rollup, requester, price, input_index, voucher_index);
        
        vm.warp(0);
        predictionMarket.openMarket(market_id, address(erc20));

        vm.warp(market_duration+1);
        predictionMarket.closeMarket(market_id);

        (uint8 open,,,,) = predictionMarket.getMarketInfo(market_id, seller);

        assertEq(open, 0, "Error: Prediction Market open mismatch!");
    }
}