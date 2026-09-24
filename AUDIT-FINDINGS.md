# 🔐 Security Review — BalancerArbExecutor

---

## Scope

|  |  |
| --- | --- |
| **Mode** | filename |
| **Files reviewed** | `src/BalancerArbExecutor.sol` (138 nSLOC) |
| **Agents** | **12 of 12 complete** — 2 opus, 10 sonnet |
| **Executable PoCs** | 7, all reproducing (`test/PoCAgent3.t.sol`, `test/PoCAgent4.t.sol`) |
| **Confidence threshold** | 80 |
| **Tool** | pashov `solidity-auditor` v3 |

Two agents ran on opus before the weekly limit; the remaining ten ran on sonnet
after the limit proved to be per model tier. Sonnet-only findings are marked.
One sonnet claim was **verified false** and rejected — see Rejected, below.

---

## Findings

[90] **1. Profit is measured in one token, so a route can lose value in every other asset and still pass**

`BalancerArbExecutor.execute` · Confidence: 90 · [agents: 3 + 7 PoCs]

**Description**
`execute` snapshots and checks only `profitToken` while Balancer's repayment check
covers only *borrowed* tokens, so any other asset the route touches is unmeasured
by both — and a third party manipulating the unmeasured leg can leave exactly
`minProfit` behind and take the rest.

Reproduced: `PoC1` shows `profitToken +10` against `tokenB −10` with the guard
passing. `MinProfitIsBlindToTheAttackedLeg` shows raising `minProfit` does not
defend. `Control_ZeroStandingBalanceReverts` is the control — with no second
asset in play the attack fails, so this is the mechanism and not a harness
artifact.

**Fix**

```diff
-        uint256 balanceBefore = IERC20(profitToken).balanceOf(address(this));
+        // Measure every asset the route can touch. The Vault guards only the
+        // borrowed set; anything else is unguarded on both sides.
+        address[] memory watched = _watchedTokens(steps, profitToken, tokens);
+        uint256[] memory before  = new uint256[](watched.length);
+        for (uint256 i; i < watched.length; ++i) {
+            before[i] = IERC20(watched[i]).balanceOf(address(this));
+        }
```
```diff
-        if (balanceAfter < required) revert UnprofitableRoute(balanceAfter, required);
+        for (uint256 i; i < watched.length; ++i) {
+            uint256 need = before[i] + (watched[i] == profitToken ? minProfit : 0);
+            uint256 got  = IERC20(watched[i]).balanceOf(address(this));
+            if (got < need) revert UnprofitableRoute(got, need);
+        }
```
---

[85] **2. `approveAmount == 0` sizes the allowance from the treasury, not the trade**

`BalancerArbExecutor.receiveFlashLoan` · Confidence: 85 · [agents: 3 + PoC]

**Description**
The sentinel resolves to `balanceOf(address(this))` — borrowed principal plus
every unswept profit — so an allowlisted router receives a live `transferFrom`
claim over the entire balance for the duration of its own call, and
`test_NoStandingAllowanceAfterRoute` cannot detect a theft that happens *during*
the step because it only asserts the post-route allowance.

Reproduced: `PoC3` logs `loan size 100.0` against `allowance granted 600.0`.

**Fix (Option A — cap to the route's own leg)**

```diff
-                uint256 amt = s.approveAmount == 0
-                    ? IERC20(s.approveToken).balanceOf(address(this))
-                    : s.approveAmount;
+                uint256 amt = s.approveAmount == type(uint256).max
+                    ? IERC20(s.approveToken).balanceOf(address(this)) - preLoanInventory[s.approveToken]
+                    : s.approveAmount;
```

**Fix (Option B — un-overload the sentinel)**

```diff
-                uint256 amt = s.approveAmount == 0
+                // 0 must mean "approve nothing" — the reading every caller expects.
+                uint256 amt = s.approveAmount == type(uint256).max
                     ? IERC20(s.approveToken).balanceOf(address(this))
                     : s.approveAmount;
```
---

[75] **3. Native ETH cannot be the profit token, forcing a vacuous floor on ETH routes**

`BalancerArbExecutor.execute` · Confidence: 75 · [agents: 1, opus]

**Description**
`IERC20(profitToken).balanceOf(...)` is unconditional, so `profitToken = address(0)`
reverts in the ABI decoder — yet `receive()` and `sweepNative()` exist precisely
because routers hand ETH back, so an ETH-denominated route must nominate an
untouched ERC20 where only `minProfit == 0` passes and the check returns the same
verdict whether the route netted 5 ETH or nothing.

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [90] | Profit measured in one token; other assets unguarded |
| 2 | [85] | `approveAmount == 0` approves the treasury, not the trade |
| 3 | [75] | Native ETH unmeasurable; ETH routes run a vacuous floor |

---

## Leads

_Not scored. High-signal trails where the exploit path could not be completed._

- ✅ **RESOLVED 2026-09-01 — fork-tested against the real Vault.** The fix (route hash) is in, and `test/ForkRealVault.t.sol::test_RealVault_EchoesUserDataVerbatim` confirms against real mainnet bytecode that Balancer echoes `userData` byte-for-byte — the external assumption all seven agents rested on. `test_RealVault_UnsolicitedFlashLoanReverts` confirms the real Vault delivers tokens and calls back, and `NotInitiated` fires. Original finding below.

- **Callback re-derives the route with no binding to what was authorized** —
  `receiveFlashLoan` — **[agents: 7]**. `execute` runs two per-step checks; the
  callback re-runs only the allowlist. `s.approveToken` / `s.approveAmount` are
  validated in neither frame. **All seven agents independently tried to exploit it
  and all seven failed**, citing the same reason: Balancer echoes `userData`
  verbatim, `flashLoan` is `nonReentrant`, `_initiated` gates entry. It holds — on
  external behaviour this contract never asserts. One-slot fix: store
  `keccak256(abi.encode(steps))` in `execute`, require it matches
  `keccak256(userData)` in the callback. Closes this, the unvalidated approve
  fields, and a hostile-Vault escalation, at the point of use.
- **Standing allowance via an allowlisted address that is itself an ERC20** —
  `execute` — [agents: 1, sonnet]. `TargetForbidden` bars only *currently borrowed*
  tokens, so a step can call `approve(attacker, max)` on any other allowlisted
  address that happens to be a token — and a Uniswap V2 pair **is** its own LP
  ERC20, which gas-optimised routes allowlist by design. The allowance **survives
  the transaction**. Demoted from FINDING at Gate 3: the step calldata is
  owner-supplied, so it needs a tricked or malicious owner (a route pasted from a
  compromised aggregator API would do it). Fix is cheap and closes the class —
  reject any step whose selector is `approve`/`transfer`/`transferFrom`/
  `increaseAllowance`/`permit`.
- **Codeless address reads as transfer success** — `_transfer` / `_approve` —
  [agents: 3 + PoC4]. Low-level `call` to an address with no code returns
  `ok == true, ret.length == 0`, and the USDT tolerance short-circuits to false.
  Owner-reachable only; the misleading `Swept` log is the harm. The helpers serve
  **three** call sites, so the `code.length` guard belongs in the helpers, not at
  `sweep` alone.
- **Native ETH is structurally unspendable in a route** — `receiveFlashLoan` —
  [agents: 2]. `Step` has no `value` field and `s.target.call(s.data)` always sends
  0 wei, so any leg requiring `msg.value` reverts. Same design gap as finding #3
  seen from the other side.
- **Two-step ownership has no cancel** — `transferOwnership` / `acceptOwnership` —
  [agents: 1, sonnet]. A nomination can only be replaced, never revoked, so a
  nominee whose key is later found compromised can front-run the correcting
  transaction with `acceptOwnership()`. Demoted at Gate 3 (the attacker is an
  owner-granted role). Fix: an explicit `cancelPendingOwnership()`.
- **Repayment trusts nominal amounts while the sibling path trusts live balance** —
  `receiveFlashLoan` — [agents: 2]. `_transfer(..., amounts[i] + feeAmounts[i])`
  never re-measures what actually arrived, while `approveAmount == 0` reads
  `balanceOf`. On a fee-on-transfer token the approve leg self-corrects and the
  repay leg cannot, so the route always reverts. Bounded to DoS.
- **No `tokens.length == 0` guard** — `execute` — [agents: 2]. `steps.length == 0`
  is guarded; `tokens.length` is not. Empty arrays make Balancer skip its
  repayment check and make the borrowed-token loop iterate zero times.
- **`transferOwnership` is the only address setter without a zero check** —
  [agents: 4, of which 3 explicitly cleared it]. `pendingOwner = address(0)` can
  never be accepted, so it degrades to an un-claimable cancel — the same pattern
  OpenZeppelin's `Ownable2Step` permits. Style note, not a defect. Recorded
  because four agents raised it: **frequency is not severity.**

---

## Rejected

- **Codeless `VAULT` silently no-ops `execute`** — [agents: 1, sonnet]. The claim
  was that solc ≥0.8.10 omits the `extcodesize` guard for void external calls, so
  a codeless Vault would make `execute` succeed while lending and doing nothing.
  **Verified false.** An isolated test under solc 0.8.24 returns:

  ```
  void  call to codeless addr: reverted
  value call to codeless addr: reverted
  ```

  The guard is dropped only when return data is *expected* — the ABI decoder then
  serves as the existence check. For void calls it is retained. A codeless Vault
  makes `execute` **revert**. The opus math-precision agent described this
  mechanism correctly; a sonnet agent inverted it.

---

## What held up

Attacked by name and not broken:

- **The callback hijack the contract is built around.** Four agents traced
  `_initiated` from different angles — a stranger naming the executor as
  `flashLoan` recipient, a transfer-hook re-entry during the Vault's delivery, an
  allowlisted router re-entering mid-route, a same-block race — and all four
  failed. The guard is consumed at the top of the callback before any external
  call, and `execute` clears it again after `flashLoan` returns.
- **`allowedTarget[VAULT]` and `allowedTarget[0]` are unreachable** — one write
  site, both guards immediately above it, `setTargets` delegating into it.
- **The profit snapshot ordering.** Pre-loan, so borrowed principal can never read
  as gain; an outside donation before the transaction raises both snapshots.
- **The Vault address.** Independently verified against Etherscan, Arbiscan,
  Basescan, Polygonscan and Gnosisscan, and the `receiveFlashLoan` signature
  checked field-for-field against Balancer's real interface.
- **No `delegatecall`, no assembly, no proxy, no storage gaps.** Every external
  call is a plain `.call`.
- **No multiplication or division anywhere.** All rate math lives in the opaque
  `Step.data` payloads, which is why the profit check is the only on-chain numeric
  guard — and why its single-token scope is the load-bearing defect.

> The invariant the contract advertises is "the route was profitable".
> The invariant it enforces is "one nominated token's balance did not fall."

---

## Executable proof

```
test/PoCAgent3.t.sol
  PoC1_MultiTokenLoan_LossOnNonProfitTokenPassesTheCheck
        tokenA (profitToken) gained: 10.0   tokenB LOST: 10.0   → guard passes
  PoC2_SingleTokenLoan_AccumulatedBalanceSilentlyDrained
        tokenA gained: 5.0   tokenB lost: 5.0
  PoC3_ZeroApproveAmountExposesAccumulatedProfit
        loan size: 100.0     allowance granted: 600.0
  PoC4_SweepOnCodelessAddressEmitsSweptAndMovesNothing

test/PoCAgent4.t.sol
  MinProfitIsBlindToTheAttackedLeg        raising the rate does not defend
  ProfitGuardDoesNotProtectNonProfitToken A 10.0→6.0 while B 0→4.0
  Control_ZeroStandingBalanceReverts      ← control: with no second asset, REVERTS
```

A passing PoC here is a **confirmed vulnerability**, not a green test. They are
excluded from the unit-test count in `server/flashloan-status.js` and surfaced as
their own inverted checklist row.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the
> complete absence of vulnerabilities and no guarantee of security is given. Team
> security reviews, bug bounty programs, and on-chain monitoring are strongly
> recommended. For a consultation regarding your projects' security, visit
> [https://www.pashov.com](https://www.pashov.com)
