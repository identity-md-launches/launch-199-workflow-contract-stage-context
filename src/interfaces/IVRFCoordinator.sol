// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal ABI of the Chainlink VRF v2.5 subscription coordinator.
/// @dev Field order/types match VRFV2PlusClient.RandomWordsRequest.
interface IVRFCoordinator {
    struct RandomWordsRequest {
        bytes32 keyHash;
        uint256 subId;
        uint16 requestConfirmations;
        uint32 callbackGasLimit;
        uint32 numWords;
        bytes extraArgs;
    }

    function requestRandomWords(RandomWordsRequest calldata request) external returns (uint256 requestId);
}
