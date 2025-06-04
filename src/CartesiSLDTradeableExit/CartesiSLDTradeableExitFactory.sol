// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {FastWithdrawalTicket} from "../FastWithdrawalTicket/FastWithdrawalTicket.sol";
import {CartesiSLDTradeableExit} from "./CartesiSLDTradeableExit.sol";

contract SLDTradeableExitFactory {
    event TokenDeployed(address token, address ownerContract);

    function deploy() external returns (address token, address tokenOwner) {
        FastWithdrawalTicket ticketToken = new FastWithdrawalTicket();
        CartesiSLDTradeableExit tradeableExitContract = new CartesiSLDTradeableExit(address(ticketToken));

        // Transfer ownership to the tradeableExitContract
        ticketToken.transferOwnership(address(tradeableExitContract));

        emit TokenDeployed(address(ticketToken), address(tradeableExitContract));
        return (address(ticketToken), address(tradeableExitContract));
    }
}
