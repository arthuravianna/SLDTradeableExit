// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {SLDTradeableExitFactory} from "../src/CartesiSLDTradeableExit/CartesiSLDTradeableExitFactory.sol";
import {FastWithdrawalTicket} from "../src/FastWithdrawalTicket/FastWithdrawalTicket.sol";
import {SLDTradeableExit} from "../src/CartesiSLDTradeableExit/CartesiSLDTradeableExit.sol";

contract CartesiSLDTradeableExit is Script {
    CartesiSLDTradeableExit public cartesiSldTradeableExit;
    FastWithdrawalTicket public tickets;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        SLDTradeableExitFactory factory = new SLDTradeableExitFactory();
        address ticketTokenAddress;
        address sldTradeableExitAddress;
        (ticketTokenAddress, sldTradeableExitAddress) = factory.deploy();

        cartesiSldTradeableExit = CartesiSLDTradeableExit(sldTradeableExitAddress);
        tickets = FastWithdrawalTicket(ticketTokenAddress);

        vm.stopBroadcast();
    }
}