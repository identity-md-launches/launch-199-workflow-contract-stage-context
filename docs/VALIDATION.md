# Local validation record

Implementation environment: Foundry 1.8.3, Solidity 0.8.26. This record describes contributor checks, not independent review or service admission.

Final clean verification:

```sh
forge clean
forge build
forge test
forge fmt --check
```

All commands succeeded with the offline Foundry profile. The retained suite reports **37 passed, 0 failed, 0 skipped**, including two grouped accounting invariants checked over **128 runs / 8,192 handler calls**, with zero unexpected reverts. A deterministic handler trace also proves execution of entry, both outcomes, settlement, winnings withdrawal, rewards, bankroll movement and pause.

The supplied protected test files were copied unchanged into scratch space and executed separately with process-local constructor/bytecode parameters. All **8 protected checks passed with no skips**. This local run used the delivered creation code, chain ID 11155111, predicted CREATE2 addresses, explicit test owner, and an inert test coordinator address. It confirms the deployment floor and supply/runtime restrictions for those arguments; it does not establish a real coordinator, operational subscription, signed manifest, policy authority or production readiness. The scratch copies were then removed so the ordinary suite needs no environment values. No test uses `vm.setEnv`.

Compiled runtime sizes are **1,772 bytes for IMDToken** and **6,626 bytes for CoinFlip**, below 24,576 bytes. Runtime scans pass the protected restrictions on `DELEGATECALL`, `CALLCODE` and `SELFDESTRUCT`. Both constructors are nonpayable, contain only permitted static arguments, and preserve the factory token balance. Committed ABI arrays were compared with compiled artifacts and match.

The build emits four non-fatal lint diagnostics: one reentrancy-state warning at the coordinator call, two post-call event warnings, and an exact-balance-equality warning. The coordinator and token operations execute under OpenZeppelin's `nonReentrant` guard; adversarial tests assert the guard's specific revert on nested calls. The request event must follow receipt of its request ID. Exact inbound balance comparison deliberately rejects token transfer taxes for the fixed IMD token. These diagnostics and the corresponding rationale remain visible for the independent reviewer; they have not been suppressed globally.

Live VRF proofs, subscription funding, final immutable launch parameters, source publication, policy/signature linkage, the separate `launch.json`, actual deployment, website behavior and independent adversarial review are outside this local validation.
