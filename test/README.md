# Adversarial Foundry coverage

These tests extend the existing integration suite using the approved workflow and frozen economics in `SPEC.md`. All dependencies are already vendored. No RPC, fork, FFI, environment mutation, or generated file in `test/scratch/` is required.

| File | Properties and failure paths |
| --- | --- |
| `TokenInvariant.t.sol` | Independent holder/allowance ledgers for both fixed-supply tokens; random transfers, approvals, delegated spending, overspending and invalid recipients; full supply, one wei, zero, maximum approval and failed-spend rollback. |
| `AccountingInvariant.t.sol` | Independent worker deposit/payment ledger, overlapping Merkle epochs, claims, expiry recycling and updater rotation; fee entitlements across crowns, original beneficiaries, odd wei, failed withdrawals and recorder authorization. |
| `CurveInvariant.t.sol` | Multi-actor buy/sell sequences, reserve-product monotonicity, exact ETH/token conservation, donations excluded from reserves, deferred fee retries, captured beneficiaries, irreversible readiness at 4.2 ETH, graduation finality and failed cap-refund rollback. |
| `HookInvariant.t.sol` | Two graduated pools using the real vendored Uniswap v4 PoolManager (the second with rejected pre-graduation saturation attempts and a real foreign position added after graduation), all four swap modes, fees derived from actual ETH movement, failed delivery/retry, crown changes, withdrawals, supply conservation and unchanged factory-owned LP positions. |
| `GraduationLiquidity.t.sol` | Proofs for the hook's pre-graduation liquidity gate: tick-cap grief on either boundary, repeated attempts across many ticks and around the price, attempts while the curve is full, all reverting `LiquidityClosed` and leaving a full-range lock; liquidity opening after graduation with removable own positions; unbound pools staying closed; the defense-in-depth boundary scan and its rollback; fuzzed threshold sells of any size. |
| `LaunchResalt.t.sol` | Bounded salt retry for poisoned predicted pools: skip to the next salt, canonical preinitialization kept, successive front-running, fuzzed poison depth, all 16 poisoned failing closed without charging, genesis re-salting inside the factory constructor, and `predictLaunchToken` agreement with actual creates. |
| `HookSecurity.t.sol` | Fault-injected hook unit tests: 0x08cc flags and rejected legacy 0x00cc addresses, `beforeAddLiquidity` admitting only the bound factory until graduation, unbound pools and direct calls rejected, swap fee math, deferred delivery and retries. |
| `FactoryAdversarial.t.sol` | Invalid configuration/fees/metadata, missing or unfunded launches, independent launches with repeated salts, and complete creation rollback followed by successful retry with identical inputs. |
| `WorkerAdversarial.t.sol` | Cross-epoch proof replay, overallocated-root budget isolation, window boundaries, superseded updaters, callback accounting and reentrancy, overlapping creator/king roles and explicit fee validation. |

Invariant handlers select bounded inputs and several actors, track independent expected balances or entitlements, and check them after each call. Expected failures assert their revert reasons; unexpected handler reverts fail the campaign. Deterministic sequences also exercise successful claims, recycling, deferred delivery and graduation so the important transitions do not rely solely on random selection.

Run counts live in Solidity inline configuration: 256 sequences of depth 64 for tokens, 128 of depth 64 for the worker/escrow/curve campaigns, and 128 of depth 48 for the real-pool campaign. Worker adversarial fuzz properties use 512 runs.

The curve invariant uses a minimal factory fixture to control escrow-recorder availability and exercise the authorized reserve sweep. The real-pool tests exercise actual factory deployment and locked graduation. Hook delivery failures and factory worker-payment failures are explicitly injected with Foundry mocks; this tests rollback and deferred accounting without claiming those failures arise naturally. Assertions of exact asset equality cover the holders and funding paths driven by each handler; unsolicited forced ETH is outside these campaigns.

The graduation regressions keep a fully funded curve unswept, then attempt one-unit, 99-wei-output dust and full-holder-balance sells, buys, donations and deferred fee retries before graduation. Two 256-run fuzz tests check both sell overloads and rollback at capacity, on the minimal fixture and on the real factory. The hook campaign attempts to saturate both extreme tick pairs with real v4 deposits before graduating its second launch (every attempt reverts `LiquidityClosed` as a v4 `WrappedError`), adds a real foreign position after graduation, snapshots the full-range bounds, and checks that later swaps and unauthorized removal attempts cannot change the locked position.

Normal verification uses `forge build` and `forge test`. To keep generated artifacts inside the disposable assignment directory and verify without network access:

```sh
forge build --offline --out test/scratch/out --cache-path test/scratch/cache
forge test --offline --out test/scratch/out --cache-path test/scratch/cache
```

Delete `test/scratch/` freely: no submitted test imports from it.
