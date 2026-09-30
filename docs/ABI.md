# ABI and integration notes

Machine-readable ABI arrays in `docs/abi/<Contract>.json` are exported from Solidity 0.8.26 build output by `python3 tools/export_abis.py`. They include constructors, events, getters, and custom errors. See [README](../README.md) for economics, custody, address handoff and deployment ordering.

| Contract / entrypoint | Integration |
| --- | --- |
| `PvPadFactory.createLaunch(string,string)` | Exact launch fee; returns launch ID; default empty metadata and zero user salt |
| `createLaunch(string,string,bytes32)` | Fresh user salt to change token/pool address |
| `createLaunch(string,string,bytes32,string)` | Also records immutable metadata URI (up to 2048 bytes); JSON can hold image and socials |
| `launches(id)`, `launchMetadataURI(id)`, `getPoolKey(id)` | Read creator, token, curve, graduated flag, PoolId, metadata and canonical pool key |
| `LaunchCreated`, `LaunchMetadata`, `Graduated`, `LiquidityLocked` | Index by factory and launch ID, not token name/symbol |
| `BondingCurve.quoteBuy`, `quoteSell`, `maxBuyInput` | Quote current state; buy quote caps executable input at the remaining threshold capacity |
| `buy(address,uint256,uint256)` | Recipient, minimum token output, deadline; payable ETH input; excess refunded to caller |
| `sell(uint256,address,uint256,uint256)` | Token amount, ETH recipient, minimum ETH output, deadline; approve curve for exact token input first |
| `readyToGraduate`, `getReserves` | Progress from accounted net ETH; donations and pending fees do not count |
| `PvPadFactory.graduate(id)` | Permissionless, once threshold reached; no ETH supplied; permanently locks liquidity |
| `lockedLiquidity(id)`, `lockedTickLower(id)`, `lockedTickUpper(id)`, `LiquidityRangeLocked` | Actual factory-owned v4 position; salt `bytes32(id)`; saturated boundaries may move inward from full range |
| `PvPadHook.getHookPermissions`, `bindings` | Check flag layout and per-pool factory/escrow/creator binding |
| `KingOfThePad.claimKing(address)` | Beneficiary; payable value strictly exceeds current claimPrice; old king is not refunded |
| `FeeEscrow.pending(address(0),account)`, `withdraw(address(0),to)` | Read native credit; only credited caller may withdraw, to a chosen nonzero address; returns 0 if recipient rejects |
| `FeeEscrow.assignUnassigned()` | Anyone assigns pre-crown fees to permanently recorded first beneficiary |
| `BondingCurve.flushDeferredFees(beneficiary)` | Anyone retries deferred curve fees; returns success without changing ownership |
| `PvPadHook.retryDeferred(escrow,creator,beneficiary)` | Anyone retries hook fees; returns delivered amount, or 0 on failure/no fees |
| `WorkerSubsidy.fundWorkers()` | Donate native ETH to available worker pot |
| `setEpoch(bytes32,uint256,uint256)` | Updater-only root/start/end; reserves available pot for new monotonically increasing epoch |
| `claimWorker(uint256,address,uint256,bytes32[])` | Epoch/payee/amount/proof; may be relayed, payout always to payee |
| `recycleExpiredEpoch(uint256)` | Permissionless; unclaimed reserved budget returns to available pot only after expiry |
| `proposeUpdater`, `acceptUpdater` | Current updater nominates a nonzero replacement; nominee must accept |

The unprotected `buy(address)` and `sell(uint256,address)` convenience overloads retain upstream compatibility. Production UI calls should use minimum-output/deadline overloads. Deadlines are inclusive.

At exactly 4.2 ETH of accounted reserves, both curve trade directions revert `NotReady` until graduation (then `Graduated`). Both buy and sell quotes are zero. Submit permissionless `graduate(id)`; a failed graduation leaves the threshold state intact for retry. Index the selected LP ticks rather than assuming the extremes. `LiquidityRangeUnavailable` fails graduation atomically if no acceptable range containing the canonical price remains.

Escrow `authorizeRecorder` is callable only by the immutable factory; the factory exposes no public forwarding setter. Recording methods, including `recordTradeFeeNativeFor` and `recordTradeFeeNativeShares`, are internal integration surfaces for authorized curves/hook, not user deposits. Explicit-share recording preserves the sum of individual rounded halves during deferred retries.

Uniswap PoolManager swaps use the canonical `PoolKey`; ETH is currency0 and token currency1. Routers must settle hook-adjusted deltas, enforce minimum output or maximum input, and handle `PartialFill` on ETH-specified swaps. The hook fee is additional accounting at fee-tier 0, not an LP fee. Use a compatible router supplied and verified by deployment/frontend services; the vendored `PoolSwapTest` is a local test harness.

Genesis metadata is empty. Later metadata is untrusted creator content and immutable after creation; the frontend should render it as data, validate image/URI schemes, and use ordinary text rendering for names/symbols.

Custom-error selectors are part of the ABI. A failed curve slippage/deadline/transfer check and a failed graduation revert atomically. Worker duplicate, invalid, expired, over-budget, and failed-recipient claims do not consume the allocation. Deferred fees and worker budgets remain separate from curve reserves and locked liquidity.
