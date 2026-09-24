> ## ⚠️ STALE — read this before trusting anything below
>
> This report describes the contract as it stood on **2026-08-29**, BEFORE the
> 12-agent audit findings were fixed on **2026-08-31**. Claims below that the
> fixes invalidated:
>
> | Stale claim | Current reality |
> |---|---|
> | Profit is measured on one nominated token (`I-5`) | Every watched asset — profit token, borrowed tokens, approved tokens — must be non-decreasing |
> | Callback re-validation is incomplete (`I-4`, On-chain=No) | Fixed. `_routeHash` binds the callback to the authorized route, and the borrowed-token check is re-run in the callback |
> | `approveAmount == 0` means "approve the full balance" | Sentinel is now `APPROVE_ROUTE_PROCEEDS`; `0` means approve nothing |
> | `profitToken` cannot be native ETH | `NATIVE` (address(0)) is supported in both snapshots |
> | Branch coverage 47.62% (10/21) | 54.55% (18/33) |
> | Verdict: FRAGILE | Unchanged — still no invariant/fuzz tests, which is what this fizz run addresses |
>
> **Derive invariants from the current source, not from this file.** It is kept
> for the threat model, entry-point map, and architecture, which are still valid.

# Invariant Map

> BalancerArbExecutor | 19 guards | 8 inferred | 3 not enforced on-chain

---

## 1. Enforced Guards (Reference)

Per-call preconditions. Heading IDs below (`G-N`) are anchor targets from x-ray.md attack surfaces.

#### G-1
`if (msg.sender != owner) revert NotOwner()` · `BalancerArbExecutor.sol:88` · Sole authority gate — every value-moving and configuration function routes through this modifier; the owner key is equivalent to the funds.

#### G-2
`if (initialOwner == address(0)) revert ZeroAddress()` · `BalancerArbExecutor.sol:93` · Prevents deploying an orphaned contract that could borrow but never be configured or swept.

#### G-3
`if (msg.sender != pendingOwner) revert NotOwner()` · `BalancerArbExecutor.sol:106` · Second half of the two-step handover — makes ownership transfer to a typo'd address recoverable, since an unclaimed `pendingOwner` never takes effect.

#### G-4
`if (target == address(0)) revert ZeroAddress()` · `BalancerArbExecutor.sol:118` · Keeps the zero address out of the allowlist, where it would make `address(0).call(data)` succeed silently as a no-op.

#### G-5
`if (target == address(VAULT)) revert TargetForbidden(target)` · `BalancerArbExecutor.sol:119` · Permanently bars the lender from the allowlist — an allowlisted Vault would let a route re-enter `flashLoan` or move the pending repayment.

#### G-6
`if (tokens.length != amounts.length) revert LengthMismatch()` · `BalancerArbExecutor.sol:144` · Guarantees the repayment loop at :216 can index both arrays; a short `amounts` would otherwise revert mid-settlement after the route had already run.

#### G-7
`if (steps.length == 0) revert NoSteps()` · `BalancerArbExecutor.sol:145` · Rejects a borrow with no route attached, which would pay gas to borrow and immediately repay.

#### G-8
`if (!allowedTarget[t]) revert TargetNotAllowed(t)` · `BalancerArbExecutor.sol:150` · Pre-flight arm of the allowlist — validates the whole route before any capital is borrowed.

#### G-9
`if (t == address(tokens[j])) revert TargetForbidden(t)` · `BalancerArbExecutor.sol:154` · Stops a step from calling a borrowed token directly, where a crafted `transferFrom` against a live approval would walk the loan out.

#### G-10
`if (balanceAfter < required) revert UnprofitableRoute(balanceAfter, required)` · `BalancerArbExecutor.sol:171` · The economic gate — enforces `minProfit` on-chain after settlement rather than trusting the caller's off-chain estimate.

#### G-11
`if (msg.sender != address(VAULT)) revert NotVault()` · `BalancerArbExecutor.sol:188` · Proves Balancer called the callback. Necessary but **not sufficient** — see G-12.

#### G-12
`if (!_initiated) revert NotInitiated()` · `BalancerArbExecutor.sol:190` · Proves *this contract* asked for the loan. Without it, any third party could call `VAULT.flashLoan(thisContract, …)` with their own `userData` and G-11 would still pass, executing an attacker's route with this contract's balances.

#### G-13
`if (!allowedTarget[s.target]) revert TargetNotAllowed(s.target)` · `BalancerArbExecutor.sol:200` · In-callback arm of the allowlist — re-validates rather than trusting the check made in the `execute` frame.

#### G-14
`if (!ok) revert StepFailed(i, ret)` · `BalancerArbExecutor.sol:210` · Unwinds the entire borrow when any hop fails, so a partially executed route can never settle.

#### G-15
`if (to == address(0)) revert ZeroAddress()` · `BalancerArbExecutor.sol:232` · Prevents sweeping accumulated profit into the burn address.

#### G-16
`if (to == address(0)) revert ZeroAddress()` · `BalancerArbExecutor.sol:242` · Same protection for the native-currency sweep path.

#### G-17
`if (!ok) revert TransferFailed()` · `BalancerArbExecutor.sol:246` · Surfaces a rejecting ETH recipient instead of silently reporting a successful sweep.

#### G-18
`if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed()` · `BalancerArbExecutor.sol:258` · Treats a no-return-data token (USDT and similar) as success while still catching an explicit `false` — required for the repayment loop to work with the most liquid pairs on-chain.

#### G-19
`if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert ApproveFailed()` · `BalancerArbExecutor.sol:266` · Same tolerance for approvals, so a failed approval cannot leave a step calling a router with no allowance.

---

## 2. Inferred Invariants (Single-Contract)

Inferred invariants are derived from structural analysis of the source code. Each block cites one of five extraction methods in its `Derivation` field.

---

#### I-1

`StateMachine` · On-chain: **Yes**

> `_initiated` is true only inside the window opened by `execute` at :160 and closed at :164, and only `execute` can open it.

**Derivation** — State-machine edge. Writes enumerated across the whole file: `_initiated = true` at :160 (inside `execute`, behind G-1), `_initiated = false` at :164 (post-`flashLoan`) and :191 (first act of the callback). No other write site exists. The :164 clear is defence in depth — it closes the window even if the Vault returns without invoking the callback.

**If violated** — G-12 becomes inert and the contract executes routes it did not author.

---

#### I-2

`Bound` · On-chain: **Yes**

> `allowedTarget[address(0)]` and `allowedTarget[address(VAULT)]` are always false.

**Derivation** — Guard lift from G-4 + G-5 at :118-119, then all write sites checked: `allowedTarget` is written at exactly one place, :120, immediately after both guards. `setTargets` at :124 delegates to the same `setTarget`, inheriting the guards.

**If violated** — a route could re-enter `flashLoan` mid-settlement, or burn a step against the zero address.

---

#### I-3

`Bound` · On-chain: **Yes**

> Every `target` called during a route is in `allowedTarget` at the moment of the call.

**Derivation** — Guard lift from G-8 (:150, pre-flight) and G-13 (:200, in-callback). Both arms present; the only call site that reaches an arbitrary address is :209, which sits inside the loop guarded by :200.

**If violated** — the owner's raw calldata could reach any address, making the allowlist decorative.

---

#### I-4

`Bound` · On-chain: **No**

> No route step targets a token that is being borrowed in the same call.

**Derivation** — Guard lift from G-9 at :154. Write/enforcement sites enumerated: the check exists **only** in `execute`'s pre-flight loop (:148-156). The callback's re-validation loop at :199-201 re-checks `allowedTarget` (G-13) but **not** the token-collision condition. The asymmetry contradicts the stated principle in the code's own comment at :197-199 ("a callback must never trust its input on the strength of a check made in another call frame").

Not reachable today: `steps` arrives back through Balancer's verbatim `userData` pass-through, and I-1 restricts the callback to routes this contract authored. The property therefore holds by construction — but by the construction of two other invariants, not by a check at the point of use.

**If violated** — a step could hold a live approval on a borrowed token and call `transferFrom` against it, draining the loan before the repayment loop at :216.

---

#### I-5

`Bound` · On-chain: **Yes**

> After a successful `execute`, `profitToken.balanceOf(this) >= balanceBefore + minProfit`.

**Derivation** — Guard lift from G-10 at :171, measured against the snapshot taken at :157 *before* `_initiated` is set and before the loan exists. Snapshot ordering matters and is correct: pre-loan, so the borrowed principal is never counted as profit.

**If violated** — a break-even or losing route settles and the operator pays gas for nothing.

---

#### I-6

`StateMachine` · On-chain: **Yes**

> `pendingOwner` is non-zero only between a `transferOwnership` and its matching `acceptOwnership`.

**Derivation** — State-machine edge: `pendingOwner = to` at :101 (behind G-1), consumed and reset at :108-109 behind G-3. No reverse path; a superseding `transferOwnership` overwrites rather than accumulating.

**If violated** — a stale pending address could claim ownership after the intended handover completed.

---

#### I-7

`Conservation` · On-chain: **Yes**

> No allowance granted to a route target survives the call that granted it.

**Derivation** — Δ-pair within the step loop: `_approve(s.approveToken, s.target, amt)` at :205 is paired with `_approve(s.approveToken, s.target, 0)` at :213 in the same loop body, gated on the same `approveToken != address(0)` condition. G-14 at :210 reverts the whole transaction on step failure, so the unwind covers the path where :213 is not reached.

**If violated** — a revoked or compromised router retains standing pull rights over the executor's balances.

---

#### I-8

`Conservation` · On-chain: **No**

> Only `profitToken` is accounted across a route; balances of every other token touched are untracked.

**Derivation** — Conservation-negative. `execute` snapshots exactly one balance (:157) and checks exactly one (:170). The repayment loop at :216 settles the borrowed set, but no Δ exists for intermediate assets a route may leave behind. Recoverable via `sweep` (:231), which is why this is an accounting gap rather than a loss.

**If violated** — nothing is stolen, but value can sit unnoticed in the contract and a route that "profited" in `profitToken` may have leaked value elsewhere.

---

**Categories:**
- **Conservation**: equal-and-opposite storage deltas in one function body.
- **Bound**: a guard lifted to a global property and checked across every write site.
- **Ratio**: a storage variable defined as a formula of others.
- **StateMachine**: discrete transitions with guards preventing reversal.
- **Temporal**: a condition depending on `block.timestamp` / `block.number`.

---

## 3. Inferred Invariants (Cross-Contract)

**None recorded.**

The template rule requires both the caller-side assumption *and* the callee-side write sites to sit inside the scope files. This codebase has exactly one in-scope contract; every counterparty — the Balancer Vault, the ERC20s, the allowlisted routers — is external. The strongest candidate (the executor transfers `amounts[i] + feeAmounts[i]` to the Vault at :216, and Balancer settles by balance rather than by allowance) has its callee side entirely out of scope, so it is recorded as a dependency in `x-ray.md` §2 instead of fabricated as an `X-N` block here.

---

## 4. Economic Invariants

---

#### E-1

On-chain: **Yes**

> A completed `execute` cannot leave the operator worse off in `profitToken` than they started, by more than gas.

**Follows from** — `I-5` + `I-1`

**If violated** — the contract becomes a gas-funded donation to routers and the Vault.

---

#### E-2

On-chain: **No**

> Total value held by the contract is non-decreasing across a route.

**Follows from** — `I-5` + `I-8`

**If violated** — a route clears its `profitToken` floor while net-losing value in a token nobody snapshotted. `sweep` recovers the residue, but only once someone notices it.
