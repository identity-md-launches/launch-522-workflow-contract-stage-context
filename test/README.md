# Adversarial Foundry coverage

These tests extend the existing integration suite using the approved workflow and frozen economics in `SPEC.md`. All dependencies are already vendored. No RPC, fork, FFI, environment mutation, or generated file in `test/scratch/` is required.

| File | Properties and failure paths |
| --- | --- |
| `TokenInvariant.t.sol` | Independent holder/allowance ledgers for both fixed-supply tokens; random transfers, approvals, delegated spending, overspending and invalid recipients; full supply, one wei, zero, maximum approval and failed-spend rollback. |
| `AccountingInvariant.t.sol` | Independent worker deposit/payment ledger, overlapping Merkle epochs, claims, expiry recycling and updater rotation; fee entitlements across crowns, original beneficiaries, odd wei, failed withdrawals and recorder authorization. |
| `CurveInvariant.t.sol` | Multi-actor buy/sell sequences, reserve-product monotonicity, exact ETH/token conservation, donations excluded from reserves, deferred fee retries, captured beneficiaries, graduation finality and failed cap-refund rollback. |
| `HookInvariant.t.sol` | Two graduated pools using the real vendored Uniswap v4 PoolManager, all four swap modes, fees derived from actual ETH movement, failed delivery/retry, crown changes, withdrawals, supply conservation and unchanged factory-owned LP positions. |
| `FactoryAdversarial.t.sol` | Invalid configuration/fees/metadata, missing or unfunded launches, independent launches with repeated salts, and complete creation rollback followed by successful retry with identical inputs. |
| `WorkerAdversarial.t.sol` | Cross-epoch proof replay, overallocated-root budget isolation, window boundaries, superseded updaters, callback accounting and reentrancy, overlapping creator/king roles and explicit fee validation. |

Invariant handlers select bounded inputs and several actors, track independent expected balances or entitlements, and check them after each call. Expected failures assert their revert reasons; unexpected handler reverts fail the campaign. Deterministic sequences also exercise successful claims, recycling, deferred delivery and graduation so the important transitions do not rely solely on random selection.

Run counts live in Solidity inline configuration: 256 sequences of depth 64 for tokens, 128 of depth 64 for the worker/escrow/curve campaigns, and 128 of depth 48 for the real-pool campaign. Worker adversarial fuzz properties use 512 runs.

The curve invariant uses a minimal factory fixture to control escrow-recorder availability and exercise the authorized reserve sweep. The real-pool tests exercise actual factory deployment and locked graduation. Hook delivery failures and factory worker-payment failures are explicitly injected with Foundry mocks; this tests rollback and deferred accounting without claiming those failures arise naturally. Assertions of exact asset equality cover the holders and funding paths driven by each handler; unsolicited forced ETH is outside these campaigns.

Normal verification uses `forge build` and `forge test`. To keep generated artifacts inside the disposable assignment directory and verify without network access:

```sh
forge build --offline --out test/scratch/out --cache-path test/scratch/cache
forge test --offline --out test/scratch/out --cache-path test/scratch/cache
```

Delete `test/scratch/` freely: no submitted test imports from it.
