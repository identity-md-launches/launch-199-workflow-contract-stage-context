# IMD Coin Flip

Contract-stage implementation of the approved single-player IMD coin flip. A player selects heads or tails, stakes `X` IMD, and receives a **gross payout of exactly `2X` on a win or zero on a loss**. The independent play fee is `floor(X / 100)` minor units (1%). All collected game fees are reserved for user rewards. Odds are 50/50 under the Chainlink VRF and chain assumptions below.

This contribution contains contracts, offline tests, ABI exports and deployment handoff documentation. The separate manifest contributor writes `launch.json`; the independent reviewer reviews the accepted source and that manifest. Source publication, artifact signing, policy admission, actual Sepolia deployment, and the public IPFS frontend are subsequent service responsibilities. No wallet, transaction broadcast, frontend deployment or independent audit is supplied here.

## Build and test offline

With Foundry and Solidity **0.8.26** available locally:

```sh
forge build
forge test
forge fmt --check
```

The configuration enforces offline compilation, disables FFI, grants no filesystem cheatcode permissions, and uses the versioned Solidity compiler rather than an executable compiler override. It compiles for Paris with optimization, `bytecode_hash = "none"`, and no CBOR metadata. All Solidity dependencies are ordinary vendored files in `lib/`; no package manager, git submodule, RPC or network connection is needed for checks. Dependency origins and licenses are in [DEPENDENCIES.md](DEPENDENCIES.md).

The tests cover token supply/transfers/allowances, exact win and loss payouts, concurrent and out-of-order requests, callbacks and request encoding, authorization, insufficient funds, request rollback, duplicate actions, paused and late results, gas failure, malicious token/coordinator reentry, failed payment retries, reward rounding, and factory construction/runtime restrictions. Stateful tests check all reserves, credits, reward liabilities and token conservation over mixed actions. Mocks do not verify VRF proofs and demonstrate local behavior only.

## Contracts

| Artifact | Purpose | Constructor |
| --- | --- | --- |
| `src/IMDToken.sol:IMDToken` | ERC-20 named IdentityMD, symbol IMD, 18 decimals | No arguments; mints exactly `10^27` minor units to its deployer |
| `src/CoinFlip.sol:CoinFlip` | IMD staking, VRF request/callback, settlement, bankroll and rewards | Nine immutable static arguments; see [deployment handoff](docs/DEPLOYMENT.md) |

The token has no owner, fee, mint entrypoint, burn entrypoint, upgrade path or privileged supply change. Application construction does not move the factory's supply, make external calls, or depend on initialization. The factory must deploy the token first and pass `$token` and the explicit policy `$owner` into the game. Neither contract uses a proxy, `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`.

## Playing and round transitions

Each bet is a separate single-player round. There is no shared entry window and no opposing player to match. Multiple bets may be pending for one or many wallets.

1. Read `minStake`, `maxStake`, `paused`, `availableBankroll()` and `quoteFee(X)`. The game's free bankroll must cover at least `X`, and the player must hold and approve **`X + fee`** IMD to the game.
2. Call `flip(X, heads)`. It atomically transfers the stake and fee, reserves `2X`, records reward participation, and requests one VRF word. A rejected request reverts the complete entry, including token transfers and rewards.
3. Use `FlipRequested.requestId` as the bet identifier. `Pending` means waiting for the coordinator; all bet inputs are immutable. A later `flip` creates a different round and cannot change any earlier bet.
4. The authenticated coordinator callback sets `Ready`. The least significant bit is the coin: odd = heads, even = tails. There is no timestamp, block-value, caller-seed or manual-outcome fallback.
5. Anyone calls `settle(requestId)`. The bet becomes `Settled` exactly once. A match credits `2X` to the original player; a mismatch releases the full reservation into the bankroll. The settler cannot redirect the payout.
6. The player calls `withdrawWinnings(recipient, amount)` to pull all or part of their credit. Failed transfers leave credits intact for retry. Rewards are claimed separately with `claimRewards(recipient)`.

`State` enum values are `0=None`, `1=Pending`, `2=Ready`, `3=Settled`. Settlement never transfers tokens. Callback handling only stores the result and emits an event; it does not invoke the player or token. Unknown, duplicate, or wrong-length coordinator callbacks are ignored without changing an outcome. Non-coordinator callbacks revert.

For a 100 IMD stake, the wallet pays 101 IMD on entry. A win creates 200 IMD of winnings; a loss creates no winnings. Fee rewards are separate and depend on historical participation. Network transaction fees and the external VRF subscription's ETH costs are separate from this IMD fee.

## Fee rewards

The workflow did not define the game fee rate or reward formula. This implementation fixes a 1% fee and redistributes 100% of collected game fees to users, with no treasury percentage. One minor unit of accepted stake earns one nontransferable, nonredeemable reward share. Shares persist and represent cumulative play volume, not ownership of the bankroll or token supply. Wins, losses and pending bets all earn shares because the fee is collected when the request is accepted.

Each new entry allocates its fee among **previously existing shares**, then adds the new stake's shares. An existing player earns on their previous shares when they play again. A newcomer cannot capture earlier fees. With no previous participants, the first player's fee is allocated to that player. Requests that revert earn nothing. Allocation is independent of oracle fulfillment and settlement ordering.

The implementation uses a cumulative reward index scaled by `10^27`, checkpoints each user's accrual before increasing their shares, and rounds down. Fractions below one minor unit discarded at a user checkpoint, and global division dust, remain in `rewardReserve`; there is no owner dust sweep. Extremely small fees relative to lifetime volume can be entirely rounding dust. Claiming or playing more often can discard more fractional dust. Claimable rewards never exceed the collected fee reserve.

Rewards can be claimed while a bet is pending or the game is paused. More play increases a wallet's share of future fees, but does not guarantee profit. Early players benefit from historical shares, and transaction ordering affects who already has shares when a fee arrives. Multiple wallets do not create extra backed rewards. These are participation rewards, not randomness-dependent prizes. Pool trading fees, network contributor rewards and other protocol fees are outside the game's custody and are not collected by this contract.

## Bankroll and custody

Before play, a sponsor must acquire IMD through the authorized token distribution and fund the game. The factory constructor cannot provide a bankroll because the entire token supply must remain at the factory during construction. `fundBankroll(amount)` requires allowance and is a donation to the owner's risk capital; it creates no deposit shares or refund claim. Direct IMD transfers also add free bankroll.

At every supported-token state:

```text
game IMD balance = availableBankroll + reservedPayouts + totalCredits + rewardReserve
reservedPayouts = sum(2 * stake for every Pending or Ready bet)
```

The immutable owner may pause/resume entry and withdraw **only** `availableBankroll`. Pending outcomes remain reserved even when their word already proves a loss, until permissionless settlement. Winnings and fee rewards cannot be swept. Owner withdrawal can reduce or eliminate new betting capacity, but does not impair already accepted payouts. A fair 2x game has no expected house edge on stakes; fees go to users. Sponsors bear variance and fund VRF costs without guaranteed revenue. A run of wins can exhaust free bankroll and stop further entry safely.

Only the supplied fixed-supply IMD token is supported. Inbound transfers must move exactly the requested amount; rebasing, taxed, upgradeable or malicious replacements are outside the supported model. Recipient zero and the game itself are rejected. There is no ETH entry route or asset-rescue function; unrelated tokens and forcibly sent ETH can be stranded.

## Randomness, failures and timeouts

The game integrates the Chainlink VRF **v2.5 subscription** ABI, using one word and native-ETH subscription billing. The configured coordinator verifies proofs; the consumer authenticates its callback address. The constructor fixes the coordinator, key hash, subscription, confirmations and callback gas limit. Our minimal immutable consumer intentionally has no coordinator-migration or owner-setter extension. The operator must register the deployed game as a consumer and fund the external subscription; this is operational provisioning, not contract initialization.

The chosen confirmation count must be assessed against chain reorganization risk and total outstanding value. Choosing the wrong coordinator could allow arbitrary outcomes. Constructors only validate static values, not external coordinator code or subscription state, so the final reviewer must check the concrete launch arguments against official Chainlink configuration.

There is **no cancellation, reroll, deadline refund, manual settlement, coordinator replacement or administrator-selected random value**. Valid results arriving arbitrarily late are accepted. This prevents a player or operator from observing/discarding an unfavorable result through a timeout. If the oracle/subscription fails permanently, accepted stakes and matching bankroll may remain locked permanently. An insufficiently funded subscription must be topped up; pausing new entries does not release outstanding reservations. If the real coordinator consumes a callback that fails or runs out of gas, it does not automatically retry; neither the owner nor the player can fabricate a replacement. The minimum callback budget is tested locally, and the deployment recommendation includes additional margin.

The design follows Chainlink's [request binding, confirmation, cancellation and callback guidance](https://docs.chain.link/vrf/v2-5/security). The authenticated external coordinator and underlying chain remain trust/liveness dependencies. Subscription operators can affect availability through funding or consumer management. The local mock is not a substitute for independent integration review.

## Handoff

See [deployment parameters and responsibilities](docs/DEPLOYMENT.md) and [ABI integration guide](docs/ABI.md). The ABI arrays are [IMDToken.json](docs/abi/IMDToken.json) and [CoinFlip.json](docs/abi/CoinFlip.json).

Passing local tests is not an independent security audit. Before release involving users' funds, the separate reviewer must assess source and the concrete manifest together, including every authority-granting argument, bankroll assumptions, permanent-lock risks and subscription availability. No independently reviewed `launch.json` or live deployment is claimed by this source contribution.
