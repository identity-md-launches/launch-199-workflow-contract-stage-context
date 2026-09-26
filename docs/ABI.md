# ABI integration

`docs/abi/IMDToken.json` and `docs/abi/CoinFlip.json` are plain ABI arrays generated from the Solidity 0.8.26 build. They include constructors, errors, functions and events. Regenerate after changing source:

```sh
forge inspect src/IMDToken.sol:IMDToken abi --json > docs/abi/IMDToken.json
forge inspect src/CoinFlip.sol:CoinFlip abi --json > docs/abi/CoinFlip.json
```

Use arbitrary-precision integers for all token values and request IDs; token decimals are 18. `true` selects heads. A win pays twice the **stake**, not twice the entry debit. Game methods are nonpayable; ETH for VRF is supplied to the separate subscription, never attached to `flip`.

| Action | Interface | Notes |
| --- | --- | --- |
| Entry quote | `quoteFee(uint256)`, `minStake()`, `maxStake()`, `availableBankroll()`, `paused()` | Fee is rounded down; quote may become stale if bankroll or pause changes |
| Allow spending | Token `approve(game, stake + fee)` | Repeated entries need sufficient remaining allowance |
| Enter | `flip(uint256 stake, bool heads)` → `uint256 requestId` | In a transaction, obtain ID from `FlipRequested`; source return values are also useful for contract callers |
| Inspect round | `bets(uint256 requestId)` | Returns `(address player, bool heads, bool resultHeads, uint8 state, uint256 stake)`; `resultHeads` is meaningful only in Ready/Settled |
| Settle | `settle(uint256 requestId)` | Anyone can submit when state is Ready; credits go only to the recorded player |
| Withdraw winnings | `credits(player)`, `withdrawWinnings(address recipient, uint256 amount)` | Caller controls only their own balance; zero and overdraw revert |
| Reward balance | `pendingRewards(player)`, `rewardShares(player)` | Pending rewards include stored and uncheckpointed rewards; shares are historical volume, not transferable tokens |
| Claim rewards | `claimRewards(address recipient)` → `uint256 amount` | Claims caller's entire accrued amount; zero reverts |
| Sponsor funding | `fundBankroll(uint256 amount)` | Approve first; irrevocable donation to risk capital |
| Owner controls | `setPaused(bool)`, `withdrawBankroll(address,uint256)` | Requires immutable explicit owner; only free bankroll withdrawable |

Oracle callbacks use `rawFulfillRandomWords(uint256,uint256[])`, callable only by the immutable coordinator. A frontend must never invoke a local mock to decide a production outcome. The game sends the official tuple signature `requestRandomWords((bytes32,uint256,uint16,uint32,uint32,bytes))`, with `numWords = 1` and extra args `abi.encodeWithSelector(bytes4(keccak256("VRF ExtraArgsV1")), true)`.

Primary events are `FlipRequested` (indexed request ID and player), `RandomnessReceived` (verified bit), `FlipSettled` (won and payout), `WinningsWithdrawn` and `RewardsClaimed`. Read onchain state again after confirmations and handle reorgs; request IDs bind results to rounds even when callback order differs from entry order.

Useful custom errors include `GamePaused`, `InvalidStake`, `InsufficientBankroll`, `BetNotReady`, `InvalidAmount`, `InvalidRecipient`, `Unauthorized`, `InvalidRequestId` and `UnsupportedToken`. Token allowance/balance failures and coordinator rejections can bubble through entry. An entry revert means no stake was collected and no local round exists. A successful request followed by an unavailable callback remains Pending without a timeout refund.
