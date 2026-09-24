# Entry Point Map

> BalancerArbExecutor | 9 entry points | 0 permissionless | 2 role-gated | 6 admin-only | 1 fallback

---

## Protocol Flow Paths

### Setup (Owner)

`constructor(initialOwner)` → `setTarget()` / `setTargets()`  ◄── deploys with an empty allowlist; no route can run until at least one target is added

### Trade (Owner)

`[setup above]` → `execute()` → `VAULT.flashLoan()` → `receiveFlashLoan()` ◄── callback, Vault-only + self-initiated
                                                              ├─→ `target.call(step.data)` × N  ◄── each target must be allowlisted
                                                              └─→ `IERC20.transfer(VAULT, amount + fee)`  ◄── repayment, settled by balance
                              → profit check  ◄── `balanceAfter >= balanceBefore + minProfit`, else the whole tx reverts

### Recovery (Owner)

`[trade above]` → `sweep()`  ◄── profit accrues in the contract until swept
                → `sweepNative()`  ◄── for routers that return native currency

### Handover (Owner → Successor)

`transferOwnership(next)` → [`next` must call] → `acceptOwnership()`  ◄── owner is unchanged until accepted

---

## Permissionless

**None.**

Both functions carrying no access-control modifier were verified against their bodies and restrict the caller internally:

- `acceptOwnership()` — `if (msg.sender != pendingOwner) revert NotOwner()` at :106 → role-gated
- `receiveFlashLoan()` — `if (msg.sender != address(VAULT)) revert NotVault()` at :188 **and** `if (!_initiated) revert NotInitiated()` at :190 → role-gated

The only unrestricted surface is the empty `receive()` fallback (see Fallback below).

---

## Role-Gated

### `VAULT` (Balancer V2, `0xBA12…F2C8`)

#### `BalancerArbExecutor.receiveFlashLoan()`

| Aspect | Detail |
|--------|--------|
| Visibility | `external override`, no modifier — gated internally by :188 + :190 |
| Caller | Balancer V2 Vault only, and only while this contract's own `execute` is on the stack |
| Parameters | `tokens` (protocol-derived), `amounts` (protocol-derived), `feeAmounts` (protocol-derived), `userData` (protocol-derived — echoed verbatim from `execute`) |
| Call chain | `→ _approve() → IERC20.approve()` → `target.call(step.data)` → `_approve(…, 0)` → `_transfer() → IERC20.transfer(VAULT)` |
| State modified | `_initiated` (true → false, :191) |
| Value flow | Tokens: Vault → this contract (borrow), then this contract → Vault (repay + fee) |
| Reentrancy guard | No `nonReentrant`; `_initiated` is consumed at :191 before any external call, which closes the re-entry window |

### `pendingOwner`

#### `BalancerArbExecutor.acceptOwnership()`

| Aspect | Detail |
|--------|--------|
| Visibility | `external`, no modifier — gated internally by :106 |
| Caller | The address named by a prior `transferOwnership` |
| Parameters | none |
| Call chain | — (no external calls) |
| State modified | `owner`, `pendingOwner` |
| Value flow | None |
| Reentrancy guard | No — no external call to re-enter through |

---

## Admin-Only

All six are gated by `onlyOwner` (:88).

| Contract | Function | Parameters | State Modified |
|----------|----------|------------|----------------|
| BalancerArbExecutor | `execute()` | `tokens` (user-controlled), `amounts` (user-controlled), `steps` (user-controlled, raw calldata), `profitToken` (user-controlled), `minProfit` (user-controlled) | `_initiated`; token balances via the route |
| BalancerArbExecutor | `setTarget()` | `target` (user-controlled), `allowed` (user-controlled) | `allowedTarget[target]` |
| BalancerArbExecutor | `setTargets()` | `targets[]` (user-controlled), `allowed` (user-controlled) | `allowedTarget[…]` |
| BalancerArbExecutor | `transferOwnership()` | `to` (user-controlled) | `pendingOwner` |
| BalancerArbExecutor | `sweep()` | `token` (user-controlled), `to` (user-controlled), `amount` (user-controlled; `0` = full balance) | none — moves token balance out |
| BalancerArbExecutor | `sweepNative()` | `to` (user-controlled) | none — moves native balance out |

---

## Fallback

#### `BalancerArbExecutor.receive()`

| Aspect | Detail |
|--------|--------|
| Visibility | `external payable`, empty body (:250) |
| Caller | Anyone |
| Parameters | none (value only) |
| Call chain | — |
| State modified | none (native balance only) |
| Value flow | Native currency: anyone → this contract |
| Reentrancy guard | n/a — empty body, no external call |

Present so routers and wrapper contracts that refund native currency mid-route do not cause the step to revert. Recoverable via `sweepNative()`.

---

## Initialization

No proxy pattern. State is set in the `constructor` (:92-96), which assigns `owner` and emits `OwnershipTransferred`. The allowlist starts empty, so a freshly deployed instance can borrow but cannot call out anywhere until `setTarget` is used.
