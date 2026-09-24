// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";
import {IBalancerVault, IFlashLoanRecipient} from "./interfaces/IBalancerVault.sol";

/// ════════════════════════════════════════════════════════════════════════════
///  BalancerArbExecutor — borrow from Balancer, run a swap route, repay, keep
///  the difference. Reverts if there is no difference, in ANY asset it touched.
///
///  WHY A FLASH LOAN CHANGES LESS THAN IT LOOKS LIKE
///  ------------------------------------------------
///  Balancer V2 lends at 0% today, so this removes the capital constraint
///  entirely. It does not create a price difference. Every leg here still pays
///  a DEX fee and moves the pool against itself, and this contract competes for
///  the same block as everyone else running the same idea.
///
///  WHAT THE PROFIT GUARD ACTUALLY MEASURES
///  ----------------------------------------
///  The first version of this contract measured ONE nominated token and called
///  that "the route was profitable". A 12-agent audit proved that wrong with
///  seven executable PoCs: a route could gain 10 of the nominated token while
///  losing 10 of another, and the guard passed. Balancer's own repayment check
///  covers only the BORROWED set, so everything else was unguarded on both
///  sides.
///
///  It now watches every asset the route can touch — the profit token, every
///  borrowed token, and every token approved to a step — and requires each one
///  to be non-decreasing, with `minProfit` applied to the profit token. The
///  watch set is derived by the contract, not supplied by the caller, because
///  forgetting to list a token is exactly how the original bug happened.
///
///  THE BUG THIS CONTRACT IS SHAPED AROUND
///  ---------------------------------------
///  `receiveFlashLoan` is called BY THE VAULT, so `msg.sender == VAULT` proves
///  only that Balancer called us — not that WE asked it to. Anyone may call
///  `VAULT.flashLoan(thisContract, ...)` naming us as recipient with their own
///  `userData`. `_initiated` is the second check, and `_routeHash` is the third:
///  the callback now verifies the route it is about to run is byte-for-byte the
///  one `execute` authorized, rather than trusting a check made in another call
///  frame — which is what the comment here used to claim and only half deliver.
///
///  TRUST MODEL
///  -----------
///  The owner supplies raw calldata per hop. Targets are allowlisted, the Vault
///  and borrowed tokens can never be targets, and steps may not invoke ERC20
///  approval/transfer selectors — without that last rule an allowlisted address
///  that is itself a token (a Uniswap V2 pair IS its own LP token) could be
///  handed a standing allowance that outlives the transaction.
///
///  This is a single-operator tool. The owner key is equivalent to the funds.
///
///  GAS: the watch-set snapshot costs ~2 SSTOREs per touched token. That is
///  deliberate — correctness over gas — but it is significant against the
///  realized value of a typical arbitrage, and is the first thing to revisit
///  (transient storage, EIP-1153) if this is ever run in anger.
///
///  NOT DEPLOYED. Audited once by 12 agents; the findings from that audit are
///  fixed here, but a fix pass is not a re-audit. Re-run before funding.
/// ════════════════════════════════════════════════════════════════════════════
contract BalancerArbExecutor is IFlashLoanRecipient {
    /// @notice Balancer V2 Vault — identical address on every chain it supports.
    ///         Verified against Etherscan, Arbiscan, Basescan, Polygonscan and
    ///         Gnosisscan during audit.
    IBalancerVault public constant VAULT =
        IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    /// @notice Sentinel for `Step.approveAmount` meaning "everything this route
    ///         has produced in that token".
    /// @dev Deliberately NOT zero. The original sentinel was 0, which is also
    ///      the value every caller would naturally write to mean "approve
    ///      nothing" — an overload that read backwards at every call site.
    uint256 public constant APPROVE_ROUTE_PROCEEDS = type(uint256).max;

    /// @notice Native asset is addressed as the zero address in `profitToken`
    ///         and in the watch set.
    address public constant NATIVE = address(0);

    /// @notice One hop of the route: call `target` with `data`, having approved
    ///         `approveAmount` of `approveToken` to it first.
    struct Step {
        address target;
        bytes data;
        address approveToken;
        uint256 approveAmount;
    }

    address public owner;
    address public pendingOwner;

    /// @notice Contracts this executor is permitted to call during a route.
    mapping(address => bool) public allowedTarget;

    /// @dev Call-scoped. Set only by `execute`, consumed by `receiveFlashLoan`.
    bool private _initiated;
    /// @dev Call-scoped. Binds the callback's route to the authorized one.
    bytes32 private _routeHash;
    /// @dev Call-scoped. Every asset the route may touch, and its balance
    ///      before the loan existed. Cleared at the end of `execute`.
    address[] private _watched;
    mapping(address => uint256) private _preLoan;

    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);
    event OwnershipTransferCancelled(address indexed wasPending);
    event TargetAllowed(address indexed target, bool allowed);
    event ArbExecuted(address indexed profitToken, uint256 profit, uint256 steps);
    event Swept(address indexed token, address indexed to, uint256 amount);

    error NotOwner();
    error NotVault();
    error NotInitiated();
    error RouteMismatch();
    error TargetNotAllowed(address target);
    error TargetForbidden(address target);
    error ForbiddenSelector(bytes4 selector);
    error NoSteps();
    error NoTokens();
    error LengthMismatch();
    error UnprofitableRoute(address token, uint256 got, uint256 required);
    error StepFailed(uint256 index, bytes returnData);
    error TransferFailed();
    error ApproveFailed();
    error NotAContract(address target);
    error ZeroAddress();
    error VaultNotDeployed();
    error VaultNotBalancer();
    error UseSweepNative();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev Refuses to deploy anywhere the Vault address is not actually
    ///      Balancer.
    ///
    ///      `VAULT` is a constant, identical on every chain Balancer supports.
    ///      On chains where it is NOT deployed, that address is not empty — as
    ///      of 2026-09-01 it holds an unrelated ~1.5KB contract on Linea,
    ///      Scroll, Unichain and Berachain. Deploying there would let `execute`
    ///      arm `_initiated` and hand control to that contract, which could
    ///      then re-enter `receiveFlashLoan` with `msg.sender == VAULT` and the
    ///      flag both satisfied.
    ///
    ///      A code-length check alone does NOT catch this — those addresses
    ///      have code. The interface probe is what distinguishes them.
    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();

        if (address(VAULT).code.length == 0) revert VaultNotDeployed();
        (bool ok, bytes memory ret) =
            address(VAULT).staticcall(abi.encodeWithSignature("getProtocolFeesCollector()"));
        if (!ok || ret.length != 32) revert VaultNotBalancer();

        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    // ── Ownership (two-step, so a typo cannot orphan the contract) ───────────

    function transferOwnership(address to) external onlyOwner {
        pendingOwner = to;
        emit OwnershipTransferStarted(owner, to);
    }

    /// @notice Revoke a pending nomination.
    /// @dev Without this, a nomination could only be replaced, never withdrawn —
    ///      so correcting a mistaken or later-compromised nominee meant issuing
    ///      a second `transferOwnership` that the first nominee could front-run
    ///      with `acceptOwnership`. This is still front-runnable in the same
    ///      way; it exists so the intent to cancel is expressible at all.
    function cancelPendingOwnership() external onlyOwner {
        emit OwnershipTransferCancelled(pendingOwner);
        pendingOwner = address(0);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    // ── Target allowlist ─────────────────────────────────────────────────────

    /// @notice Permit or revoke a router/pool this executor may call.
    function setTarget(address target, bool allowed) public onlyOwner {
        if (target == address(0)) revert ZeroAddress();
        if (target == address(VAULT)) revert TargetForbidden(target);
        allowedTarget[target] = allowed;
        emit TargetAllowed(target, allowed);
    }

    function setTargets(address[] calldata targets, bool allowed) external onlyOwner {
        for (uint256 i; i < targets.length; ++i) setTarget(targets[i], allowed);
    }

    // ── The trade ────────────────────────────────────────────────────────────

    /// @notice Borrow `amounts` of `tokens`, run `steps`, repay, keep the rest.
    /// @param profitToken  the token `minProfit` is denominated in. Use
    ///                     `NATIVE` (the zero address) for the chain's native
    ///                     asset — routers that refund ETH are why `receive()`
    ///                     exists, and the original version could not measure it.
    /// @param minProfit    the smallest acceptable gain in `profitToken`. Every
    ///                     OTHER watched asset must merely not decrease.
    function execute(
        IERC20[] calldata tokens,
        uint256[] calldata amounts,
        Step[] calldata steps,
        address profitToken,
        uint256 minProfit
    ) external onlyOwner {
        if (tokens.length != amounts.length) revert LengthMismatch();
        // An empty borrow makes the Vault skip its own repayment check and makes
        // the borrowed-token guard below iterate zero times — an arbitrary-call
        // primitive wearing a flash loan's clothes.
        if (tokens.length == 0) revert NoTokens();
        if (steps.length == 0) revert NoSteps();

        for (uint256 i; i < steps.length; ++i) {
            address t = steps[i].target;
            if (!allowedTarget[t]) revert TargetNotAllowed(t);
            for (uint256 j; j < tokens.length; ++j) {
                if (t == address(tokens[j])) revert TargetForbidden(t);
            }
        }

        // Watch set, derived rather than caller-supplied.
        _watch(profitToken);
        for (uint256 j; j < tokens.length; ++j) _watch(address(tokens[j]));
        for (uint256 i; i < steps.length; ++i) {
            if (steps[i].approveToken != address(0)) _watch(steps[i].approveToken);
        }

        _routeHash = keccak256(abi.encode(steps));
        _initiated = true;
        VAULT.flashLoan(this, tokens, amounts, abi.encode(steps));
        // Cleared in the callback; reset here too so a Vault that returns
        // without calling back cannot leave the flag armed.
        _initiated = false;

        // Authoritative check, after repayment: what actually survived the round
        // trip, across every asset — not what one nominated token did.
        uint256 profit;
        for (uint256 i; i < _watched.length; ++i) {
            address t = _watched[i];
            uint256 need = _preLoan[t] + (t == profitToken ? minProfit : 0);
            uint256 got = _balanceOf(t);
            if (got < need) revert UnprofitableRoute(t, got, need);
            if (t == profitToken) profit = got - _preLoan[t];
        }

        _clearWatched();
        _routeHash = bytes32(0);

        emit ArbExecuted(profitToken, profit, steps.length);
    }

    /// @inheritdoc IFlashLoanRecipient
    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external override {
        // Proves Balancer called us.
        if (msg.sender != address(VAULT)) revert NotVault();
        // Proves WE asked it to.
        if (!_initiated) revert NotInitiated();
        // Proves this is the route we authorized — the check the old comment
        // claimed to make and did not.
        if (keccak256(userData) != _routeHash) revert RouteMismatch();
        _initiated = false;

        Step[] memory steps = abi.decode(userData, (Step[]));

        for (uint256 i; i < steps.length; ++i) {
            Step memory s = steps[i];
            if (!allowedTarget[s.target]) revert TargetNotAllowed(s.target);
            for (uint256 j; j < tokens.length; ++j) {
                if (s.target == address(tokens[j])) revert TargetForbidden(s.target);
            }
            _rejectTokenMutatingSelector(s.data);

            if (s.approveToken != address(0)) {
                _approve(s.approveToken, s.target, _approvableAmount(s));
            }

            (bool ok, bytes memory ret) = s.target.call(s.data);
            if (!ok) revert StepFailed(i, ret);

            if (s.approveToken != address(0)) _approve(s.approveToken, s.target, 0);
        }

        // Balancer settles by balance, so repayment is a transfer. The fee is
        // repaid as quoted rather than assumed 0, in case governance turns it on.
        for (uint256 i; i < tokens.length; ++i) {
            _transfer(address(tokens[i]), address(VAULT), amounts[i] + feeAmounts[i]);
        }
    }

    // ── Recovery ─────────────────────────────────────────────────────────────

    /// @notice Move an ERC20 balance out. Profit accrues here until swept.
    /// @dev The event precedes the transfer: a token with a transfer hook can
    ///      re-enter, and an event emitted afterwards can be reordered in ways
    ///      that mislead anything indexing these logs.
    function sweep(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(0)) revert UseSweepNative();
        uint256 amt = amount == 0 ? IERC20(token).balanceOf(address(this)) : amount;
        emit Swept(token, to, amt);
        _transfer(token, to, amt);
    }

    /// @notice Move native currency out, for routers that hand it back.
    function sweepNative(address payable to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = address(this).balance;
        emit Swept(address(0), to, bal);
        (bool ok, ) = to.call{value: bal}("");
        if (!ok) revert TransferFailed();
    }

    receive() external payable {}

    // ── Internals ────────────────────────────────────────────────────────────

    function _balanceOf(address token) private view returns (uint256) {
        return token == NATIVE ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    function _watch(address token) private {
        for (uint256 i; i < _watched.length; ++i) {
            if (_watched[i] == token) return;
        }
        _watched.push(token);
        _preLoan[token] = _balanceOf(token);
    }

    function _clearWatched() private {
        for (uint256 i; i < _watched.length; ++i) delete _preLoan[_watched[i]];
        delete _watched;
    }

    /// @dev "Route proceeds" is the balance ABOVE what was already here, so a
    ///      step is never handed a claim on standing inventory. This is the fix
    ///      for the PoC that granted a 600-unit allowance against a 100 loan.
    function _approvableAmount(Step memory s) private view returns (uint256) {
        if (s.approveAmount != APPROVE_ROUTE_PROCEEDS) return s.approveAmount;
        uint256 bal = _balanceOf(s.approveToken);
        uint256 pre = _preLoan[s.approveToken];
        return bal > pre ? bal - pre : 0;
    }

    /// @dev A step must never be the direct caller of an ERC20 mutation. The
    ///      allowlist bounds WHERE a step may call, never WHAT — and a Uniswap
    ///      V2 pair is simultaneously a valid swap target and its own LP token,
    ///      so "allowlisted" and "a token we hold" are not disjoint sets.
    ///      Routers pull via `transferFrom` using the allowance granted above;
    ///      none of them needs this contract to call these selectors directly.
    function _rejectTokenMutatingSelector(bytes memory data) private pure {
        if (data.length < 4) return;
        bytes4 sel = bytes4(data[0])
            | (bytes4(data[1]) >> 8)
            | (bytes4(data[2]) >> 16)
            | (bytes4(data[3]) >> 24);
        if (
            sel == 0x095ea7b3 // approve(address,uint256)
                || sel == 0xa9059cbb // transfer(address,uint256)
                || sel == 0x23b872dd // transferFrom(address,address,uint256)
                || sel == 0x39509351 // increaseAllowance(address,uint256)
                || sel == 0xd505accf // permit(address,address,uint256,...)
        ) revert ForbiddenSelector(sel);
    }

    // USDT and friends return no value from transfer/approve. Requiring a bool
    // would make this contract unable to trade the most liquid pairs on-chain.
    // The code-length check is what stops a codeless address from reading as
    // success — a raw `call` to one returns ok=true with empty returndata, which
    // is indistinguishable from a well-behaved no-return token.

    function _transfer(address token, address to, uint256 amount) private {
        if (token.code.length == 0) revert NotAContract(token);
        (bool ok, bytes memory ret) =
            token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    function _approve(address token, address spender, uint256 amount) private {
        if (token.code.length == 0) revert NotAContract(token);
        (bool ok, bytes memory ret) =
            token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, amount));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert ApproveFailed();
    }
}
