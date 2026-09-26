// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IMDToken} from "../src/IMDToken.sol";
import {CoinFlip} from "../src/CoinFlip.sol";
import {MockCoordinator} from "./mocks/MockCoordinator.sol";

contract AccountingHandler is Test {
    IMDToken public immutable token;
    CoinFlip public immutable game;
    MockCoordinator public immutable coordinator;
    address[3] public players = [address(0xA11CE), address(0xB0B), address(0xCA)];
    uint256[] private ids;
    uint256 public feesPaid;
    uint256 public rewardsClaimed;
    uint256 public payoutsEarned;
    uint256 public payoutsWithdrawn;
    uint256 public successfulPlays;
    uint256 public successfulSettlements;

    constructor(IMDToken token_) {
        token = token_;
        coordinator = new MockCoordinator();
        game = new CoinFlip(
            address(token_), address(this), address(coordinator), 7, bytes32(uint256(42)), 3, 100_000, 100, 1000 ether
        );
        token.approve(address(game), type(uint256).max);
        for (uint256 i; i < players.length; ++i) {
            vm.prank(players[i]);
            token.approve(address(game), type(uint256).max);
        }
    }

    function requestCount() external view returns (uint256) {
        return ids.length;
    }

    function requestAt(uint256 index) external view returns (uint256) {
        return ids[index];
    }

    function play(uint256 actorSeed, uint256 amountSeed, bool heads) external {
        if (game.paused()) return;
        address player = players[actorSeed % players.length];
        uint256 limit = token.balanceOf(player) / 101 * 100;
        uint256 bankroll = game.availableBankroll();
        if (limit > bankroll) limit = bankroll;
        if (limit > 1000 ether) limit = 1000 ether;
        if (limit < 100) return;
        uint256 stake = bound(amountSeed, 100, limit);
        vm.prank(player);
        ids.push(game.flip(stake, heads));
        feesPaid += stake / 100;
        successfulPlays++;
    }

    function fulfill(uint256 requestSeed, uint256 word) external {
        if (ids.length == 0) return;
        // Deliberately includes duplicate callbacks after readiness or settlement.
        coordinator.fulfill(ids[requestSeed % ids.length], word);
    }

    function settle(uint256 requestSeed) external {
        if (ids.length == 0) return;
        uint256 id = ids[requestSeed % ids.length];
        (, bool heads, bool resultHeads, CoinFlip.State state, uint256 stake) = game.bets(id);
        if (state != CoinFlip.State.Ready) return;
        game.settle(id);
        if (heads == resultHeads) payoutsEarned += stake * 2;
        successfulSettlements++;
    }

    function withdraw(uint256 actorSeed, uint256 amountSeed) external {
        address player = players[actorSeed % players.length];
        uint256 credit = game.credits(player);
        if (credit == 0) return;
        uint256 amount = bound(amountSeed, 1, credit);
        vm.prank(player);
        game.withdrawWinnings(player, amount);
        payoutsWithdrawn += amount;
    }

    function claim(uint256 actorSeed) external {
        address player = players[actorSeed % players.length];
        uint256 amount = game.pendingRewards(player);
        if (amount == 0) return;
        vm.prank(player);
        assertEq(game.claimRewards(player), amount);
        rewardsClaimed += amount;
    }

    function withdrawBankroll(uint256 amountSeed) external {
        uint256 available = game.availableBankroll();
        if (available == 0) return;
        game.withdrawBankroll(address(this), bound(amountSeed, 1, available));
    }

    function fund(uint256 amountSeed) external {
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) return;
        game.fundBankroll(bound(amountSeed, 1, balance));
    }

    function pause(bool value) external {
        game.setPaused(value);
    }
}

contract AccountingInvariantTest is StdInvariant, Test {
    IMDToken private token;
    CoinFlip private game;
    AccountingHandler private handler;

    function setUp() public {
        token = new IMDToken();
        handler = new AccountingHandler(token);
        game = handler.game();
        token.transfer(address(game), 10_000 ether);
        token.transfer(address(handler), 10_000 ether);
        for (uint256 i; i < 3; ++i) {
            token.transfer(handler.players(i), 10_000 ether);
        }
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.play.selector;
        selectors[1] = handler.fulfill.selector;
        selectors[2] = handler.settle.selector;
        selectors[3] = handler.withdraw.selector;
        selectors[4] = handler.claim.selector;
        selectors[5] = handler.withdrawBankroll.selector;
        selectors[6] = handler.fund.selector;
        selectors[7] = handler.pause.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariantAllLiabilitiesAreCoveredAndFeesNeverBecomeOwnerCapital() public view {
        uint256 pending;
        uint256 cumulativeVolume;
        for (uint256 i; i < handler.requestCount(); ++i) {
            (,,, CoinFlip.State state, uint256 stake) = game.bets(handler.requestAt(i));
            if (state == CoinFlip.State.Pending || state == CoinFlip.State.Ready) pending += stake * 2;
            cumulativeVolume += stake;
        }
        assertEq(game.reservedPayouts(), pending);
        assertEq(game.totalRewardShares(), cumulativeVolume);
        uint256 credits;
        uint256 rewards;
        for (uint256 i; i < 3; ++i) {
            address player = handler.players(i);
            credits += game.credits(player);
            rewards += game.pendingRewards(player);
        }
        assertEq(game.totalCredits(), credits);
        assertEq(handler.payoutsEarned(), handler.payoutsWithdrawn() + credits);
        assertEq(handler.feesPaid(), handler.rewardsClaimed() + game.rewardReserve());
        assertLe(rewards, game.rewardReserve());
        assertGe(token.balanceOf(address(game)), pending + credits + game.rewardReserve());
        assertEq(token.balanceOf(address(game)), game.availableBankroll() + pending + credits + game.rewardReserve());
    }

    function invariantEveryTokenIsAccountedFor() public view {
        uint256 balances =
            token.balanceOf(address(this)) + token.balanceOf(address(game)) + token.balanceOf(address(handler));
        for (uint256 i; i < 3; ++i) {
            balances += token.balanceOf(handler.players(i));
        }
        assertEq(balances, 1e27);
        assertEq(token.totalSupply(), 1e27);
    }

    /// @dev Deterministic trace prevents a vacuous handler from appearing covered by random runs.
    function testHandlerExercisesFullLifecycleAndBothOutcomes() public {
        handler.play(0, 100 ether, true);
        handler.play(1, 300 ether, false);
        handler.fulfill(0, 1);
        handler.fulfill(1, 1);
        handler.settle(0);
        handler.settle(1);
        handler.withdraw(0, 200 ether);
        handler.claim(0);
        handler.withdrawBankroll(10 ether);
        handler.fund(10 ether);
        handler.pause(true);
        assertEq(handler.successfulPlays(), 2);
        assertEq(handler.successfulSettlements(), 2);
        assertGt(handler.payoutsWithdrawn(), 0);
        assertGt(handler.rewardsClaimed(), 0);
        invariantAllLiabilitiesAreCoveredAndFeesNeverBecomeOwnerCapital();
        invariantEveryTokenIsAccountedFor();
    }
}
