// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import {ICartesiDApp, Proof} from "@cartesi/rollups/contracts/dapp/ICartesiDApp.sol";

// 1) anyone opens the market for a given epoch
// 2) every x deposit/submission to the market generates OK or FAIL token/shares
// 3) After the epoch ends, anyone can close the market
// 4) Anyone can exchange their shares for the original token. 1 OK == 1 Token if epoch is valid, otherwise 1 FAIL = 1 Token

// Tradeable Exit request_id = abi.encode(rollup, requester, price, input_index, voucher_index)
// match_id = request_id

struct Market {
    uint8 open; // 0 = closed, 1 = open
    address token;
    uint256 timeout;
    uint24 price;
    uint8 result;
    mapping(address => uint256) ok;
    mapping(address => uint256) fail;
}

contract PredictionMarket {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;
    using Address for address;
    
    mapping(bytes => Market) public markets;
    uint24 internal constant market_timeout = 604800; // one week

    constructor() {}

    function openMarket(bytes calldata market_id, address token) public {
        // 1) check if it already exists using address
        Market storage market = markets[market_id];
        require(market.token == address(0), "Error: Market already exists!");

        market.open = 1;
        market.token = token;
        market.timeout = block.timestamp + market_timeout;
        market.price = 1;
    }

    function buyCompleteSets(bytes calldata market_id, uint256 volume) public {
        Market storage market = markets[market_id];
        require(market.open == 1, "Error: Market is closed!");

        IERC20 erc20 = IERC20(market.token);
        bool success = erc20.transferFrom(msg.sender, address(this), volume * market.price);
        require(success, "Error: Failed to buy sets!");
        
        market.ok[msg.sender] += volume;
        market.fail[msg.sender] += volume;
    }

    function sellCompleteSets(bytes calldata market_id, uint256 volume) public {
        Market storage market = markets[market_id];
        require(market.open == 1, "Error: Market is closed!");

        require(volume <= market.ok[msg.sender], "Error: Not enough 'OK' volume to sell");
        require(volume <= market.fail[msg.sender], "Error: Not enough 'FAIL' volume to sell");

        IERC20 erc20 = IERC20(market.token);
        bool success = erc20.transfer(msg.sender, volume * market.price);
        require(success, "Error: Failed to sell sets!");

        market.ok[msg.sender] -= volume;
        market.fail[msg.sender] -= volume;
    }

    // seller signs a message with the value for a specific set
    // buyer calls exchange function with signed messaged as parameter.
    function exchange(bytes calldata market_id, uint8 set_id, address seller, 
     uint256 volume, uint256 payment,
     bytes calldata sellIntentionSignature) public {
        Market storage market = markets[market_id];

        require(market.open == 1, "Error: Unable to exchange, market is closed!");
        require(market.timeout >= block.timestamp, "Error: Unable to exchange, market timeout!");

        bytes32 sellIntentionMessage = keccak256(abi.encodePacked(set_id, volume, payment));

        require(_verifySignature(sellIntentionMessage, seller, sellIntentionSignature), 
         "Error: Invalid signature");

        IERC20 erc20 = IERC20(market.token);
        bool success = erc20.transfer(seller, payment);
        require(success, "Error: Failed to execute exchange payment!");

        if (set_id == 0) { // sell ok set
            require(market.ok[seller] >= volume, "Error: Failed to execute exchange volume!");
            market.ok[seller] -= volume;
            market.ok[msg.sender] += volume;
        } else if (set_id == 1) { // sell fail set
            require(market.fail[seller] >= volume, "Error: Failed to execute exchange volume!");
            market.fail[seller] -= volume;
            market.fail[msg.sender] += volume;
        } else {
            revert("Error: Invalid set!");
        }
    }

    function closeMarket(bytes calldata market_id) public {
        (address dapp,,, uint256 input_index, uint256 voucher_index) =
         abi.decode(market_id, (address, address, uint256, uint256, uint256));

        Market storage market = markets[market_id];
        require(market.open == 1, "Error: Market already closed or does not exists!");
        
        if (block.timestamp < market.timeout) {
            ICartesiDApp cartesi_dapp = ICartesiDApp(dapp);
            require(cartesi_dapp.wasVoucherExecuted(input_index, voucher_index), 
             "Error: Unable to close market, voucher not executed!");
        }

        market.open = 0;
    }


    // message = keccak256 hash value of the message
    // signer = signer address
    // signature = signature
    function _verifySignature(
        bytes32 message,
        address signer,
        bytes memory signature
    ) private pure returns (bool) {
        bytes32 hash = message.toEthSignedMessageHash(); // add the prefix '\x19Ethereum Signed Message:\n'
        address recoveredSigner = hash.recover(signature);
        return signer == recoveredSigner;
    }


    function withdrawFromMarket(bytes calldata match_id) public {
        Market storage market = markets[match_id];
        require(market.token != address(0), "Error: Market does not exists!");
        require(market.open == 0, "Error: Market must be closed to withdraw!");

        IERC20 erc20 = IERC20(market.token);
        uint256 transfer_amount = market.ok[msg.sender] + market.fail[msg.sender];
        bool success = erc20.transfer(msg.sender, transfer_amount);
        require(success, "Error: Failed to withdraw from market!");
    }

    function getMarketInfo(bytes calldata match_id, address user) public view returns (
        uint8 open,
        address token,
        uint256 timeout,
        uint256 okBalance,
        uint256 failBalance
    ) {
        Market storage market = markets[match_id];
        open = market.open;
        token = market.token;
        timeout = market.timeout;
        okBalance = market.ok[user];
        failBalance = market.fail[user];
    }
}