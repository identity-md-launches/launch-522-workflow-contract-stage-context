# PvPad contracts

This contribution implements the contract stage for the permissionless PvPad launchpad from [the pinned upstream release](https://github.com/Lavel0rz/pvpad/tree/abc00a55b20f9ab6552413b34634bc5f788c5597). The frozen product requirements are in [SPEC.md](SPEC.md). It includes local tests, vendored dependencies and [ABI exports and integration notes](docs/ABI.md); deployment, publication, policy admission, `launch.json`, independent launch review, and the `pvpad` frontend are subsequent contributions/services.

## Build and verify

```sh
forge build
forge test
forge fmt --check
python3 tools/export_abis.py
```

Foundry pins Solidity **0.8.26**, Cancun, optimizer 200, and `bytecode_hash = "none"`. The verifier supplies the compiler. Every imported Solidity dependency is an ordinary file under `lib/`, with revisions in [DEPENDENCIES.json](DEPENDENCIES.json); no installation, submodule, network, FFI, environment variables, or filesystem cheatcodes are needed by the tests. Tests use the actual vendored Uniswap v4 PoolManager locally, not a fork or a funded wallet.

## Economics and lifecycle

| Parameter | Behavior |
| --- | --- |
| Each pad token | 1 billion tokens, 18 decimals, fixed supply; full supply transferred atomically to its curve |
| Genesis | Launch 0, Pepe Values Pepe / PVP, created without a fee in the factory constructor |
| Later launches | Permissionless; exact `0.0005 ETH` create fee goes entirely to WorkerSubsidy |
| Curve and pool fees | 1% of the native ETH leg; half to current king beneficiary, half to creator; odd fee wei to creator |
| Graduation | Permissionless at exactly `4.2 ETH` net curve reserves |
| Graduated pool | Native ETH/token, fee tier 0, tick spacing 60; shared hook charges pad fee |
| LP | Full-range position owned permanently by factory; no removal or withdrawal entrypoint |
| King | Bid strictly greater than claim price; starts `0.01 ETH`, price increases 10% per claim; entire bid to workers, no previous-king refund |
| Before first king | King share belongs to the first beneficiary, even if claimed after later crowns |

The factory supports multiple independent launches, creator metadata, curve trading, progress, and graduation. `createLaunch` accepts token name and symbol, with an optional caller-selected salt and immutable metadata URI (up to 2048 bytes for JSON image/social references). Genesis has an empty URI. Names/symbols are display strings, not unique identifiers; use factory address plus launch ID. Token contracts are plain ERC-20s with no mint/admin/fee/upgrade path after construction. Third parties can create their own markets for freely transferable tokens; the pad's canonical pool is the one whose swaps are gated until graduation.

Curve trades support minimum output and deadline parameters. Integrators should use those protected overloads, quote immediately before signing, and display refunded excess input at the threshold. Direct donations are not counted as curve reserves and do not accelerate graduation; donated ETH/tokens stay unrecoverable in the curve after graduation.

### Curve formula and graduation

Let `S = 10^27` token units, virtual tokens `Vt = S/8`, virtual ETH `Ve = 2.1 ETH`, and real reserves `(T,E)`, initially `(S,0)`. Constant-product pricing uses `(T + Vt) * (E + Ve)`. Buys charge a fee from accepted gross ETH input; sells charge a fee from gross ETH output. Output rounds down to protect reserves. Buys cap net reserves at `4.2 ETH` and refund unused ETH; sells cannot spend phantom reserves. Repeated rounding can leave small token dust.

At the target reserve, the theoretical real token reserve is `S/4`. Thus the curve's terminal marginal price equals the pool reserve price, `(4.2 ETH)/(S/4)`. The factory fixes this pool initialization price and deposits as much of both reserves as full-range liquidity can consume. Rounding remainders stay locked in the factory. Curve trading stops after the atomic graduation transaction; a failed PoolManager interaction rolls back the sweep and all graduation state.

The canonical pool is initialized atomically during creation, with swaps disabled until graduation. Because the required shared hook has **no beforeInitialize**, someone who predicts a future token address can preinitialize its pool. An existing pool is accepted only at the canonical price; a conflicting price fails closed, preserving funds. Retry with a different creation salt (or factory deployment salt for genesis); private transaction submission reduces mempool grief. This is a remaining availability limitation, not permission to seed at an attacker-selected price.

### Post-graduation trades and delivery

The shared hook takes ETH for both trade directions and supports exact input and exact output. When ETH is the specified amount, fees use `beforeSwapReturnDelta`; when ETH is unspecified, they use the actual ETH delta and `afterSwapReturnDelta`. Exact ETH output is grossed up to preserve the requested net amount; exact token output grosses up the pool's required ETH input. Each gross-up uses fee `(net - 1) / 99` for nonzero net, the smallest gross amount whose rounded 1% fee leaves that net. A specified-ETH partial fill reverts atomically; an unspecified-ETH partial fill charges only actual execution. Standard routers must account for hook deltas and enforce their own output/maximum-input protections.

Escrow recording makes no call to a creator or beneficiary. They withdraw their own credits to a chosen recipient. A rejecting recipient leaves the credit available for retry. If recording fails, curve/hook custody retains deferred ETH, original beneficiary and per-trade rounded shares; anyone may retry delivery without redirecting it. Deferred pre-crown fees still belong to the first beneficiary. No fees are diverted to a house treasury.

## Deployment parameters and responsibilities

All top-level application constructors are nonpayable and use supported static argument types. Deploy in this order:

| Artifact | Constructor arguments / responsibility |
| --- | --- |
| `LaunchToken` | None; protocol-required launch artifact |
| `WorkerSubsidy` | `address initialUpdater`: approved operational role, expressed as `$owner` if policy assigns that role to owner |
| `KingOfThePad` | `address workerSubsidy` |
| `PvPadHook` | `address poolManager`: independently verified target-chain PoolManager |
| `PvPadFactory` | `address poolManager`, `address workerSubsidy`, `address king`, `address hook`, `address genesisCreator` (policy-approved `$owner`) |

Factory construction creates its own immutable FeeEscrow and genesis token/curve; it needs no initialization transaction. Later pad launches deploy PvPadToken and BondingCurve internally, so these dynamic child constructors are not entries in the top-level launch manifest. The hook authenticates each binding against the token's immutable factory and the escrow's immutable factory, supporting constructor-created genesis without callbacks to an unfinished factory.

The hook requires CREATE2 address flags **0x00cc** (beforeSwap, afterSwap, and both swap-return-delta permissions). `HookMiner` is a local pure-address derivation helper; deployment services must mine against their actual CREATE2 deployer, creation bytecode and PoolManager constructor argument. A wrong flag address reverts construction. If the deployment service's salt scheme cannot yield those bits, that is a concrete deployment integration conflict for manifest review. Do not substitute an arbitrary hook address.

The separate manifest contributor writes `launch.json` from these ABIs and accepted source; source publication, signed artifact linkage, policy allocation, attestation and admission belong to services. Application pools have fee 0 and this hook; the protocol launch-token pool remains subject to its independent pinned policy (including its fee and currency). Do not confuse those pools.

### LaunchToken versus the pad genesis token

The mandated `src/LaunchToken.sol` mints exactly `10^27` units to its deployer, with no arguments or privileged controls. Protocol services distribute it under launch policy (currently 80% pool / 10% swarm / 10% treasury). **It is distinct from launch 0's PvPadToken**, whose whole supply funds its curve as the product requires. Both use the brief's PVP name/symbol; integrations must distinguish addresses. The protocol LaunchToken does not implement the brief's full-supply-to-curve allocation; the factory-created pad tokens do. No application constructor moves the protocol launch supply.

### Sepolia address handoff

No transactions were broadcast and no addresses are claimed as deployed or verified by this contribution.

| Item | Sepolia (chain ID 11155111) |
| --- | --- |
| PoolManager | Service must supply and verify; no task network.json was provided |
| Protocol LaunchToken | Pending service deployment |
| WorkerSubsidy / KingOfThePad | Pending service deployment |
| Shared PvPadHook / PvPadFactory | Pending service deployment |
| Factory FeeEscrow / genesis PVP / genesis curve | Read factory getters and `LaunchCreated` after service deployment |
| Second token proof | Exercised locally in integration tests; chain proof belongs to deployment service |
| Published source / site / PR | Service handoff; requested site name `pvpad`, IPFS hosting and imd-deployment wiring |

## Worker keeper runbook and custody

1. The off-chain keeper obtains accepted work from `https://api.imd.fun/workers`, resolves seats to payees, and aggregates one amount per payee. Solidity makes no HTTP calls.
2. Prefer the Identity MD oracle workflow (panel 70 / quorum 67) before the trusted updater signs. The contracts do not verify that off-chain attestation.
3. Read next epoch ID and available `workerPot`; construct sorted-pair Merkle trees with double-hashed leaves `keccak256(bytes.concat(keccak256(abi.encode(epochId, payee, amount))))`. The leaf's epoch prevents cross-epoch replay. Publish the complete allocation, proof and epoch metadata for payees.
4. The updater calls `setEpoch(root, windowStart, windowEnd)` with a valid nonzero root and a window at most 90 days. Choose a future start with inclusion margin: `windowStart` must be at least the timestamp of the mined transaction. It reserves the available pot as that epoch's budget. Allocation sum must fit the budget; newly donated funds remain available for later epochs.
5. Anyone can relay `claimWorker(epochId,payee,amount,proof)`; ETH always goes to the proof's payee. Each payee claims once per epoch. A rejected ETH transfer reverts the claim and leaves it retryable during the window.
6. After expiry, anyone can recycle unclaimed reserved funds into the pot for a later epoch. Updater rotation uses propose/accept, never an implicit deployer role.

The updater can publish a dishonest root and allocate the available worker pot to itself. Merkle membership proves inclusion, not fair work or oracle approval. Use a policy-approved multisig, independent allocation review and an operational signing policy before production. No updater can withdraw curve reserves, LP, or fee credits. There is no pause, upgrade, creator LP withdrawal or hidden fee beneficiary.

## Validation and remaining review

Validation completed with `forge build`, `forge test -j 4` (**57 passed, 0 failed, 0 skipped**), and `forge fmt --check`. A fresh `forge test --offline --no-cache -j 4` also passed with only PATH set in the environment. All eight ABI exports match build artifacts; runtime size and forbidden-opcode checks pass.

Tests cover genesis and a second launch, curve round trips and limits, real v4 swaps in all four modes, locked liquidity, shared king fee accounting, permission checks, failed payouts and deferred delivery, reentrancy, worker windows/claims, and token invariants. The protected deployment checks are a baseline for supply, runtime size and forbidden opcodes; local tests do not substitute for the service's signed-artifact checks.

An independent adversarial review of accepted source plus final manifest remains required before release, especially curve rounding, v4 accounting, constructor roles and updater custody. This contribution does not claim an audit, deployment, or completion of hosting. Slither and Mythril were not run.

MIT for project changes; vendored dependencies retain their own licenses.
