// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;
import {ICartesiDApp, IConsensus, Proof} from "@cartesi/rollups/contracts/dapp/ICartesiDApp.sol";

contract CartesiDappMock is ICartesiDApp {
    function migrateToConsensus(IConsensus _newConsensus) external override {}

    function executeVoucher(
        address _destination,
        bytes calldata _payload,
        Proof calldata _proof
    ) external override returns (bool) {
        return true;
    }

    function wasVoucherExecuted(
        uint256 _inputIndex,
        uint256 _outputIndexWithinInput
    ) external view override returns (bool) {
        return true;
    }

    function validateNotice(
        bytes calldata _notice,
        Proof calldata _proof
    ) external view override returns (bool) {
        return true;
    }

    function getTemplateHash() external view override returns (bytes32) {
        return 0x0;
    }

    function getConsensus() external view override returns (IConsensus) {
        return IConsensus(address(0));
    }
}