// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IVRFCoordinator} from "../../src/interfaces/IVRFCoordinator.sol";

interface IVRFConsumer {
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata words) external;
}

/// @dev Deterministic test double, NOT a VRF proof verifier or a deployable randomness source.
contract MockCoordinator is IVRFCoordinator {
    uint256 public nextId = 1;
    bool public rejectRequests;
    mapping(uint256 => address) public consumers;
    RandomWordsRequest private last;
    address public reentryTarget;
    bytes public reentryData;
    bool public reentrySucceeded;
    bytes public reentryResult;

    function setRejectRequests(bool reject) external {
        rejectRequests = reject;
    }

    function setNextId(uint256 id) external {
        nextId = id;
    }

    function setReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryData = data;
    }

    function requestRandomWords(RandomWordsRequest calldata request) external returns (uint256 id) {
        require(!rejectRequests, "subscription unavailable");
        last = request;
        if (reentryTarget != address(0)) {
            (reentrySucceeded, reentryResult) = reentryTarget.call(reentryData);
        }
        id = nextId++;
        consumers[id] = msg.sender;
    }

    function lastRequest() external view returns (RandomWordsRequest memory) {
        return last;
    }

    function fulfill(uint256 id, uint256 word) external {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        IVRFConsumer(consumers[id]).rawFulfillRandomWords(id, words);
    }

    function deliver(address consumer, uint256 id, uint256[] calldata words) external {
        IVRFConsumer(consumer).rawFulfillRandomWords(id, words);
    }

    function fulfillWithGas(uint256 id, uint256 word, uint256 gasLimit) external returns (bool ok) {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        (ok,) = consumers[id].call{gas: gasLimit}(abi.encodeCall(IVRFConsumer.rawFulfillRandomWords, (id, words)));
    }
}
