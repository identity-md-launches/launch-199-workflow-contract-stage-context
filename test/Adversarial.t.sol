// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {CoinFlip} from "../src/CoinFlip.sol";
import {MockCoordinator} from "./mocks/MockCoordinator.sol";
import {AdversarialToken} from "./mocks/AdversarialToken.sol";

contract AdversarialTest is Test {
    AdversarialToken private token;
    MockCoordinator private coordinator;
    CoinFlip private game;
    address private constant ALICE = address(0xA11CE);

    function setUp() public {
        token = new AdversarialToken();
        coordinator = new MockCoordinator();
        game = new CoinFlip(
            address(token),
            address(this),
            address(coordinator),
            7,
            bytes32(uint256(42)),
            3,
            100_000,
            1 ether,
            1000 ether
        );
        token.approve(address(game), type(uint256).max);
        game.fundBankroll(1000 ether);
        token.transfer(ALICE, 1000 ether);
        vm.prank(ALICE);
        token.approve(address(game), type(uint256).max);
    }

    function _flip() private returns (uint256 id) {
        vm.prank(ALICE);
        return game.flip(100 ether, true);
    }

    function testTokenFailureCannotBreakCallbackOrSettlementAndWithdrawalIsRetryable() public {
        uint256 id = _flip();
        token.setFailure(true);
        assertTrue(coordinator.fulfillWithGas(id, 1, 100_000));
        game.settle(id);
        assertEq(game.credits(ALICE), 200 ether);
        assertEq(game.totalCredits(), 200 ether);
        vm.expectPartialRevert(SafeERC20.SafeERC20FailedOperation.selector);
        vm.prank(ALICE);
        game.withdrawWinnings(ALICE, 200 ether);
        assertEq(game.credits(ALICE), 200 ether);
        assertEq(game.totalCredits(), 200 ether);
        token.setFailure(false);
        vm.prank(ALICE);
        game.withdrawWinnings(ALICE, 200 ether);
        assertEq(token.balanceOf(ALICE), 1099 ether);
    }

    function testRewardTransferFailureRestoresAccrualAndReserve() public {
        _flip();
        token.setFailure(true);
        uint256 indexPaid = game.rewardIndexPaid(ALICE);
        vm.expectPartialRevert(SafeERC20.SafeERC20FailedOperation.selector);
        vm.prank(ALICE);
        game.claimRewards(ALICE);
        assertEq(game.rewardReserve(), 1 ether);
        assertEq(game.pendingRewards(ALICE), 1 ether);
        assertEq(game.rewardIndexPaid(ALICE), indexPaid);
        token.setFailure(false);
        vm.prank(ALICE);
        assertEq(game.claimRewards(ALICE), 1 ether);
        assertEq(game.rewardReserve(), 0);
    }

    function testEntryAndBankrollTransferFailuresDoNotChangeBalances() public {
        token.setFailure(true);
        vm.expectPartialRevert(SafeERC20.SafeERC20FailedOperation.selector);
        vm.prank(ALICE);
        game.flip(100 ether, true);
        assertEq(game.totalRewardShares(), 0);
        assertEq(game.reservedPayouts(), 0);
        vm.expectPartialRevert(SafeERC20.SafeERC20FailedOperation.selector);
        game.withdrawBankroll(address(this), 10 ether);
        assertEq(game.availableBankroll(), 1000 ether);
        vm.expectPartialRevert(SafeERC20.SafeERC20FailedOperation.selector);
        game.fundBankroll(10 ether);
        assertEq(game.availableBankroll(), 1000 ether);
    }

    function testTaxedIncomingTokensAreRejectedWithoutAccountingChanges() public {
        token.setTaxed(true);
        vm.expectRevert(CoinFlip.UnsupportedToken.selector);
        vm.prank(ALICE);
        game.flip(100 ether, true);
        assertEq(token.balanceOf(ALICE), 1000 ether);
        assertEq(game.totalRewardShares(), 0);
        vm.expectRevert(CoinFlip.UnsupportedToken.selector);
        game.fundBankroll(10 ether);
        assertEq(game.availableBankroll(), 1000 ether);
    }

    function testTransferFromReentryCannotCreateAnotherBet() public {
        token.setReentry(address(game), abi.encodeCall(game.flip, (100 ether, false)));
        uint256 id = _flip();
        assertFalse(token.reentrySucceeded());
        assertEq(token.reentryResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(id, 1);
        assertEq(game.reservedPayouts(), 200 ether);
        assertEq(game.totalRewardShares(), 100 ether);
    }

    function testOutgoingTransferReentryCannotSpendCreditTwice() public {
        uint256 id = _flip();
        coordinator.fulfill(id, 1);
        game.settle(id);
        token.setReentry(address(game), abi.encodeCall(game.withdrawWinnings, (ALICE, 200 ether)));
        vm.prank(ALICE);
        game.withdrawWinnings(ALICE, 200 ether);
        assertFalse(token.reentrySucceeded());
        assertEq(token.reentryResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(game.totalCredits(), 0);
        assertEq(token.balanceOf(ALICE), 1099 ether);
    }

    function testRewardTransferReentryCannotSpendReserveTwice() public {
        _flip();
        token.setReentry(address(game), abi.encodeCall(game.claimRewards, (ALICE)));
        vm.prank(ALICE);
        game.claimRewards(ALICE);
        assertFalse(token.reentrySucceeded());
        assertEq(token.reentryResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(game.rewardReserve(), 0);
    }

    function testCoordinatorReentryAndSynchronousCallbackAreRejected() public {
        coordinator.setReentry(address(game), abi.encodeCall(game.flip, (100 ether, false)));
        _flip();
        assertFalse(coordinator.reentrySucceeded());
        assertEq(
            coordinator.reentryResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        uint256[] memory words = new uint256[](1);
        words[0] = 1;
        coordinator.setReentry(address(game), abi.encodeCall(game.rawFulfillRandomWords, (2, words)));
        uint256 id = _flip();
        assertFalse(coordinator.reentrySucceeded());
        assertEq(
            coordinator.reentryResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        (,,, CoinFlip.State state,) = game.bets(id);
        assertEq(uint256(state), uint256(CoinFlip.State.Pending));
        coordinator.fulfill(id, 1);
        game.settle(id);
        assertEq(game.credits(ALICE), 200 ether);
    }
}
