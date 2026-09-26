// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IMDToken} from "../src/IMDToken.sol";

contract IMDTokenTest is Test {
    IMDToken private token;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);

    function setUp() public {
        token = new IMDToken();
    }

    function testFixedSupplyAndMetadata() public view {
        assertEq(token.name(), "IdentityMD");
        assertEq(token.symbol(), "IMD");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function testFuzzTransfersConserveSupply(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(address(this)), 1e27 - amount);
        vm.prank(ALICE);
        token.transfer(ALICE, amount);
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.totalSupply(), 1e27);
    }

    function testAllowanceAndInfiniteApproval() public {
        token.transfer(ALICE, 100 ether);
        vm.prank(ALICE);
        token.approve(BOB, 30 ether);
        vm.prank(BOB);
        token.transferFrom(ALICE, BOB, 20 ether);
        assertEq(token.allowance(ALICE, BOB), 10 ether);
        assertEq(token.balanceOf(BOB), 20 ether);
        vm.prank(ALICE);
        token.approve(BOB, type(uint256).max);
        vm.prank(BOB);
        token.transferFrom(ALICE, BOB, 80 ether);
        assertEq(token.allowance(ALICE, BOB), type(uint256).max);
    }

    function testInvalidTransfersAndUnauthorizedSpending() public {
        vm.expectPartialRevert(IERC20Errors.ERC20InvalidReceiver.selector);
        token.transfer(address(0), 1);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientBalance.selector);
        vm.prank(ALICE);
        token.transfer(BOB, 1);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientAllowance.selector);
        vm.prank(BOB);
        token.transferFrom(address(this), BOB, 1);
        assertEq(token.totalSupply(), 1e27);
    }

    function testNoAdministrativeSelectorsForAnyone() public {
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, 1e27);
            (bool ok,) = address(token).call(data);
            assertFalse(ok);
            vm.prank(ALICE);
            (ok,) = address(token).call(data);
            assertFalse(ok);
        }
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(ALICE), 0);
    }
}
