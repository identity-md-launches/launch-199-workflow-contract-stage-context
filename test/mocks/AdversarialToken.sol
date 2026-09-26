// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Test-only transfer failure, tax and reentry hooks. Never deploy as the launch token.
contract AdversarialToken is ERC20 {
    bool public failTransfers;
    bool public taxed;
    address public target;
    bytes public callData;
    bool public reentrySucceeded;
    bytes public reentryResult;

    constructor() ERC20("Adversarial", "BAD") {
        _mint(msg.sender, 1_000_000_000 ether);
    }

    function setFailure(bool fail) external {
        failTransfers = fail;
    }

    function setTaxed(bool tax) external {
        taxed = tax;
    }

    function setReentry(address target_, bytes calldata data) external {
        target = target_;
        callData = data;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (failTransfers) return false;
        _hook();
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (failTransfers) return false;
        _hook();
        bool ok = super.transferFrom(from, to, amount);
        if (taxed && amount != 0) _transfer(to, address(0xDEAD), 1);
        return ok;
    }

    function _hook() private {
        if (target != address(0)) {
            (reentrySucceeded, reentryResult) = target.call(callData);
        }
    }
}
