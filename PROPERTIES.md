# PROPERTIES — BalancerArbExecutor

Synthesised from 5 parallel discovery agents (conservation, round-trip/rounding,
state-transition, adversarial, protocol-type). **53 raw properties → 18** after
dedup. The profit guard alone was proposed five times (CON-01, FL-04, RT-01,
ST-05, ADV-01) — merged into `SP-01`.

`SHOULD-HOLD` = explicitly guaranteed by the contract's own docs or an exact code
identity, with a citation. `EXPLORATORY` = inferred; a violation needs human
triage before it is called a bug.

Storage slots below were confirmed twice — once by me via
`forge inspect storage-layout`, once independently by the state-transition agent.

---

## Global properties

- [ ] **GL-01** · SHOULD-HOLD · Between any two top-level calls, all call-scoped
  state is neutral: `_initiated == false` (slot 3), `_routeHash == 0` (slot 4),
  `_watched.length == 0` (slot 5), and `_preLoan[t] == 0` (slot 6) for every
  token the harness can watch. Leakage would corrupt the next route's baseline
  or leave the callback armed.
  *Merged from CON-02, FL-03, ST-01, ST-02, ST-03, ST-04, ADV-04.*

- [ ] **GL-02** · SHOULD-HOLD · `allowedTarget[VAULT]` is always false.
  *Merged from ST-09, ADV-06.*

- [ ] **GL-03** · SHOULD-HOLD · `allowedTarget[address(0)]` is always false.
  *From ST-10.*

- [ ] **GL-04** · SHOULD-HOLD · `owner` is never `address(0)` — the contract can
  never become ownerless. *From VS-01.*

- [ ] **GL-05** · SHOULD-HOLD · No allowance from the executor to any router
  survives a call. The direct negative-space check for the
  "router is also a token" scenario. *From RT-02.*

- [ ] **GL-06** · SHOULD-HOLD · No non-owner call to **any** `onlyOwner` function
  succeeds — `execute`, `setTarget`, `setTargets`, `transferOwnership`,
  `cancelPendingOwnership`, `sweep`, `sweepNative`. Must read `exec.owner()` at
  call time, because ownership genuinely moves during a run.
  *Merged from ST-21, ADV-05. Widens the existing execute-only check.*
  **Needs a new handler.**

- [ ] **GL-07** · SHOULD-HOLD · An unsolicited flash loan — anyone naming this
  contract as recipient, or calling `receiveFlashLoan` directly — always reverts
  and changes nothing. *Merged from FL-02, ST-20, ADV-02.*
  **Needs a new handler.**

## Specific properties

- [ ] **SP-01** · SHOULD-HOLD · After a successful `execute`, every asset in the
  route's watch set ends at or above its pre-loan balance, and `profitToken`
  gained at least `minProfit`. Checked from **outside** the contract using real
  ERC20 balances, so a regression in the internal `_watched`/`_preLoan`
  bookkeeping surfaces as a genuine violation rather than being self-certified.
  *Merged from CON-01, FL-04, RT-01, ST-05, ADV-01. This is the property the
  whole rewrite exists for.*

- [ ] **SP-02** · SHOULD-HOLD · A step whose calldata begins with
  `approve`/`transfer`/`transferFrom`/`increaseAllowance`/`permit` is rejected
  with `ForbiddenSelector`. *Merged from FL-07, ADV-08.* **Needs a new route kind.**

- [ ] **SP-03** · SHOULD-HOLD · A step targeting a token borrowed in the same
  call is rejected with `TargetForbidden`, in both the pre-flight loop and the
  callback. *Merged from FL-06, ADV-07.* **Needs a new route kind.**

- [ ] **SP-04** · SHOULD-HOLD · Repayment transfers exactly
  `amounts[i] + feeAmounts[i]` using the fee the Vault **quoted**, not an assumed
  zero. *Merged from FL-01, ADV-10.* **Needs a `setVaultFee` handler — `feeBps`
  is currently always 0, so this is vacuous until then.**

- [ ] **SP-05** · SHOULD-HOLD · `APPROVE_ROUTE_PROCEEDS` grants exactly
  `balance - preLoan` (never standing inventory), a literal amount grants exactly
  that amount, and a literal `0` grants nothing. *Merged from FL-05, ADV-15.*
  **Needs router instrumentation — deferred.**

- [ ] **SP-06** · SHOULD-HOLD · `acceptOwnership` succeeds only for the current
  `pendingOwner`; on success `owner` becomes the caller and `pendingOwner` resets.
  *Merged from ST-14, ADV-12.*

- [ ] **SP-07** · SHOULD-HOLD · After `cancelPendingOwnership`, the previously
  nominated address can no longer accept. Verifies the cancel path delivers what
  its docstring claims. *Merged from ST-16, ADV-13.*

- [ ] **SP-08** · SHOULD-HOLD · `sweep` moves exactly the swept amount of exactly
  one token (`amount == 0` sweeps the full balance) and changes no other token,
  owner, or allowlist entry. *From ST-17.*

- [ ] **SP-09** · SHOULD-HOLD · `sweep(address(0), …)` always reverts with
  `UseSweepNative` — native currency leaves only via `sweepNative`. *From ST-18.*

- [ ] **SP-10** · SHOULD-HOLD · With `profitToken == NATIVE`, profit is measured
  against `address(exec).balance`. *From FL-09.* **Needs `profitSel % 3` and a
  router that pays ETH — deferred; this path is currently dark.**

- [ ] **SP-11** · SHOULD-HOLD · A malicious allowlisted router that re-enters
  `VAULT.flashLoan` mid-route hits `NotInitiated`, because the flag is consumed
  before any step runs. *From ADV-09.* **Needs a `MaliciousRouter` mock — deferred.**

---

## Deliberately dropped

Recorded so the reasoning isn't lost:

| Raw ID | Why dropped |
|---|---|
| CON-03 | The agent labelled it itself: tests MockERC20 plumbing, not the contract |
| FL-08 | `EXPLORATORY`; agent admitted the mid-call observability problem may make it unimplementable |
| ADV-03 | A sanity counter, not a failure signal |
| ADV-14 | Liveness check implemented as a state-changing "view"; low value for the awkwardness |
| ST-06/07/08/11/12/13/15/19, VS-02 | Baseline admin postconditions. Real but low yield — they catch only gross refactor errors while adding campaign cost to every run |
| ADV-11 | `EXPLORATORY`; needs a hostile token. **Kept as a documented design limit instead — see below** |

### ADV-11 as a documented limitation, not a property

The watch set is **derived from the route** (`profitToken` ∪ borrowed ∪ each
step's `approveToken`), not from the executor's holdings. Standing inventory in a
token the route never references is therefore outside the guard.

This is a deliberate tradeoff — watching all holdings would be unbounded — but it
is not stated in the contract's header, and it should be. Exploiting it requires
a token with a permissionless balance-moving function, which a single operator
would have to have routed through deliberately. Recorded rather than asserted.

---

## Harness gaps this synthesis surfaced

Independently flagged by multiple agents. A property over unreached code passes
vacuously, which is worse than no property.

| Gap | Flagged by | Blocks |
|---|---|---|
| `receiveFlashLoan` never attacked directly | protocol-type, state-transition, adversarial | GL-07 |
| Non-owner calls never attempted on 6 of 7 `onlyOwner` functions | state-transition, adversarial | GL-06 |
| `vault.setFeeBps` never called — fee always 0 | protocol-type, roundtrip, adversarial | SP-04 |
| `_buildRoute` only builds well-formed routes | protocol-type, adversarial | SP-02, SP-03 |
| `NATIVE` never a profit token; no router pays ETH | protocol-type, roundtrip | SP-10 |
| `MockRouter` doesn't record observed allowance | protocol-type, adversarial | SP-05 |
| No reentrant router mock | adversarial | SP-11 |
| No third token for unwatched-inventory tests | adversarial | ADV-11 |
