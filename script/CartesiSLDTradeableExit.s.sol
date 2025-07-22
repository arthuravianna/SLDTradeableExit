// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {CartesiSLDTradeableExit} from "../src/CartesiSLDTradeableExit/CartesiSLDTradeableExit.sol";

contract CartesiSLDTradeableExitScript is Script {
    CartesiSLDTradeableExit public cartesiSldTradeableExit;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        bytes32 MY_SALT = 0;
        cartesiSldTradeableExit = new CartesiSLDTradeableExit{salt: MY_SALT}();

        vm.stopBroadcast();
    }
}