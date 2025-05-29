// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {FastWithdrawalTicket} from "./FastWithdrawalTicket.sol";
import {SLDTradeableExit} from "./SLDTradeableExit.sol";

contract SLDTradeableExitFactory {
    event TokenDeployed(address token, address ownerContract);

    function deploy() external returns (address token, address tokenOwner) {
        FastWithdrawalTicket ticketToken = new FastWithdrawalTicket();
        SLDTradeableExit tradeableExitContract = new SLDTradeableExit(address(ticketToken));

        // Transfer ownership to the tradeableExitContract
        ticketToken.transferOwnership(address(tradeableExitContract));

        emit TokenDeployed(address(ticketToken), address(tradeableExitContract));
        return (address(ticketToken), address(tradeableExitContract));
    }
}
