// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IVRFCoordinator} from "./interfaces/IVRFCoordinator.sol";

/// @notice Fully collateralized, single-player IMD coin flips using Chainlink VRF v2.5.
/// @dev The token MUST be the immutable fixed-supply IMDToken. See README for oracle liveness risks.
contract CoinFlip is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum State {
        None,
        Pending,
        Ready,
        Settled
    }

    struct Bet {
        address player;
        bool heads;
        bool resultHeads;
        State state;
        uint256 stake;
    }

    error InvalidConfiguration();
    error Unauthorized();
    error GamePaused();
    error InvalidStake();
    error InsufficientBankroll();
    error InvalidAmount();
    error InvalidRecipient();
    error InvalidRequestId();
    error BetNotReady();
    error UnsupportedToken();

    event BankrollFunded(address indexed funder, uint256 amount);
    event BankrollWithdrawn(address indexed recipient, uint256 amount);
    event PauseChanged(bool paused);
    event FlipRequested(uint256 indexed requestId, address indexed player, uint256 stake, uint256 fee, bool heads);
    event RandomnessReceived(uint256 indexed requestId, bool resultHeads);
    event CallbackIgnored(uint256 indexed requestId);
    event FlipSettled(uint256 indexed requestId, address indexed player, bool won, uint256 payout);
    event WinningsWithdrawn(address indexed player, address indexed recipient, uint256 amount);
    event RewardsClaimed(address indexed player, address indexed recipient, uint256 amount);

    uint256 public constant FEE_BPS = 100;
    uint256 public constant REWARD_SCALE = 1e27;
    uint256 private constant TOKEN_SUPPLY = 1_000_000_000 ether;
    // The four-byte truncation is the coordinator's specified ABI tag.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes4 private constant EXTRA_ARGS_V1_TAG = bytes4(keccak256("VRF ExtraArgsV1"));

    IERC20 public immutable token;
    address public immutable owner;
    IVRFCoordinator public immutable coordinator;
    uint256 public immutable subscriptionId;
    bytes32 public immutable keyHash;
    uint16 public immutable requestConfirmations;
    uint32 public immutable callbackGasLimit;
    uint256 public immutable minStake;
    uint256 public immutable maxStake;

    bool public paused;
    uint256 public reservedPayouts;
    uint256 public totalCredits;
    uint256 public rewardReserve;
    uint256 public totalRewardShares;
    uint256 public rewardPerShare;

    mapping(uint256 => Bet) public bets;
    mapping(address => uint256) public credits;
    mapping(address => uint256) public rewardShares;
    mapping(address => uint256) public storedRewards;
    mapping(address => uint256) public rewardIndexPaid;

    /// @dev Nonpayable, static arguments only; no transfers, oracle calls, or initialization call required.
    ///      Subscription billing is fixed to native ETH, paid by the external subscription.
    constructor(
        address token_,
        address owner_,
        address coordinator_,
        uint256 subscriptionId_,
        bytes32 keyHash_,
        uint16 requestConfirmations_,
        uint32 callbackGasLimit_,
        uint256 minStake_,
        uint256 maxStake_
    ) {
        if (
            token_ == address(0) || owner_ == address(0) || coordinator_ == address(0) || subscriptionId_ == 0
                || keyHash_ == bytes32(0) || requestConfirmations_ < 3 || requestConfirmations_ > 200
                || callbackGasLimit_ < 100_000 || callbackGasLimit_ > 2_500_000 || minStake_ < 100
                || maxStake_ < minStake_ || maxStake_ > TOKEN_SUPPLY / 2
        ) revert InvalidConfiguration();
        token = IERC20(token_);
        owner = owner_;
        coordinator = IVRFCoordinator(coordinator_);
        subscriptionId = subscriptionId_;
        keyHash = keyHash_;
        requestConfirmations = requestConfirmations_;
        callbackGasLimit = callbackGasLimit_;
        minStake = minStake_;
        maxStake = maxStake_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    /// @notice Tokens available to back new bets or for the owner to withdraw.
    function availableBankroll() public view returns (uint256) {
        return token.balanceOf(address(this)) - reservedPayouts - totalCredits - rewardReserve;
    }

    function quoteFee(uint256 stake) public pure returns (uint256) {
        return stake / 100;
    }

    /// @notice A donation to the owner's risk capital, not an LP deposit or a refundable loan.
    function fundBankroll(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        _receiveTokens(msg.sender, amount);
        emit BankrollFunded(msg.sender, amount);
    }

    function withdrawBankroll(address recipient, uint256 amount) external nonReentrant onlyOwner {
        _checkRecipient(recipient);
        if (amount == 0) revert InvalidAmount();
        if (amount > availableBankroll()) revert InsufficientBankroll();
        token.safeTransfer(recipient, amount);
        emit BankrollWithdrawn(recipient, amount);
    }

    /// @notice Pausing only stops entry. Results, settlement, withdrawals and rewards remain available.
    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PauseChanged(paused_);
    }

    /// @notice Debit stake + fee and commit a new independent bet; true selects heads.
    /// @return requestId The immutable identifier used by VRF, the frontend and permissionless settlement.
    function flip(uint256 stake, bool heads) external nonReentrant returns (uint256 requestId) {
        if (paused) revert GamePaused();
        if (stake < minStake || stake > maxStake) revert InvalidStake();
        if (availableBankroll() < stake) revert InsufficientBankroll();
        uint256 fee = quoteFee(stake);
        _receiveTokens(msg.sender, stake + fee);
        reservedPayouts += stake * 2;
        _allocateRewards(msg.sender, stake, fee);

        // The trusted coordinator responds asynchronously. No user input can change this request.
        requestId = coordinator.requestRandomWords(
            IVRFCoordinator.RandomWordsRequest({
                keyHash: keyHash,
                subId: subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: 1,
                extraArgs: abi.encodeWithSelector(EXTRA_ARGS_V1_TAG, true)
            })
        );
        if (requestId == 0 || bets[requestId].state != State.None) revert InvalidRequestId();
        bets[requestId] = Bet(msg.sender, heads, false, State.Pending, stake);
        emit FlipRequested(requestId, msg.sender, stake, fee, heads);
    }

    /// @notice Oracle callback: authenticates and stores one bit, without transfers or user callbacks.
    /// @dev Duplicate, unknown and malformed callbacks cannot alter an existing outcome.
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata words) external nonReentrant {
        if (msg.sender != address(coordinator)) revert Unauthorized();
        Bet storage bet = bets[requestId];
        if (bet.state != State.Pending || words.length != 1) {
            emit CallbackIgnored(requestId);
            return;
        }
        bet.resultHeads = (words[0] & 1) == 1;
        bet.state = State.Ready;
        emit RandomnessReceived(requestId, bet.resultHeads);
    }

    /// @notice Anyone may settle a ready bet, always crediting the original player.
    function settle(uint256 requestId) external nonReentrant {
        Bet storage bet = bets[requestId];
        if (bet.state != State.Ready) revert BetNotReady();
        bet.state = State.Settled;
        uint256 payout = bet.stake * 2;
        reservedPayouts -= payout;
        bool won = bet.heads == bet.resultHeads;
        if (won) {
            credits[bet.player] += payout;
            totalCredits += payout;
        }
        emit FlipSettled(requestId, bet.player, won, won ? payout : 0);
    }

    /// @notice Withdraw a chosen portion of winnings; a failed transfer leaves the credit intact.
    function withdrawWinnings(address recipient, uint256 amount) external nonReentrant {
        _checkRecipient(recipient);
        if (amount == 0 || amount > credits[msg.sender]) revert InvalidAmount();
        credits[msg.sender] -= amount;
        totalCredits -= amount;
        token.safeTransfer(recipient, amount);
        emit WinningsWithdrawn(msg.sender, recipient, amount);
    }

    function pendingRewards(address player) public view returns (uint256) {
        return storedRewards[player]
            + Math.mulDiv(rewardShares[player], rewardPerShare - rewardIndexPaid[player], REWARD_SCALE);
    }

    /// @notice Claim all accrued fee rewards, independent of winnings or oracle availability.
    function claimRewards(address recipient) external nonReentrant returns (uint256 amount) {
        _checkRecipient(recipient);
        _checkpointRewards(msg.sender);
        amount = storedRewards[msg.sender];
        if (amount == 0) revert InvalidAmount();
        storedRewards[msg.sender] = 0;
        rewardReserve -= amount;
        token.safeTransfer(recipient, amount);
        emit RewardsClaimed(msg.sender, recipient, amount);
    }

    function _allocateRewards(address player, uint256 stake, uint256 fee) private {
        rewardReserve += fee;
        uint256 previousShares = totalRewardShares;
        // Historical accepted stake volume earns new fees. No oracle/settlement ordering dependence.
        if (previousShares != 0) rewardPerShare += Math.mulDiv(fee, REWARD_SCALE, previousShares);
        _checkpointRewards(player);
        rewardShares[player] += stake;
        totalRewardShares = previousShares + stake;
        // Bootstrap: with no earlier players, the first fee belongs to the first player.
        if (previousShares == 0) rewardPerShare += Math.mulDiv(fee, REWARD_SCALE, stake);
    }

    function _checkpointRewards(address player) private {
        storedRewards[player] = pendingRewards(player);
        rewardIndexPaid[player] = rewardPerShare;
    }

    function _receiveTokens(address from, uint256 amount) private {
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        if (token.balanceOf(address(this)) != beforeBalance + amount) revert UnsupportedToken();
    }

    function _checkRecipient(address recipient) private view {
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
    }
}
