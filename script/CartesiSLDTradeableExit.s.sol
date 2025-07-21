// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {CartesiSLDTradeableExit} from "../src/CartesiSLDTradeableExit/CartesiSLDTradeableExit.sol";

contract CartesiSLDTradeableExitScript is Script {
    CartesiSLDTradeableExit public cartesiSldTradeableExit;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        cartesiSldTradeableExit = new CartesiSLDTradeableExit();

        vm.stopBroadcast();
    }
}