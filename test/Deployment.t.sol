// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDToken} from "../src/IMDToken.sol";
import {CoinFlip} from "../src/CoinFlip.sol";

contract FactoryProbe {
    function deploy(bytes memory initCode, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(initCode, 32), mload(initCode), salt)
        }
        require(deployed != address(0), "deployment failed");
    }
}

contract DeploymentTest is Test {
    struct Config {
        address token;
        address owner;
        address coordinator;
        uint256 subId;
        bytes32 keyHash;
        uint16 confirmations;
        uint32 gasLimit;
        uint256 minimum;
        uint256 maximum;
    }

    function _valid() private pure returns (Config memory) {
        return Config(address(1), address(2), address(3), 1, bytes32(uint256(1)), 3, 100_000, 100, 1000 ether);
    }

    function _bad(Config memory c) private {
        vm.expectRevert(CoinFlip.InvalidConfiguration.selector);
        new CoinFlip(
            c.token, c.owner, c.coordinator, c.subId, c.keyHash, c.confirmations, c.gasLimit, c.minimum, c.maximum
        );
    }

    function testRejectsInvalidConstructorConfiguration() public {
        Config memory c = _valid();
        c.token = address(0);
        _bad(c);
        c = _valid();
        c.owner = address(0);
        _bad(c);
        c = _valid();
        c.coordinator = address(0);
        _bad(c);
        c = _valid();
        c.subId = 0;
        _bad(c);
        c = _valid();
        c.keyHash = 0;
        _bad(c);
        c = _valid();
        c.confirmations = 2;
        _bad(c);
        c.confirmations = 201;
        _bad(c);
        c = _valid();
        c.gasLimit = 99_999;
        _bad(c);
        c.gasLimit = 2_500_001;
        _bad(c);
        c = _valid();
        c.minimum = 99;
        _bad(c);
        c = _valid();
        c.maximum = c.minimum - 1;
        _bad(c);
        c = _valid();
        c.maximum = 1e27 / 2 + 1;
        _bad(c);
    }

    function testFactoryDeploymentPreservesSupplyAndExplicitOwner() public {
        FactoryProbe factory = new FactoryProbe();
        address owner = address(0xBEEF);
        IMDToken token = IMDToken(factory.deploy(type(IMDToken).creationCode, bytes32(uint256(1))));
        bytes memory initCode = abi.encodePacked(
            type(CoinFlip).creationCode,
            abi.encode(
                address(token),
                owner,
                address(0xCAFE),
                uint256(1),
                bytes32(uint256(42)),
                uint16(3),
                uint32(200_000),
                uint256(1 ether),
                uint256(1000 ether)
            )
        );
        CoinFlip game = CoinFlip(factory.deploy(initCode, bytes32(uint256(2))));
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(factory)), 1e27);
        assertEq(token.balanceOf(address(game)), 0);
        assertEq(game.owner(), owner);
        assertEq(address(game.token()), address(token));
        vm.prank(owner);
        game.setPaused(true);
        vm.expectRevert(CoinFlip.Unauthorized.selector);
        vm.prank(address(factory));
        game.setPaused(false);
        _checkRuntime(address(token));
        _checkRuntime(address(game));
    }

    function _checkRuntime(address deployed) private view {
        bytes memory code = deployed.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
            } else {
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
            }
        }
    }
}
