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
| LP | Full range; the hook closes the pool to all other liquidity until graduation; permanently factory-owned with no withdrawal |
| King | Bid strictly greater than claim price; starts `0.01 ETH`, price increases 10% per claim; entire bid to workers, no previous-king refund |
| Before first king | King share belongs to the first beneficiary, even if claimed after later crowns |

The factory supports multiple independent launches, creator metadata, curve trading, progress, and graduation. `createLaunch` accepts token name and symbol, with an optional caller-selected salt and immutable metadata URI (up to 2048 bytes for JSON image/social references). Genesis has an empty URI. Names/symbols are display strings, not unique identifiers; use factory address plus launch ID. Token contracts are plain ERC-20s with no mint/admin/fee/upgrade path after construction. Third parties can create their own markets for freely transferable tokens; the pad's canonical pool is the one whose swaps are gated until graduation.

Curve trades support minimum output and deadline parameters. Integrators should use those protected overloads, quote immediately before signing, and display refunded excess input at the threshold. Direct donations are not counted as curve reserves and do not accelerate graduation; donated ETH/tokens stay unrecoverable in the curve after graduation.

### Curve formula and graduation

Let `S = 10^27` token units, virtual tokens `Vt = S/8`, virtual ETH `Ve = 2.1 ETH`, and real reserves `(T,E)`, initially `(S,0)`. Constant-product pricing uses `(T + Vt) * (E + Ve)`. Buys charge a fee from accepted gross ETH input; sells charge a fee from gross ETH output. Output rounds down to protect reserves. Buys cap net reserves at `4.2 ETH` and refund unused ETH; sells cannot spend phantom reserves. Repeated rounding can leave small token dust.

At the target reserve, the theoretical real token reserve is `S/4`. Thus the curve's terminal marginal price equals the pool reserve price, `(4.2 ETH)/(S/4)`. The factory fixes this pool initialization price and deposits as much of both reserves as the selected liquidity range can consume. Remainders stay locked in the factory. Both buys and sells stop once accounted reserves reach the threshold, so a dust sell cannot invalidate a pending permissionless graduation. Sell quotes return zero in that state. A failed PoolManager interaction rolls back the sweep and all graduation state; anyone can retry, while curve trading remains closed at the threshold.

Graduation deposits the full-range ticks `[-887220,887220]`. The shared hook's `beforeAddLiquidity` callback keeps every canonical pool **closed to liquidity until graduation**: the PoolManager only accepts a deposit whose caller is the bound factory (the graduation deposit itself) or whose pool the factory has already registered as graduated. Any other pre-graduation deposit reverts `LiquidityClosed`, so nobody can saturate a boundary tick's liquidity cap for dust and force a `TickLiquidityOverflow` or a narrower range. After graduation anyone may add and remove their own positions; the factory's position has no removal path. Pools that name this hook but were never bound by a factory (for example a different fee tier) never open.

The inward-moving boundary scan from the previous revision remains as defense in depth: if a boundary tick were somehow saturated, the factory still moves only that boundary inward by tick spacing 60, keeps the canonical price strictly inside, records `lockedTickLower`/`lockedTickUpper` and emits `LiquidityRangeLocked` (salt is `bytes32(launchId)`), or reverts `LiquidityRangeUnavailable` atomically. With the hook gate in place this path is unreachable through the PoolManager and every launch locks the full range.

The canonical pool is initialized atomically during creation, with swaps disabled until graduation. Because the required shared hook has **no beforeInitialize**, someone who predicts a future token address can preinitialize its pool at a foreign price. `createLaunch` now scans up to `MAX_SALT_ATTEMPTS` (16) salt derivations: attempt 0 is the original `keccak256(abi.encode(launchId, creator, name, symbol, userSalt))`, later attempts append the attempt index. A predicted pool that is uninitialized or already at the canonical price is used; a poisoned one is skipped and `LaunchSaltRetried(launchId, attempt, token)` is emitted. Genesis construction uses the same scan. If every bounded candidate is poisoned the create reverts `UnexpectedPoolPrice` and charges nothing; a different user salt moves to a fresh derivation. The final price check before `initialize` is unchanged, so a launch is never seeded at a foreign price. `predictLaunchToken(creator, name, symbol, userSalt)` returns the token address and attempt the next create would use so frontends can display it. Poisoning the 16 candidates costs the attacker 16 pool initializations per launch attempt and still cannot steal or misprice funds; it remains an availability nuisance, not a fund-safety issue.

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

### Hook flags: 0x08cc

The hook requires CREATE2 address flags **0x08cc**: `beforeAddLiquidity` (0x0800, the pre-graduation liquidity gate), `beforeSwap` (0x0080), `afterSwap` (0x0040), `beforeSwapReturnDelta` (0x0008) and `afterSwapReturnDelta` (0x0004). There is still **no beforeInitialize** and no afterInitialize, remove-liquidity or donate callback. The constant is exported as `PvPadHook.REQUIRED_FLAGS`, `PvPadConstants.HOOK_FLAGS` and `HookMiner.PVPAD_HOOK_FLAGS`; `HookMiner.findPvPadHook(deployer, poolManager)` mines a salt for it locally. An address carrying the previous **0x00cc** layout is rejected by the constructor (`HookAddressNotValid`), so any salt mined for the earlier revision is void. `HookMiner` is a local derivation helper; deployment services must mine against their actual CREATE2 deployer, creation bytecode and PoolManager constructor argument. If the deployment service's salt scheme cannot yield those bits, that is a concrete deployment integration conflict for manifest review. Do not substitute an arbitrary hook address.

The committed `launch.json` notes still describe the earlier 0x00cc requirement. This source-only revision does not edit the manifest; the manifest contributor must regenerate it against this source before any deployment, and nothing in this revision is deployed, redeployed or re-minted.

The deployment service must record the actual deployer, salt, final creation-code hash including encoded PoolManager argument, and predicted hook address; verify `(uint160(address) & 0x3fff) == 0x08cc`, and pass that salt through the application deployment mechanism. Factory construction calls the PoolManager to inspect and initialize genesis, so constructor simulation must use Sepolia (chain ID `11155111`) or its fork with verified live PoolManager code. Merely setting a local chain ID does not supply that code. After any artifact or constructor-argument change, recompute addresses and simulate the complete deployment order. The reported candidate `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` is not verified by this source contribution. Concrete chain checks and mined service salt/address evidence remain deployment/admission outputs, not fabricated local deployment claims.

`genesisCreator` is the immutable lifetime beneficiary of genesis's creator half of each curve/hook fee, including odd fee wei. There is no rotation path. Policy must authorize this address as the actual genesis creator; `$owner` must not silently mean a generic deployment wallet. `initialUpdater` is a separate custody role, even if policy assigns the same `$owner` to both. The manifest reviewer must inspect those resolved arguments against policy; this source revision does not supply or edit `launch.json`.

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

The updater can publish a dishonest root and allocate the available worker pot to itself. It can also reserve the pot for an arbitrarily distant future window: the 90-day bound limits window duration, not the start's distance from the present. Claims wait until that start and recycling waits until expiry; updater rotation cannot cancel an existing epoch. Merkle membership proves inclusion, not fair work or oracle approval. Use a policy-approved multisig, independent allocation/window review and an operational signing policy before production. No updater can withdraw curve reserves, LP, or other accounts' fee credits. There is no pause, upgrade, creator LP withdrawal or hidden fee beneficiary.

## Validation and remaining review

Revision validation completed with `forge build`, `forge test` (**123 passed, 0 failed, 0 skipped**), and `forge fmt --check`. The source fixes in this revision and their failing-to-passing proofs are listed in [CHANGELOG.md](CHANGELOG.md). All eight ABI exports match build artifacts; runtime size and forbidden-opcode checks pass.

Tests cover genesis and a second launch, curve round trips and limits, real v4 swaps in all four modes, locked liquidity, shared king fee accounting, permission checks, failed payouts and deferred delivery, reentrancy, worker windows/claims, and token invariants. Regressions cover rejected pre-graduation deposits on either boundary and across many ticks, liquidity opening after graduation, unbound pools staying closed, the defense-in-depth range scan and its rollback, threshold sells of any size, and bounded salt retry for poisoned pools (including genesis). The protected deployment checks are a baseline for supply, runtime size and forbidden opcodes; local tests do not substitute for the service's signed-artifact checks.

An independent adversarial review of accepted source plus final manifest remains required before release, especially curve rounding, v4 accounting, constructor roles and updater custody. This contribution does not claim an audit, deployment, or completion of hosting. Slither and Mythril were not run.

MIT for project changes; vendored dependencies retain their own licenses.
