// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

//import {IL1ArbitrumGateway} from "../../arbitrum-token-bridge/contracts/tokenbridge/ethereum/gateway/IL1ArbitrumGateway.sol";
import {IL1ArbitrumGateway} from "lib/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/IL1ArbitrumGateway.sol";

contract L1ArbitrumGatewayMock is IL1ArbitrumGateway {
    mapping(uint256 => WithdrawalInfo) public withdrawals;

    function setWithdrawalInfo(
        uint256 exitNum,
        address requester,
        address l1Token,
        uint256 amount,
        address to
    ) external {
        withdrawals[exitNum] = WithdrawalInfo({
            l1Token: l1Token,
            from: requester,
            to: to,
            amount: amount
        });
    }

    function getWithdrawalInfo(
        uint256 exitNum
    ) external view returns (WithdrawalInfo memory) {
        return withdrawals[exitNum];
    }

    function inbox() external view returns (address) {
        return address(0);
    }

    function outboundTransferCustomRefund(
        address _l1Token,
        address _refundTo,
        address _to,
        uint256 _amount,
        uint256 _maxGas,
        uint256 _gasPriceBid,
        bytes calldata _data
    ) external payable returns (bytes memory) {
        return "";
    }

    function outboundTransfer(
        address _token,
        address _to,
        uint256 _amount,
        uint256 _maxGas,
        uint256 _gasPriceBid,
        bytes calldata _data
    ) external payable returns (bytes memory) {
        return "";
    }

    function finalizeInboundTransfer(
        address _token,
        address _from,
        address _to,
        uint256 _amount,
        bytes calldata _data
    ) external payable {}

    function calculateL2TokenAddress(
        address l1ERC20
    ) external view returns (address) {
        return address(0);
    }

    function getOutboundCalldata(
        address _token,
        address _from,
        address _to,
        uint256 _amount,
        bytes memory _data
    ) external view returns (bytes memory) {
        return "";
    }

    function supportsInterface(
        bytes4 interfaceId
    ) external view returns (bool) {
        return true;
    }
}
