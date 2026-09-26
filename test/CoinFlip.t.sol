// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IMDToken} from "../src/IMDToken.sol";
import {CoinFlip} from "../src/CoinFlip.sol";
import {IVRFCoordinator} from "../src/interfaces/IVRFCoordinator.sol";
import {MockCoordinator} from "./mocks/MockCoordinator.sol";

contract CoinFlipTest is Test {
    IMDToken private token;
    CoinFlip private game;
    MockCoordinator private coordinator;
    address private constant OWNER = address(0xAA);
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant CAROL = address(0xCA);
    uint256 private constant BANKROLL = 10_000 ether;

    function setUp() public {
        token = new IMDToken();
        coordinator = new MockCoordinator();
        game = new CoinFlip(
            address(token), OWNER, address(coordinator), 7, bytes32(uint256(42)), 3, 100_000, 1 ether, 1000 ether
        );
        token.approve(address(game), type(uint256).max);
        game.fundBankroll(BANKROLL);
        address[3] memory players = [ALICE, BOB, CAROL];
        for (uint256 i; i < players.length; ++i) {
            token.transfer(players[i], 10_000 ether);
            vm.prank(players[i]);
            token.approve(address(game), type(uint256).max);
        }
    }

    function _flip(address player, uint256 stake, bool heads) private returns (uint256) {
        vm.prank(player);
        return game.flip(stake, heads);
    }

    function _state(uint256 id) private view returns (CoinFlip.State state) {
        (,,, state,) = game.bets(id);
    }

    function _checkAccounting() private view {
        assertEq(
            token.balanceOf(address(game)),
            game.availableBankroll() + game.reservedPayouts() + game.totalCredits() + game.rewardReserve()
        );
        assertEq(token.totalSupply(), 1e27);
    }

    function testWinPaysExactlyDoubleAndKeepsFeeSeparate() public {
        uint256 id = _flip(ALICE, 100 ether, true);
        assertEq(token.balanceOf(ALICE), 9899 ether);
        assertEq(game.reservedPayouts(), 200 ether);
        assertEq(game.availableBankroll(), BANKROLL - 100 ether);
        coordinator.fulfill(id, 1);
        assertEq(uint256(_state(id)), uint256(CoinFlip.State.Ready));
        assertEq(game.credits(ALICE), 0);
        vm.prank(BOB);
        game.settle(id);
        assertEq(game.credits(ALICE), 200 ether);
        assertEq(game.credits(BOB), 0);
        vm.prank(ALICE);
        game.withdrawWinnings(ALICE, 75 ether);
        vm.prank(ALICE);
        game.withdrawWinnings(CAROL, 125 ether);
        assertEq(token.balanceOf(CAROL), 10_125 ether);
        assertEq(game.credits(ALICE), 0);
        assertEq(game.pendingRewards(ALICE), 1 ether);
        vm.prank(ALICE);
        game.claimRewards(ALICE);
        assertEq(game.rewardReserve(), 0);
        _checkAccounting();
    }

    function testLossTransfersStakeToBankroll() public {
        uint256 id = _flip(ALICE, 100 ether, true);
        coordinator.fulfill(id, 0);
        game.settle(id);
        assertEq(game.credits(ALICE), 0);
        assertEq(game.reservedPayouts(), 0);
        assertEq(game.availableBankroll(), BANKROLL + 100 ether);
        assertEq(token.balanceOf(ALICE), 9899 ether);
        _checkAccounting();
    }

    function testFuzzParityHasExactPayout(uint256 word, bool heads, uint256 stake) public {
        stake = bound(stake, 1 ether, 1000 ether);
        uint256 id = _flip(ALICE, stake, heads);
        coordinator.fulfill(id, word);
        game.settle(id);
        bool won = ((word & 1) == 1) == heads;
        assertEq(game.credits(ALICE), won ? 2 * stake : 0);
        assertEq(game.availableBankroll(), won ? BANKROLL - stake : BANKROLL + stake);
        _checkAccounting();
    }

    function testExactVRFRequestEncoding() public {
        _flip(ALICE, 100 ether, true);
        IVRFCoordinator.RandomWordsRequest memory request = coordinator.lastRequest();
        assertEq(request.keyHash, bytes32(uint256(42)));
        assertEq(request.subId, 7);
        assertEq(request.requestConfirmations, 3);
        assertEq(request.callbackGasLimit, 100_000);
        assertEq(request.numWords, 1);
        assertEq(request.extraArgs, abi.encodeWithSelector(bytes4(keccak256("VRF ExtraArgsV1")), true));
        // Chainlink's canonical v2.5 tuple selector, checked independently of the mock's interface.
        assertEq(
            IVRFCoordinator.requestRandomWords.selector,
            bytes4(keccak256("requestRandomWords((bytes32,uint256,uint16,uint32,uint32,bytes))"))
        );
    }

    function testConcurrentBetsCanResolveOutOfOrder() public {
        uint256 a = _flip(ALICE, 100 ether, true);
        uint256 b = _flip(BOB, 200 ether, false);
        uint256 c = _flip(ALICE, 300 ether, false);
        coordinator.fulfill(c, 0);
        coordinator.fulfill(a, 0);
        coordinator.fulfill(b, type(uint256).max);
        game.settle(b);
        game.settle(c);
        game.settle(a);
        assertEq(game.credits(ALICE), 600 ether);
        assertEq(game.credits(BOB), 0);
        assertEq(game.availableBankroll(), BANKROLL);
        assertEq(game.reservedPayouts(), 0);
        _checkAccounting();
    }

    function testPendingAndWinningLiabilitiesCannotBeWithdrawn() public {
        uint256 id = _flip(ALICE, 100 ether, true);
        vm.expectRevert(CoinFlip.InsufficientBankroll.selector);
        vm.prank(OWNER);
        game.withdrawBankroll(OWNER, BANKROLL - 100 ether + 1);
        vm.prank(OWNER);
        game.withdrawBankroll(OWNER, BANKROLL - 100 ether);
        vm.expectRevert(CoinFlip.InsufficientBankroll.selector);
        vm.prank(BOB);
        game.flip(1 ether, false);
        coordinator.fulfill(id, 1);
        game.settle(id);
        vm.expectRevert(CoinFlip.InsufficientBankroll.selector);
        vm.prank(OWNER);
        game.withdrawBankroll(OWNER, 1);
        vm.prank(ALICE);
        game.withdrawWinnings(ALICE, 200 ether);
        vm.prank(ALICE);
        game.claimRewards(ALICE);
        assertEq(token.balanceOf(address(game)), 0);
    }

    function testRejectsInvalidStakeAndUnauthorizedCalls() public {
        vm.startPrank(ALICE);
        vm.expectRevert(CoinFlip.InvalidStake.selector);
        game.flip(0, false);
        vm.expectRevert(CoinFlip.InvalidStake.selector);
        game.flip(1 ether - 1, false);
        vm.expectRevert(CoinFlip.InvalidStake.selector);
        game.flip(1000 ether + 1, false);
        vm.expectRevert(CoinFlip.Unauthorized.selector);
        game.setPaused(true);
        vm.expectRevert(CoinFlip.Unauthorized.selector);
        game.withdrawBankroll(ALICE, 1);
        uint256[] memory words = new uint256[](1);
        vm.expectRevert(CoinFlip.Unauthorized.selector);
        game.rawFulfillRandomWords(1, words);
        vm.stopPrank();
    }

    function testMissingAllowanceOrBalanceRollsBack() public {
        vm.prank(ALICE);
        token.approve(address(game), 0);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientAllowance.selector);
        vm.prank(ALICE);
        game.flip(100 ether, true);
        address empty = address(0x123);
        vm.prank(empty);
        token.approve(address(game), type(uint256).max);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientBalance.selector);
        vm.prank(empty);
        game.flip(100 ether, true);
        assertEq(game.reservedPayouts(), 0);
        assertEq(game.rewardReserve(), 0);
        assertEq(game.totalRewardShares(), 0);
        assertEq(coordinator.nextId(), 1);
    }

    function testRequestFailureAtomicallyRestoresFundsAndShares() public {
        coordinator.setRejectRequests(true);
        vm.expectRevert("subscription unavailable");
        vm.prank(ALICE);
        game.flip(100 ether, true);
        assertEq(token.balanceOf(ALICE), 10_000 ether);
        assertEq(game.reservedPayouts(), 0);
        assertEq(game.rewardReserve(), 0);
        assertEq(game.totalRewardShares(), 0);
        assertEq(game.rewardPerShare(), 0);
        _checkAccounting();
    }

    function testInvalidAndReusedRequestIdsRevertEntireEntry() public {
        coordinator.setNextId(0);
        vm.expectRevert(CoinFlip.InvalidRequestId.selector);
        vm.prank(ALICE);
        game.flip(100 ether, true);
        coordinator.setNextId(1);
        uint256 id = _flip(ALICE, 100 ether, true);
        coordinator.setNextId(id);
        vm.expectRevert(CoinFlip.InvalidRequestId.selector);
        vm.prank(BOB);
        game.flip(200 ether, false);
        assertEq(game.reservedPayouts(), 200 ether);
        assertEq(token.balanceOf(BOB), 10_000 ether);
        (address player, bool heads,,, uint256 stake) = game.bets(id);
        assertEq(player, ALICE);
        assertTrue(heads);
        assertEq(stake, 100 ether);
    }

    function testUnknownMalformedAndDuplicateCallbacksCannotChangeOutcome() public {
        uint256 id = _flip(ALICE, 100 ether, true);
        uint256[] memory empty = new uint256[](0);
        coordinator.deliver(address(game), id, empty);
        assertEq(uint256(_state(id)), uint256(CoinFlip.State.Pending));
        uint256[] memory tooMany = new uint256[](2);
        coordinator.deliver(address(game), id, tooMany);
        coordinator.deliver(address(game), 999, empty);
        assertEq(uint256(_state(999)), uint256(CoinFlip.State.None));
        coordinator.fulfill(id, 1);
        coordinator.fulfill(id, 0);
        game.settle(id);
        coordinator.fulfill(id, 0);
        assertEq(game.credits(ALICE), 200 ether);
        vm.expectRevert(CoinFlip.BetNotReady.selector);
        game.settle(id);
        assertEq(game.credits(ALICE), 200 ether);
    }

    function testOnlyReadyBetsSettleAndInputsStayCommitted() public {
        vm.expectRevert(CoinFlip.BetNotReady.selector);
        game.settle(999);
        uint256 id = _flip(ALICE, 100 ether, false);
        vm.expectRevert(CoinFlip.BetNotReady.selector);
        game.settle(id);
        coordinator.fulfill(id, 0);
        // A later entry gets an independent ID and cannot change a revealed bet.
        uint256 second = _flip(ALICE, 200 ether, true);
        assertTrue(second != id);
        (address player, bool heads,,, uint256 stake) = game.bets(id);
        assertEq(player, ALICE);
        assertFalse(heads);
        assertEq(stake, 100 ether);
        game.settle(id);
        assertEq(game.credits(ALICE), 200 ether);
    }

    function testDelayedFulfillmentWorksWhilePausedWithoutRefundOrReroll() public {
        uint256 id = _flip(ALICE, 100 ether, true);
        vm.warp(block.timestamp + 365 days);
        vm.roll(block.number + 1_000_000);
        vm.prank(OWNER);
        game.setPaused(true);
        vm.expectRevert(CoinFlip.GamePaused.selector);
        vm.prank(BOB);
        game.flip(100 ether, false);
        (bool ok,) = address(game).call(abi.encodeWithSignature("refund(uint256)", id));
        assertFalse(ok);
        (ok,) = address(game).call(abi.encodeWithSignature("cancel(uint256)", id));
        assertFalse(ok);
        assertEq(game.reservedPayouts(), 200 ether);
        coordinator.fulfill(id, 1);
        game.settle(id);
        vm.prank(ALICE);
        game.withdrawWinnings(ALICE, 200 ether);
        vm.prank(ALICE);
        game.claimRewards(ALICE);
        vm.prank(OWNER);
        game.setPaused(false);
        _flip(BOB, 1 ether, false);
        _checkAccounting();
    }

    function testCallbackFitsMinimumConfiguredGas() public {
        uint256 id = _flip(ALICE, 100 ether, true);
        assertTrue(coordinator.fulfillWithGas(id, 1, 100_000));
        game.settle(id);
        assertEq(game.credits(ALICE), 200 ether);
    }

    function testCallbackOutOfGasLeavesReservationAndNoInventedResult() public {
        uint256 id = _flip(ALICE, 100 ether, true);
        assertFalse(coordinator.fulfillWithGas(id, 1, 500));
        assertEq(uint256(_state(id)), uint256(CoinFlip.State.Pending));
        assertEq(game.reservedPayouts(), 200 ether);
        vm.expectRevert(CoinFlip.BetNotReady.selector);
        game.settle(id);
    }

    function testFeesRewardPriorVolumeAndNoRetroactiveCapture() public {
        _flip(ALICE, 100 ether, true); // Alice receives bootstrap fee: 1.
        _flip(BOB, 100 ether, true); // Alice receives 1, Bob has no prior shares.
        assertEq(game.pendingRewards(ALICE), 2 ether);
        assertEq(game.pendingRewards(BOB), 0);
        _flip(CAROL, 100 ether, true); // Alice and Bob receive 0.5 each.
        assertEq(game.pendingRewards(ALICE), 2.5 ether);
        assertEq(game.pendingRewards(BOB), 0.5 ether);
        assertEq(game.pendingRewards(CAROL), 0);
        assertEq(game.rewardReserve(), 3 ether);
        vm.prank(ALICE);
        game.claimRewards(ALICE);
        vm.prank(BOB);
        game.claimRewards(BOB);
        assertEq(game.rewardReserve(), 0);
        vm.expectRevert(CoinFlip.InvalidAmount.selector);
        vm.prank(ALICE);
        game.claimRewards(ALICE);
        _checkAccounting();
    }

    function testRepeatPlayAccruesOldSharesBeforeAddingNewShares() public {
        _flip(ALICE, 100 ether, true);
        _flip(BOB, 100 ether, true);
        _flip(ALICE, 200 ether, false);
        assertEq(game.pendingRewards(ALICE), 3 ether);
        assertEq(game.pendingRewards(BOB), 1 ether);
        assertEq(game.rewardShares(ALICE), 300 ether);
        _flip(CAROL, 400 ether, true);
        assertEq(game.pendingRewards(ALICE), 6 ether);
        assertEq(game.pendingRewards(BOB), 2 ether);
        assertEq(game.pendingRewards(CAROL), 0);
        _checkAccounting();
    }

    function testRewardsRoundDownAndDustRemainsReserved() public {
        uint256 stake = 1 ether + 37;
        _flip(ALICE, stake, true);
        _flip(BOB, stake + 101, true);
        _flip(CAROL, stake + 203, true);
        uint256 owed = game.pendingRewards(ALICE) + game.pendingRewards(BOB) + game.pendingRewards(CAROL);
        assertLe(owed, game.rewardReserve());
        vm.prank(ALICE);
        game.claimRewards(ALICE);
        vm.prank(BOB);
        game.claimRewards(BOB);
        assertGt(game.rewardReserve(), 0);
        uint256 available = game.availableBankroll();
        vm.prank(OWNER);
        game.withdrawBankroll(OWNER, available);
        assertEq(game.availableBankroll(), 0);
        _checkAccounting();
    }

    function testNoStealingCreditsOrInvalidRecipients() public {
        uint256 id = _flip(ALICE, 100 ether, true);
        coordinator.fulfill(id, 1);
        game.settle(id);
        vm.expectRevert(CoinFlip.InvalidAmount.selector);
        vm.prank(BOB);
        game.withdrawWinnings(BOB, 1);
        vm.startPrank(ALICE);
        vm.expectRevert(CoinFlip.InvalidRecipient.selector);
        game.withdrawWinnings(address(0), 1);
        vm.expectRevert(CoinFlip.InvalidRecipient.selector);
        game.claimRewards(address(game));
        vm.expectRevert(CoinFlip.InvalidAmount.selector);
        game.withdrawWinnings(ALICE, 201 ether);
        vm.expectRevert(CoinFlip.InvalidAmount.selector);
        game.withdrawWinnings(ALICE, 0);
        vm.stopPrank();
        assertEq(game.credits(ALICE), 200 ether);
    }

    function testFundingDonationAndZeroAmounts() public {
        vm.expectRevert(CoinFlip.InvalidAmount.selector);
        game.fundBankroll(0);
        token.transfer(address(game), 12 ether);
        assertEq(game.availableBankroll(), BANKROLL + 12 ether);
        vm.prank(ALICE);
        game.fundBankroll(10 ether);
        assertEq(game.availableBankroll(), BANKROLL + 22 ether);
        vm.expectRevert(CoinFlip.InvalidAmount.selector);
        vm.prank(OWNER);
        game.withdrawBankroll(OWNER, 0);
        vm.expectRevert(CoinFlip.InvalidRecipient.selector);
        vm.prank(OWNER);
        game.withdrawBankroll(address(game), 1);
    }
}
