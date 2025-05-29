// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// A token that works as a ticket for fast withdrawal
// it can only be minted, burned, and transfered by the Tradeable Exit smart-contract.
// "balanceOf" and "transfer" functions where disabled.
interface IFastWithdrawalTicket is IERC20 {
    function balanceOf(address account) external view override returns (uint256);

    function transfer(address to, uint256 value) external override returns (bool);

    function balanceOf(bytes calldata request_id, address account) external view returns (uint256);

    function mint(bytes calldata request_id, address account, uint256 value) external;

    function burn(bytes calldata request_id, address account, uint256 value) external;

    function transferFrom(address from, address to, uint256 value) external override returns (bool);
}
