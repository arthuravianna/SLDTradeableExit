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

    uint256 constant mock_volume = 1000;
    bytes constant mock_market_id0 = abi.encode(address(0), address(0), 0, 0, 0);
    bytes constant mock_market_id1 = abi.encode(address(1), address(0), 0, 0, 0);

    function setUp() public {
        erc20.mint(seller, erc20Balance);
        erc20.mint(buyer, erc20Balance);

        erc20.approve(seller, address(predictionMarket), erc20Balance);
        erc20.approve(buyer, address(predictionMarket), erc20Balance);
        
        vm.warp(0);
        predictionMarket.openMarket(mock_market_id0, address(erc20));

        predictionMarket.openMarket(mock_market_id1, address(erc20));
        vm.prank(seller);
        predictionMarket.buyCompleteSets(mock_market_id1, mock_volume);


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

    function test_BuyCompleteSets() public {
        vm.prank(buyer);
        predictionMarket.buyCompleteSets(mock_market_id0, mock_volume);

        // 2 * volume because we have two markets
        assertEq(erc20.balanceOf(address(predictionMarket)), 2*mock_volume, "Error: ERC20 Prediction Market balance mismatch!");

        (,,, 
        uint256 buyer_okBalance, uint256 buyer_failBalance) = predictionMarket.getMarketInfo(mock_market_id0, buyer);

        assertEq(buyer_okBalance, mock_volume, "Error: CompleteSet buyer okBalance mismatch!");
        assertEq(buyer_failBalance, mock_volume, "Error: CompleteSet buyer failBalance mismatch!");
    }

    function test_SellCompleteSets() public {
        vm.prank(seller);
        predictionMarket.sellCompleteSets(mock_market_id1, mock_volume);

        assertEq(erc20.balanceOf(address(predictionMarket)), 0, "Error: ERC20 Prediction Market balance mismatch!");
        assertEq(erc20.balanceOf(seller), erc20Balance, "Error: ERC20 seller balance mismatch!");

        (,,, 
        uint256 seller_okBalance, uint256 seller_failBalance) = predictionMarket.getMarketInfo(mock_market_id1, seller);

        assertEq(seller_okBalance, 0, "Error: CompleteSet seller okBalance mismatch!");
        assertEq(seller_failBalance, 0, "Error: CompleteSet seller failBalance mismatch!");
    }

    function test_Exchange() public {
        uint8 set_id = 1; // fail
        uint256 volume = 1000;
        uint256 payment = 1000;

        vm.prank(buyer);
        // seller intention message && signature
        bytes32 sellIntentionMessage = keccak256(abi.encodePacked(set_id, volume, payment)).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sellerPrivateKey, sellIntentionMessage);
        bytes memory sellIntentionSignature = abi.encodePacked(r, s, v);

        predictionMarket.exchange(mock_market_id1, set_id, seller, volume, payment, sellIntentionSignature);

        (,,,uint256 seller_okBalance, uint256 seller_failBalance) = predictionMarket.getMarketInfo(mock_market_id1, seller);
        (,,,uint256 buyer_okBalance, uint256 buyer_failBalance) = predictionMarket.getMarketInfo(mock_market_id1, buyer);
        assertEq(seller_okBalance, volume, "Error: seller okBalance mismatch!");
        assertEq(seller_failBalance, 0, "Error: seller failBalance mismatch!");
        assertEq(buyer_okBalance, 0, "Error: buyer okBalance mismatch!");
        assertEq(buyer_failBalance, volume, "Error: buyer failBalance mismatch!");
    }

    function test_CloseMarket() public {
        vm.warp(market_duration+1);
        predictionMarket.closeMarket(mock_market_id0);

        (uint8 open,,,,) = predictionMarket.getMarketInfo(mock_market_id0, seller);

        assertEq(open, 0, "Error: Prediction Market open mismatch!");
    }
}