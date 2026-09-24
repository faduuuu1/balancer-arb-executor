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

# X-Ray Report

> BalancerArbExecutor | 164 nSLOC | no VCS (`untracked`) | Foundry | 29/08/26

---

## 1. Protocol Overview

**What it does:** Borrows a token from Balancer V2 at 0% fee, runs an owner-supplied sequence of DEX calls, repays the loan in the same transaction, and reverts unless a caller-specified profit floor is cleared.

- **Users**: A single operator. There is no user-facing surface — no deposits, no shares, no counterparties.
- **Core flow**: `execute()` borrows → route runs inside the Vault's callback → loan repaid → profit checked → residue accrues in the contract until `sweep()`.
- **Key mechanism**: Balancer V2 flash loan (`IFlashLoanRecipient`), settled by balance rather than allowance. Route steps are raw calldata against an owner-managed allowlist of routers.
- **Token model**: No token is issued. The contract transiently holds borrowed principal and permanently holds accrued profit until swept.
- **Admin model**: Single `owner` with two-step handover. No timelock, no multisig, no pause. The owner key is equivalent to the funds.

For a visual overview, see the [architecture diagram](architecture.svg) *(not generated — see §5 note)*.

### Contracts in Scope

| Subsystem | Key Contracts | nSLOC | Role |
|-----------|--------------|------:|------|
| Execution | BalancerArbExecutor | 138 | Borrows, routes, repays, enforces the profit floor, holds and releases residue |

Interfaces (`IERC20`, `IBalancerVault` — 26 nSLOC) are excluded as declaration-only.

### How It Fits Together

**The core trick:** the profit check happens *after* settlement, against a balance snapshot taken *before* the loan existed — so borrowed principal can never be mistaken for gain, and a losing route unwinds atomically instead of settling.

#### Borrow and route

```
Owner → BalancerArbExecutor.execute()
  ├─ validate every step: allowlist + not-a-borrowed-token      :148-156
  ├─ snapshot profitToken balance                               :157   ← pre-loan, the honest baseline
  ├─ _initiated = true                                          :160   ← the only place this opens
  └─ VAULT.flashLoan(this, tokens, amounts, abi.encode(steps))  :161
```

#### Inside the Vault's callback

```
Balancer Vault → BalancerArbExecutor.receiveFlashLoan()
  ├─ require msg.sender == VAULT                                :188   ← proves Balancer called
  ├─ require _initiated                                         :190   ← proves WE asked. load-bearing
  ├─ _initiated = false                                         :191   ← consumed before any external call
  ├─ for each step:
  │    ├─ approve(target, amount or full balance)               :205
  │    ├─ target.call(step.data)                                :209   ← arbitrary calldata, allowlisted target
  │    └─ approve(target, 0)                                    :213   ← no standing allowance survives
  └─ transfer(VAULT, amounts[i] + feeAmounts[i])                :216-218 ← fee as quoted, not assumed 0
```

#### Settle

```
back in execute()
  ├─ _initiated = false                                         :164   ← defence in depth if no callback fired
  ├─ balanceAfter = profitToken.balanceOf(this)                 :170
  └─ require balanceAfter >= balanceBefore + minProfit          :171   ← else the entire tx reverts
```

---

## 2. Threat & Trust Model

### Protocol Threat Profile

> Protocol classified as: **MEV / Arbitrage Executor** with **Flash-Loan Integrator** characteristics

Single-operator, no third-party funds, no shares or accounting for others. Signals: `IFlashLoanRecipient` implementation, an owner-managed target allowlist, raw-calldata route steps, and a post-settlement profit assertion. The adversary set is therefore unusual — the dominant threat is not a user attacking the protocol but a third party hijacking the callback, or the operator's own key.

### Actors & Adversary Model

| Actor | Trust Level | Capabilities |
|-------|-------------|-------------|
| Owner | Trusted (equivalent to the funds) | All 6 admin functions, instant, no timelock or pause: `execute` with arbitrary calldata against allowlisted targets, allowlist management, both sweeps, ownership handover. Two-step transfer protects the *seat*, not any operational action. |
| `pendingOwner` | Bounded (only after an owner-initiated transfer) | `acceptOwnership()` only. Cannot act until named, and the naming is `onlyOwner`. |
| Balancer V2 Vault | Trusted (immutable, out of scope) | Sole caller of `receiveFlashLoan`. Supplies `tokens`/`amounts`/`feeAmounts` and echoes `userData` verbatim. |
| Allowlisted routers | Bounded (owner-chosen, called with owner-chosen calldata) | Receive a transient approval and an arbitrary call during a route; approval is revoked at :213 in the same loop iteration. |

**Adversary Ranking**:

1. **Callback hijacker** — anyone can name this contract as recipient in their own `VAULT.flashLoan(...)`; the entire defence is one boolean.
2. **Compromised owner key** — no timelock, no pause, no second signer anywhere in the design.
3. **Malicious or compromised allowlisted router** — holds a live approval and receives control flow mid-route.
4. **MEV competitor** — not a security adversary but the economic one; sees the same opportunity and bids the same block.

See [entry-points.md](entry-points.md) for the full entry point map.

### Trust Boundaries

- **Owner ↔ contract** — no delay of any kind on operational actions; the two-step handover protects only the seat itself. Worst instant action: `sweep(token, attacker, 0)` at :231 empties any balance in one call.

- **Vault ↔ callback** — the only boundary a stranger can reach. `msg.sender == VAULT` (:188) is satisfiable by *anyone* who initiates a flash loan naming this contract; `_initiated` (:190) is what actually holds the line.

- **Contract ↔ allowlisted router** — the router is handed an approval at :205 and control flow at :209. The revoke at :213 bounds the window to a single loop iteration, but the router executes owner-authored calldata, so the boundary assumes owner competence, not router honesty.

### Key Attack Surfaces

- **Flash-loan callback authorisation** &nbsp;&#91;[G-12](invariants.md#g-12), [I-1](invariants.md#i-1)&#93; — `receiveFlashLoan:186-191` is reachable by any third party via their own `flashLoan` call, since `msg.sender` is legitimately the Vault. Worth confirming `_initiated` cannot be observed true by any path other than an in-flight `execute`.

- **Validation asymmetry between the two step loops** &nbsp;&#91;[I-4](invariants.md#i-4), [G-9](invariants.md#g-9), [G-13](invariants.md#g-13)&#93; — the pre-flight loop at :148-156 checks allowlist *and* borrowed-token collision; the callback loop at :199-201 re-checks only the allowlist. Worth tracing whether `userData` can reach :199 by any route other than the contract's own `execute`.

- **Arbitrary calldata against allowlisted targets** &nbsp;&#91;[I-3](invariants.md#i-3)&#93; — `s.target.call(s.data)` at :209 executes owner-authored bytes; the allowlist bounds *where*, never *what*. Worth confirming the allowlist is the intended and sufficient bound for the operator's threat model.

- **Owner powers without timelock, multisig, or pause** &nbsp;&#91;[G-1](invariants.md#g-1)&#93; — six instant functions at :88, two of which move balances out unconditionally. Worth deciding whether a single EOA is the intended custody model before funding.

- **Full-balance approval semantics** &nbsp;&#91;[I-7](invariants.md#i-7)&#93; — `approveAmount == 0` at :204 means "approve the entire current balance", an overload of zero that reads as "approve nothing". Worth checking every construction site of `Step` for the intended reading.

- **Single-token profit accounting** &nbsp;&#91;[I-8](invariants.md#i-8), [E-2](invariants.md#e-2)&#93; — `execute` snapshots one balance (:157) and checks one (:170); residue in other route assets is untracked. Worth confirming multi-asset routes cannot clear the floor while net-losing value.

### Upgrade Architecture Concerns

None. No proxy, no `initialize`, no storage gaps, no `delegatecall`. State is constructor-set (:92-96) and the deployed bytecode is final.

### Protocol-Type Concerns

**As a MEV / Arbitrage Executor:**
- `minProfit` (:171) is denominated in `profitToken` units and does not price gas; a route clearing a small floor can still lose money net of a priority-fee bid. The floor is a necessary condition, not a sufficient one.
- No deadline or block-number bound anywhere. A transaction stuck in the mempool can execute against a materially later market — the profit check protects the floor, but the *opportunity* it was sized against may be long gone.

**As a Flash-Loan Integrator:**
- `feeAmounts` is repaid as quoted (:217) rather than assumed zero, so a Balancer governance change to `getFlashLoanFeePercentage` degrades profitability instead of breaking settlement — the correct failure mode.
- Multi-token borrows are supported (`tokens[]`), but profit is asserted on one token only. The N-token borrow path is materially less covered than the single-token one.

### Temporal Risk Profile

**Deployment & Initialization:**
- Allowlist starts empty (no constructor seeding), so a fresh instance can borrow but cannot call out — a deliberately inert initial state, and the correct default.
- `constructor` takes `initialOwner` explicitly with a zero-check (:93), so a deploy script cannot orphan the contract.

### Composability & Dependency Risks

**Dependency Risk Map:**

> **Balancer V2 Vault** — via `BalancerArbExecutor:161, 186`
> - Assumes: `userData` is echoed to the callback verbatim; `feeAmounts` is authoritative; settlement is verified by balance delta, not allowance.
> - Validates: `msg.sender == VAULT` (:188) and `_initiated` (:190). The fee is read from the callback rather than assumed.
> - Mutability: Immutable contract; flash-loan fee is governance-settable.
> - On failure: Repayment shortfall reverts inside the Vault, unwinding the whole transaction.

> **Allowlisted routers** — via `BalancerArbExecutor:209`
> - Assumes: the call either performs the intended swap or reverts.
> - Validates: allowlist membership (:200) and success/failure (:210). Output amount is **not** validated per-step — only the aggregate profit at :171.
> - Mutability: Owner-settable at any time, instantly.
> - On failure: `StepFailed` reverts the entire route.

> **ERC20 tokens** — via `BalancerArbExecutor:257, 263`
> - Assumes: standard or no-return-data `transfer`/`approve` semantics.
> - Validates: success flag plus an optional boolean return (:258, :266).
> - Mutability: Arbitrary — any token the owner routes through.
> - On failure: `TransferFailed` / `ApproveFailed` reverts.

**Token Assumptions** *(unvalidated only)*:
- **Fee-on-transfer**: assumes the amount sent equals the amount received — the repayment at :217 transfers exactly `amounts[i] + feeAmounts[i]`, which arrives short. Impact: settlement reverts; the route is unusable rather than exploitable.
- **Rebasing**: assumes balances do not move independently of transfers, in the snapshot pair at :157/:170. Impact: profit measurement drifts.
- **Approval-race tokens (USDT-style)**: handled — every approval is reset to 0 at :213 before any subsequent raise.

---

## 3. Invariants

> ### 📋 Full invariant map: **[invariants.md](invariants.md)**
>
> A dedicated reference file contains the complete invariant analysis — do not look here for the catalog.
>
> - **19 Enforced Guards** (`G-1` … `G-19`) — per-call preconditions with `Check` / `Location` / `Purpose`
> - **8 Single-Contract Invariants** (`I-1` … `I-8`) — Conservation, Bound, StateMachine
> - **0 Cross-Contract Invariants** — only one contract is in scope; every counterparty is external, so no `X-N` block can cite both sides without fabrication
> - **2 Economic Invariants** (`E-1` … `E-2`) — derived from `I-5`, `I-1`, `I-8`
>
> Every inferred block cites a concrete Δ-pair, guard-lift + write-sites, or state edge. The **On-chain=No** blocks are the high-signal ones: `I-4` (validation asymmetry between the two step loops), `I-8` and `E-2` (single-token profit accounting).

---

## 4. Documentation Quality

| Aspect | Status | Notes |
|--------|--------|-------|
| README | Present | `contracts/README.md` — covers trust model, the callback attack, and deploy procedure |
| NatSpec | 3 annotations | `@notice`/`@dev` on public functions; the contract header carries a long prose rationale that NatSpec counts do not capture |
| Spec/Whitepaper | Missing | No formal spec |
| Inline Comments | Thorough | Comments state *why* rather than *what* — notably :189, :197-199, :215, :233 |

---

## 5. Test Analysis

| Metric | Value | Source |
|--------|-------|--------|
| Test files | 1 | File scan (always reliable) |
| Test functions | 13 | File scan (always reliable) |
| Line coverage | 84.93% (62/73) | `forge coverage` |
| Branch coverage | **47.62% (10/21)** | `forge coverage` |
| Statement coverage | 78.22% (79/101) | `forge coverage` |
| Function coverage | 69.23% (9/13) | `forge coverage` |

### Test Depth

| Category | Count | Contracts Covered |
|----------|-------|-------------------|
| Unit | 13 | BalancerArbExecutor (broad) |
| Integration | 0 | none — mocks only, no forked Vault |
| Fork | 0 | none |
| Stateless Fuzz | 0 | none |
| Stateful Fuzz (Foundry) | 0 | none |
| Stateful Fuzz (Echidna) | 0 | none |
| Stateful Fuzz (Medusa) | 0 | none |
| Formal Verification (Certora / Halmos / HEVM) | 0 | none |

### Gaps

- **Branch coverage at 47.62% is the headline gap** — under half the decision points are exercised. `I-4` (the validation asymmetry) and the multi-token borrow path are both in the unexercised half.
- **No stateful fuzzing.** For a contract whose central security property is a state-machine invariant (`I-1`: `_initiated` true only inside one window), invariant fuzzing is the directly applicable technique. This is the highest-value gap.
- **No fork test against the real Balancer Vault.** All 13 tests run against `MockVault`, which is a reimplementation of the settlement rule, not the rule itself. The assumption that `userData` is echoed verbatim — which `I-4`'s safety currently rests on — is asserted by the mock rather than verified against Balancer.
- **No multi-token borrow test.** `tokens[]`/`amounts[]` are exercised at length 1 only, while the repayment loop and `LengthMismatch` guard exist for N.
- **No fee-on-transfer or rebasing token test**, both listed as unvalidated assumptions in §2.
- **`architecture.svg` not generated** — the skill's SVG step requires a working `python3`; this machine resolves `python3` to the Windows Store alias stub. `architecture.json` is written and valid; run the generator after installing Python to produce the diagram.

---

## 6. Developer & Git History

> Repo shape: **no VCS** — `contracts/` is not inside a git repository, so no history, contributors, churn, or fix-commit signal exists to analyse.

The git security analysis script was skipped for the same reason (and `python3` is unavailable regardless). Every git-derived subsection of the standard report — Contributors, Review Signals, File Hotspots, Security-Relevant Commits, Dangerous Area Evolution, Forked Dependencies, Technical Debt Markers — is therefore **not applicable** rather than empty.

### Security Observations

- **No version control** — no review trail, no blame, no ability to detect late pre-audit changes. Initialising a repository before further work would restore all of the above.
- **Single forked dependency** — `lib/forge-std` is a clean upstream clone at depth 1, unmodified.
- **No TODO / FIXME / HACK markers** in source.

---

## X-Ray Verdict

**FRAGILE** — unit tests exist but nothing beyond them, and a single un-timelocked EOA holds every operational power over the funds.

**Structural facts:**
1. 164 nSLOC across one in-scope contract; 138 in `BalancerArbExecutor.sol`, 26 in declaration-only interfaces.
2. 9 entry points: **0 permissionless**, 2 role-gated (Vault, `pendingOwner`), 6 owner-only, 1 empty payable fallback.
3. 13 unit tests, 84.93% line and **47.62% branch** coverage; zero fuzz, invariant, fork, or formal-verification tests.
4. No proxy, no `delegatecall`, no timelock, no pause, no multisig; ownership is a single EOA with a two-step handover.
5. Not under version control, so no development history exists to analyse.
