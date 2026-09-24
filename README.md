# BalancerArbExecutor

Borrow from Balancer V2 at 0%, run a swap route, repay, keep the difference —
or revert.

**Status: written, not compiled, not audited, not deployed.**

---

## What it does not solve

A flash loan removes the *capital* constraint. It does not create a price
difference. Measurement in this project found:

| Test | Result |
|---|---|
| EVM same-chain DEX↔DEX, 568 venue-pairs | 0 directionally consistent |
| Solana same-slot, buy-vs-buy | direction random (44–55%) |
| Solana same-slot, direction-split | failed its own same-venue control |
| Realized MEV (11.4M executed arbs) | median **$0.043** Arbitrum, **$10.16** Ethereum |
| | 90.8% of Arbitrum arbs are under **$1** |
| | 43,025 / 41,877 competing searchers |

The median realized arbitrage on Ethereum does not clear the gas of a two-swap
route. The tail is real (p99 ≈ $6,250) and goes to whoever wins the priority-fee
auction. This contract does not make you faster.

Set `minProfit` accordingly. It is enforced on-chain precisely because
off-chain estimates were wrong every time they were checked.

## Layout

```
src/BalancerArbExecutor.sol      the executor
src/interfaces/                  IERC20, IBalancerVault
test/BalancerArbExecutor.t.sol   security + economics tests
script/Deploy.s.sol              deploys with NO targets allowlisted
```

## Security model

**The attack this is shaped around.** `receiveFlashLoan` is called *by the
Vault*, so `msg.sender == VAULT` proves only that Balancer called us — not that
we asked. Anyone may call `VAULT.flashLoan(thisContract, …)` naming this
contract as recipient with their own `userData`. Without a second check the
contract would execute an attacker's route using its own balances and
approvals. The `_initiated` flag is that check: only `execute()` sets it, and
the callback consumes it immediately. `test_RevertWhen_VaultCallsButWeDidNotInitiate`
covers it.

Also enforced:

- **Target allowlist**, re-checked inside the callback — a callback must not
  trust input on the strength of a check made in another call frame
- **The Vault can never be a target** (would allow re-entering `flashLoan`)
- **A borrowed token can never be a target** (an approval plus a crafted
  `transferFrom` walks the loan out)
- **Allowances reset to 0 after every step** — no standing approval survives
- **Profit checked after repayment**, in `execute`, against a pre-loan snapshot
- **Fee repaid as quoted**, not assumed 0 — governance can turn it on
- **Two-step ownership**, so a typo cannot orphan the contract
- **No-return-value ERC20s supported** (USDT and friends)

**What is *not* protected.** The owner supplies raw calldata per hop. That is
deliberate — routes change faster than contracts — but it means the owner can
make this contract call anything on an allowlisted target. This is a
single-operator tool; the owner key is equivalent to the funds.

## Build and test

Needs [Foundry](https://getfoundry.sh).

```bash
cd contracts && forge install foundry-rs/forge-std && forge build && forge test -vv
```

## Audit before deploying

The pashov skills are installed at `~/.claude/skills/` and apply directly:

```bash
run an x-ray on the codebase
```

then the 12-agent pass, then invariant fuzzing:

```bash
run the solidity auditor with all the different agents possible on src/BalancerArbExecutor.sol
```

```bash
run fizz on the codebase
```

## Deploying

Deploys with **no targets allowlisted** — it can borrow but cannot call out
anywhere, so a mistake in the script cannot move funds. Allowlist routers
afterwards, one at a time, checking each address on the explorer for that
chain.

```bash
forge script script/Deploy.s.sol:Deploy --rpc-url <url> --account <keystore-name> --broadcast --verify
```

Use a keystore or hardware wallet. Never put a private key in this repo, in
`.env`, or on the command line — shell history and `ps` both leak it.

Balancer V2 Vault, same address on every supported chain:
`0xBA12222222228d8Ba445958a75a0704d566BF2C8`
