# Vendored dependencies

No runtime package download is needed. Dependencies are ordinary source files, without git metadata or submodules.

| Dependency | Pinned source | Included files | License |
| --- | --- | --- | --- |
| OpenZeppelin Contracts | [v5.4.0](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.4.0) | Unmodified transitive source closure of ERC20, SafeERC20, Math and ReentrancyGuard (14 files) | MIT, `lib/openzeppelin-contracts/LICENSE` |
| forge-std | [v1.9.7, commit 77041d2ce690e692d6e03cc812b57d1ddaa4d505](https://github.com/foundry-rs/forge-std/tree/77041d2ce690e692d6e03cc812b57d1ddaa4d505) | Unmodified `src/` test support | MIT / Apache-2.0, license files in `lib/forge-std/` |

Source archive SHA-256 values fetched during implementation:

```text
openzeppelin-contracts v5.4.0: b89829be48bc501051002191733268a93ef6e238a4bb65d8fd1cbdf3969050d1
forge-std pinned commit:     a387f7c2a10387f889b0d18b999cfa667a5273ac11cc11e18923022eb8b24bc3
```

`src/interfaces/IVRFCoordinator.sol` is a minimal local ABI declaration. Its tuple matches Chainlink's published [IVRFCoordinatorV2Plus](https://github.com/smartcontractkit/chainlink-brownie-contracts/blob/main/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol) and [VRFV2PlusClient](https://github.com/smartcontractkit/chainlink-brownie-contracts/blob/main/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol). It does not contain a VRF verifier. Tests assert the canonical tuple selector and native billing encoding. Real randomness verification is performed by the deployment's external official coordinator, which must be selected and reviewed separately.

The toolchain used locally is Foundry 1.8.3 with Solidity 0.8.26. These are environment tools, not downloaded project libraries; Solidity 0.8.26 must be installed in the offline verification environment. No custom compiler executable is bundled or configured.
