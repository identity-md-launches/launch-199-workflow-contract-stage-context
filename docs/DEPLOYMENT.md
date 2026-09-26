# Deployment handoff

This file describes the accepted-source interface for the separate manifest contributor, launch services and independent reviewer. It is not a manifest or a broadcast script. All example numeric choices below are recommendations for review, not deployed configuration.

## Factory artifacts and ordering

Deploy launch token `src/IMDToken.sol:IMDToken` with **no constructor arguments**. Declare symbol `IMD`, name `IdentityMD`, decimals `18`, and total supply `1000000000000000000000000000`. It mints the complete supply to `msg.sender`, which at launch must be ProjectFactory.

Application identifier: **`CoinFlip`** (unique, fewer than 32 ASCII characters). Its source artifact is `src/CoinFlip.sol:CoinFlip`. There is one application, with a backward dependency only on the launch token. Do not name any application `MerkleDistributor`, which is reserved for the protocol artifact. Token-first construction preserves the full factory supply. There are no initialization calls and both constructors are nonpayable.

## CoinFlip constructor arguments, in exact order

| Position | Solidity type | Parameter | Manifest value / choice |
| --- | --- | --- | --- |
| 1 | `address` | `token_` | `$token` |
| 2 | `address` | `owner_` | `$owner`, resolved from pinned policy, never a hard-coded privileged wallet |
| 3 | `address` | `coordinator_` | Verified official Sepolia Chainlink VRF v2.5 subscription coordinator |
| 4 | `uint256` | `subscriptionId_` | Existing, nonzero subscription ID whose operator commits to funding and registering the game |
| 5 | `bytes32` | `keyHash_` | Nonzero official Sepolia key hash supported by that coordinator and selected gas lane |
| 6 | `uint16` | `requestConfirmations_` | Example `10`; enforced range 3–200; verify coordinator minimum and assess reorganization risk |
| 7 | `uint32` | `callbackGasLimit_` | Recommend `200000`; enforced range 100000–2500000; verify coordinator maximum |
| 8 | `uint256` | `minStake_` | Example `1000000000000000000` = 1 IMD; at least 100 minor units so the fee cannot be zero |
| 9 | `uint256` | `maxStake_` | Example `1000000000000000000000` = 1,000 IMD; at least minimum and at most `500000000000000000000000000` |

All addresses must be nonzero. Reference syntax can fill only address positions. Subscription ID, key hash and VRF values have no default or setter; do not put test placeholders into a launch manifest. No `$owner` reference belongs in the token constructor because it takes no arguments. Owner powers belong to the explicit policy owner, not the factory that calls the constructor.

**Unresolved launch choices:** concrete coordinator address, official key hash/gas lane, external subscription ID and operator, confirmation count, stake limits, committed initial bankroll amount and funder. The pinned project owner must be resolved by services. The constructor arguments must be filled and independently reviewed before actual deployment. Consult Chainlink's [supported networks](https://docs.chain.link/vrf/v2-5/supported-networks) and [subscription management](https://docs.chain.link/vrf/v2-5/subscription) for the active Sepolia configuration. This deliverable deliberately does not assert a live subscription or wallet authorization.

The factory deployment floor runs constructors in isolation, without provisioning an external coordinator. Consequently the game constructor performs no external code/subscription checks. Its source works in that floor, but a successful floor does not prove the selected coordinator address is a real VRF verifier or that the subscription will fulfill requests. Those are concrete deployment checks.

## Canonical manifest guidance

The separate manifest has kind `evm_project`, the token above, and the single `CoinFlip` application in its dependency-ordered contracts list. For the supplied native ETH Sepolia pool guidance, native currency is the zero address, fee is 3000, tick spacing is 60, and the legacy initial price string is `79228162514264337593543950336`. The factory supplies the hook-free LP and protocol MerkleDistributor and seeds liquidity with the token only.

The supplied policy-v5 guidance specifies 20 ETH opening FDV, 2% rewards to launch contributors and 8% equally among wallets with accepted work in the preceding 12 hours. **Services apply the pinned policy**, including an effective price derived from `initialMarketCapWei` where present. This game does not implement or override that distribution. Its separate 1% play fee is entirely reserved for game users. Canonical policy selection, attestation, signed-artifact linkage and admission belong to services; they are not additional source/constructor fields to invent. Concrete source, constructor, authority or policy conflicts remain independent-review findings.

## Operational sequence for authorized services

1. Produce the manifest against these exact artifacts and ABI types; resolve immutable VRF arguments and `$owner`. Independently review source and manifest together. Publish source and attest/admit artifacts through the authorized services.
2. Deploy through ProjectFactory. Confirm chain 11155111 (Sepolia), token supply/decimals, deployed bytecode, explicit owner and all immutable game values. The contracts themselves are not chain-locked; choosing Sepolia is a service responsibility.
3. The subscription owner must register the resulting game address as a consumer, ensure the configured key hash is valid, and fund the subscription with sufficient Sepolia ETH including a buffer for all outstanding requests. Billing is always `nativePayment = true`; LINK-only funding is insufficient for these requests. The immutable coordinator cannot be migrated in place.
4. Acquire and approve IMD from an authorized post-launch allocation, then call `fundBankroll`. No tokens are taken from the factory during constructors. A balance of at least the largest desired stake is necessary to accept that stake, and substantially more risk capital is needed for concurrent bets and variance. Funders must understand deposits are donations subject to owner withdrawal of free capital.
5. Start the frontend only after consumer registration, funding and integration checks. Display chain/addresses, total debit (`stake + fee`), gross winning payout, available bankroll, both claim types, and the permanent oracle-failure lock risk. Never display a generated frontend animation as an actual settled result.
6. Monitor `FlipRequested`, `RandomnessReceived`, `FlipSettled`, subscription balances and the ages of pending requests. Anyone may settle a ready request; the website can let its player do so, and an authorized keeper can assist. During incidents the policy owner may pause new entry. Claims and existing settlement remain callable. Do not cancel/migrate the external subscription while outstanding obligations exist.

No keeper, oracle, broadcast or private-key process is run by this contribution. Subscription funding is outside the game contract and can be exhausted by repeated valid small bets. Minimum stake and bankroll limits must be chosen with the operating subsidy in mind. The fair bankroll has no expected fee revenue and must be treated as at-risk capital.

## Independent review focus

- Verify `$token` resolves to the delivered immutable ERC-20 and `$owner` to policy authority; verify the real coordinator/key/subscription tuple rather than a mock or caller-controlled oracle.
- Assess fee/reward economics, first-player advantage, historical-volume rewards, ordering effects, and permanently reserved rounding dust against the intended experience.
- Check accounting and the maximum aggregate outstanding exposure, not only per-bet limits. Confirm no owner path can remove pending stake, winning credit or rewards.
- Assess coordinator/subscription availability, confirmations and callback gas with the actual deployment. Permanent failures can lock stakes; there is deliberately no refund or reroll mechanism.
- Review the custom immutable callback authentication. Chainlink's mutable consumer-base migration/ownership extensions are not inherited. Changing an immutable configuration requires a new deployment; accepted bets remain in the original contract.

These are handoff considerations, not findings from an independent reviewer. That separate review and launch manifest remain outside this source assignment.
