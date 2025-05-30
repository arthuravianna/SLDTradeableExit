// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// A token that works as a ticket for fast withdrawal
// it can only be minted, burned, and transfered by the Tradeable Exit smart-contract.
// "balanceOf" and "transfer" functions where disabled.
contract FastWithdrawalTicket is ERC20, Ownable {
    mapping(bytes => mapping(address => uint256)) private _balances;

    constructor() ERC20("FastWithdrawalTicket", "FWT") Ownable(msg.sender) {}

    function balanceOf(address account) public view override returns (uint256) {
        revert("USE_balanceOf(bytes request_id, address account)_INSTEAD");
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        revert("transfer_NOT_SUPPORTED");
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        revert("transferFrom_NOT_SUPPORTED");
    }

    function balanceOf(bytes calldata request_id, address account) public view returns (uint256) {
        return _balances[request_id][account];
    }

    function mint(bytes calldata request_id, address account, uint256 value) public onlyOwner {
        _balances[request_id][account] += value;
        _mint(account, value);
    }

    function burn(bytes calldata request_id, address account, uint256 value) public onlyOwner {
        _balances[request_id][account] -= value;
        _burn(account, value);
    }

    function transferFrom(bytes calldata request_id, address from, address to, uint256 value) public onlyOwner returns (bool) {
        address spender = _msgSender();

        _balances[request_id][from] -= value;
        _balances[request_id][to] += value;

        _transfer(from, to, value);
        emit Transfer(from, to, value);

        return true;
    }
}
