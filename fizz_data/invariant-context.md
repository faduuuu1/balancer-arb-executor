# INVARIANT_CONTEXT — BalancerArbExecutor

## What this protocol is

A **single-operator MEV arbitrage executor**, 138 nSLOC, one contract. The owner
borrows tokens from Balancer V2 at 0% fee, runs an owner-supplied sequence of
raw calls against an allowlist of routers, repays in the same transaction, and
keeps the difference. There are no users, no shares, no deposits, no
counterparties. The owner key is equivalent to the funds.

## ⚠️ This contract was fixed two days after it was audited

A 12-agent audit found 3 findings with 7 executable PoCs. **All are now fixed.**
The fixes are the newest and least-tested surface — that is where invariants are
most valuable. Do not re-derive the old bugs; derive properties for the code as
it stands now.

| Was | Now |
|---|---|
| Profit measured on ONE nominated token | A derived **watch set** — profit token + every borrowed token + every step's `approveToken` — each must be non-decreasing, with `minProfit` applied only to the profit token |
| `approveAmount == 0` meant "approve entire balance" | Sentinel is `APPROVE_ROUTE_PROCEEDS` (`type(uint256).max`) and grants only `balance - preLoan`; plain `0` approves nothing |
| Callback trusted `execute`'s validation | `_routeHash = keccak256(abi.encode(steps))` is set in `execute` and re-checked in the callback |
| Steps could call any allowlisted address | Steps may not use ERC20-mutating selectors (`approve`/`transfer`/`transferFrom`/`increaseAllowance`/`permit`) |
| `profitToken` could not be native ETH | `NATIVE` (address(0)) supported via `_balanceOf` |
| Codeless address read as transfer success | `_transfer`/`_approve` check `token.code.length` |
| No way to cancel a pending ownership transfer | `cancelPendingOwnership()` |

## AGGREGATE_VARIABLES

**There are none in the conventional sense.** No `totalSupply`, no `totalAssets`,
no accumulators. Do not invent them. The nearest equivalent is call-scoped:

- `address[] _watched` — every asset the current route may touch
- `mapping(address => uint256) _preLoan` — each watched asset's balance BEFORE
  the loan existed

Both are populated in `execute`, read in `receiveFlashLoan` (for approval
sizing) and in the final check, then **cleared before `execute` returns**. The
strongest conservation-shaped property here is that they are empty between
calls — leakage across calls would corrupt the next route's baseline.

## PAIRED_OPERATIONS

- `transferOwnership` / `acceptOwnership` / `cancelPendingOwnership`
- `setTarget(x, true)` / `setTarget(x, false)`
- `_approve(token, target, amt)` / `_approve(token, target, 0)` — same loop body
- Vault lends `amounts[i]` / contract repays `amounts[i] + feeAmounts[i]`
- `_watch(token)` populates / `_clearWatched()` empties

## CONVERSION_FUNCTIONS

**None.** There is no multiplication, no division, no fixed-point scaling and no
downcast anywhere in the contract. All rate math lives in opaque `Step.data`
payloads executed by external routers. Round-trip and rounding analysis has no
on-chain surface here — say so rather than manufacturing one.

## ACCESS_CONTROL

- `onlyOwner` — `execute`, `setTarget`, `setTargets`, `transferOwnership`,
  `cancelPendingOwnership`, `sweep`, `sweepNative`
- `msg.sender == pendingOwner` — `acceptOwnership`
- `msg.sender == address(VAULT)` **and** `_initiated` **and** `_routeHash` match
  — `receiveFlashLoan`
- `receive()` — unrestricted, empty

## STATE MACHINE

`_initiated` is the load-bearing flag. It is set ONLY in `execute` immediately
before `VAULT.flashLoan`, consumed as the first act of `receiveFlashLoan`, and
cleared again after `flashLoan` returns. Four separate audit agents attacked it
and none broke it. Properties asserting it is false between calls, and that
`_routeHash` is zero between calls, are high value.

## HARNESS FACTS

- `test/fizz/Base.sol` deploys 2 MockERC20s in ascending address order (the real
  Vault rejects unsorted token arrays), etches a `MockVault` at the hardcoded
  Balancer address `0xBA12222222228d8Ba445958a75a0704d566BF2C8`, deploys the
  executor with `admin` as owner, and allowlists three `MockRouter`s.
- The fuzzer drives routes through `balancerArbExecutor_execute_clamped` using
  scalars: `routeKind` (4 shapes incl. a two-token loan), `loanAmount`, and
  **`rate1`/`rate2` which move the router rates between 0.5x and 2.0x**. That
  rate movement is the adversary — it is how a route quoted at one price gets
  executed at another.
- `balancerArbExecutor_donate` transfers tokens into the executor, creating the
  standing-inventory state that the original bugs depended on.
- Ownership is genuinely transferable during a run: the secondary handler can
  hand it to an actor who then accepts. Any property about "the owner" must read
  `exec.owner()` at call time rather than assuming `admin`. A first fuzz run
  already produced a false violation from exactly this mistake.

## WHAT A GOOD PROPERTY LOOKS LIKE HERE

The contract's own claim is: *"the route was profitable"*. The audit's finding
was that it only enforced *"one nominated token's balance did not fall"*. The
gap between an advertised guarantee and an enforced one is where the bugs were,
and is where to look for more.
