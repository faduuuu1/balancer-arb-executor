// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

pragma experimental ABIEncoderV2;

import "../Base.sol";
import {Properties} from "../Properties.sol";
import {MockRouter} from "../mocks/FuzzMocks.sol";

/// @notice Drives BalancerArbExecutor.
///
/// The generated stub exposed `execute(IERC20[], uint256[], Step[], address,
/// uint256)` directly. A fuzzer cannot synthesise a meaningful `Step[]` — it
/// would produce garbage calldata against random targets, every call would die
/// in the allowlist check, and coverage would flatline while looking busy.
///
/// So routes are built here from scalars the fuzzer CAN explore. `rate1`/`rate2`
/// are the adversarial lever: the owner quotes a route against one rate and the
/// fuzzer executes it against another, which is the sandwich the audit's PoCs
/// modelled by hand.
///
/// Route kinds 4 and 5 are deliberately malformed. Five discovery agents
/// independently flagged that the original `_buildRoute` only ever produced
/// well-formed routes, leaving `ForbiddenSelector` and `TargetForbidden` —
/// two of the newest security fixes — completely unexercised.
abstract contract BalancerArbExecutorHandler is Properties {
    uint256 internal constant RATE_MIN = 5_000; // 0.5x — heavy loss
    uint256 internal constant RATE_MAX = 20_000; // 2.0x — heavy gain

    uint8 internal constant ROUTE_KINDS = 6;

    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    function balancerArbExecutor_execute_clamped(
        uint8 routeKind,
        uint256 loanAmount,
        uint256 rate1,
        uint256 rate2,
        uint8 profitSel,
        uint256 minProfit
    ) public {
        routeKind = uint8(routeKind % ROUTE_KINDS);
        loanAmount = clampBetween(loanAmount, 1e18, 100_000e18);
        rate1 = clampBetween(rate1, RATE_MIN, RATE_MAX);
        rate2 = clampBetween(rate2, RATE_MIN, RATE_MAX);
        minProfit = clampBetween(minProfit, 0, 10e18);

        routerAB.setRate(rate1);
        routerBA.setRate(rate2);
        routerAA.setRate(rate1);

        (IERC20[] memory loanTokens, uint256[] memory loanAmounts, BalancerArbExecutor.Step[] memory s) =
            _buildRoute(routeKind, loanAmount);

        address profitToken = (profitSel % 2 == 0) ? address(tokenA) : address(tokenB);

        snapshotBefore();

        vm.startPrank(admin);
        try exec.execute(loanTokens, loanAmounts, s, profitToken, minProfit) {
            // SP-02 / SP-03: the malformed routes must never reach here.
            if (routeKind == 4) t(false, "SP-02: a forbidden selector step succeeded");
            if (routeKind == 5) t(false, "SP-03: a step targeting a borrowed token succeeded");
            // SP-01: the property the rewrite exists for.
            _prop_watchSetNonDecreasing(profitToken, minProfit);
        } catch {}
        vm.stopPrank();
    }

    /// GL-06 — attempt every owner-gated function as a non-owner.
    function balancerArbExecutor_onlyOwner_unauthorized(uint8 fnSel, address who, uint256 arg, bool flag)
        public
    {
        address caller = toActor(who);
        // Ownership genuinely moves during a run, so read it at call time.
        // Assuming `admin` stays owner produced a false violation on the first
        // fuzz run of this suite.
        if (caller == exec.owner()) return;

        bool ok;
        vm.startPrank(caller);
        uint8 sel = uint8(fnSel % 7);
        if (sel == 0) {
            IERC20[] memory loanTokens = new IERC20[](1);
            uint256[] memory loanAmounts = new uint256[](1);
            loanTokens[0] = IERC20(address(tokenA));
            loanAmounts[0] = 1e18;
            BalancerArbExecutor.Step[] memory s = new BalancerArbExecutor.Step[](1);
            s[0] = BalancerArbExecutor.Step({
                target: address(routerAA),
                data: abi.encodeWithSelector(MockRouter.swap.selector, 1e18),
                approveToken: address(tokenA),
                approveAmount: 1e18
            });
            try exec.execute(loanTokens, loanAmounts, s, address(tokenA), 0) { ok = true; } catch {}
        } else if (sel == 1) {
            try exec.setTarget(address(routerAB), flag) { ok = true; } catch {}
        } else if (sel == 2) {
            address[] memory arr = new address[](1);
            arr[0] = address(routerAB);
            try exec.setTargets(arr, flag) { ok = true; } catch {}
        } else if (sel == 3) {
            try exec.transferOwnership(caller) { ok = true; } catch {}
        } else if (sel == 4) {
            try exec.cancelPendingOwnership() { ok = true; } catch {}
        } else if (sel == 5) {
            try exec.sweep(address(tokenA), caller, arg) { ok = true; } catch {}
        } else {
            try exec.sweepNative(payable(caller)) { ok = true; } catch {}
        }
        vm.stopPrank();

        if (ok) _nonOwnerCallSucceeded = true;
    }

    /// GL-07 — an unsolicited flash loan. Two shapes: calling the callback
    /// directly (blocked by `NotVault`), and getting the Vault itself to call
    /// it while no `execute` is in flight (blocked by `NotInitiated`). The
    /// second is the one that matters — `msg.sender == VAULT` is legitimately
    /// satisfied there.
    function balancerArbExecutor_unsolicitedCallback(bool viaVault, address who, uint256 amount)
        public
    {
        IERC20[] memory loanTokens = new IERC20[](1);
        uint256[] memory loanAmounts = new uint256[](1);
        uint256[] memory f = new uint256[](1);
        loanTokens[0] = IERC20(address(tokenA));
        loanAmounts[0] = clampBetween(amount, 1e18, 1_000e18);

        if (viaVault) {
            address[] memory raw = new address[](1);
            raw[0] = address(tokenA);
            vm.startPrank(toActor(who));
            try vault.flashLoan(address(exec), raw, loanAmounts, "") { _unsolicitedCallbackSucceeded = true; }
            catch {}
            vm.stopPrank();
        } else {
            vm.startPrank(toActor(who));
            try exec.receiveFlashLoan(loanTokens, loanAmounts, f, "") { _unsolicitedCallbackSucceeded = true; } catch {}
            vm.stopPrank();
        }
    }

    /// SP-04 — the fee lever. Three agents independently flagged that no handler
    /// ever moved it, so `feeAmounts[i]` was always zero and the
    /// "repay the fee AS QUOTED" guarantee was vacuous.
    function balancerArbExecutor_setVaultFee(uint256 bps) public {
        vault.setFeeBps(clampBetween(bps, 0, 100)); // the mock caps at 1%
    }

    function balancerArbExecutor_sweep_clamped(uint8 tokenSel, address to, uint256 amount)
        public
    {
        address token = (tokenSel % 2 == 0) ? address(tokenA) : address(tokenB);
        to = toActor(to);
        amount = clampBetween(amount, 0, 1_000e18);
        uint256 balBefore = execBalance(token);

        vm.startPrank(admin);
        try exec.sweep(token, to, amount) {
            _prop_sweepIsExact(token, amount, balBefore);
        } catch {}
        vm.stopPrank();
    }

    /// SP-09 — native currency leaves only via sweepNative.
    function balancerArbExecutor_sweepZeroTokenReverts(address to, uint256 amount) public {
        vm.startPrank(admin);
        try exec.sweep(address(0), toActor(to), amount) {
            t(false, "SP-09: sweep(address(0)) must revert with UseSweepNative");
        } catch {}
        vm.stopPrank();
    }

    function balancerArbExecutor_sweepNative_clamped(address to) public {
        to = toActor(to);
        vm.startPrank(admin);
        // solhint-disable-next-line no-empty-blocks
        try exec.sweepNative(payable(to)) {} catch {}
        vm.stopPrank();
    }

    function balancerArbExecutor_secondary(uint8 selector, address arg0, bool arg1) public {
        selector = uint8(selector % 5);
        vm.startPrank(admin);
        if (selector == 0) {
            // solhint-disable-next-line no-empty-blocks
            try exec.transferOwnership(toActor(arg0)) {} catch {}
        } else if (selector == 1) {
            address wasPending = exec.pendingOwner();
            try exec.cancelPendingOwnership() {
                vm.stopPrank();
                // SP-07: a cancelled nominee must no longer be able to accept.
                if (wasPending != address(0)) {
                    vm.startPrank(wasPending);
                    try exec.acceptOwnership() {
                        t(false, "SP-07: a cancelled nominee still became owner");
                    } catch {}
                    vm.stopPrank();
                }
                return;
            } catch {}
        } else if (selector == 2) {
            // solhint-disable-next-line no-empty-blocks
            try exec.setTarget(address(routerAB), arg1) {} catch {}
        } else if (selector == 3) {
            // solhint-disable-next-line no-empty-blocks
            try exec.setTarget(address(routerBA), arg1) {} catch {}
        } else {
            // solhint-disable-next-line no-empty-blocks
            try exec.setTarget(address(routerAA), arg1) {} catch {}
        }
        vm.stopPrank();
    }

    /// SP-06 — acceptOwnership succeeds only for the current pendingOwner.
    function balancerArbExecutor_acceptOwnership(address who) public {
        address caller = toActor(who);
        address pendingBefore = exec.pendingOwner();

        vm.startPrank(caller);
        try exec.acceptOwnership() {
            t(caller == pendingBefore, "SP-06: acceptOwnership succeeded for a non-pendingOwner");
            t(exec.owner() == caller, "SP-06: owner did not become the accepting caller");
            t(exec.pendingOwner() == address(0), "SP-06: pendingOwner was not reset");
        } catch {}
        vm.stopPrank();
    }

    /// Unowned value arriving mid-life — the standing-inventory state the
    /// original bugs depended on.
    function balancerArbExecutor_donate(uint8 tokenSel, uint256 amount) public {
        amount = clampBetween(amount, 0, 1_000e18);
        if (tokenSel % 2 == 0) tokenA.transfer(address(exec), amount);
        else tokenB.transfer(address(exec), amount);
    }

    // ―――――――――――――――――――――― Route construction ―――――――――――――――――――

    function _buildRoute(uint8 routeKind, uint256 loanAmount)
        internal
        view
        returns (IERC20[] memory loanTokens, uint256[] memory loanAmounts, BalancerArbExecutor.Step[] memory s)
    {
        if (routeKind == 2) {
            // Two-token loan — the shape PoC1 exploited, where a loss on the
            // unmeasured token used to pass the profit guard.
            loanTokens = new IERC20[](2);
            loanAmounts = new uint256[](2);
            loanTokens[0] = IERC20(address(tokenA));
            loanTokens[1] = IERC20(address(tokenB));
            loanAmounts[0] = loanAmount;
            loanAmounts[1] = loanAmount;

            s = new BalancerArbExecutor.Step[](2);
            s[0] = _step(address(routerAA), loanAmount, address(tokenA), loanAmount);
            s[1] = _step(address(routerBA), loanAmount, address(tokenB), loanAmount);
            return (loanTokens, loanAmounts, s);
        }

        loanTokens = new IERC20[](1);
        loanAmounts = new uint256[](1);
        loanTokens[0] = IERC20(address(tokenA));
        loanAmounts[0] = loanAmount;

        if (routeKind == 0) {
            s = new BalancerArbExecutor.Step[](1);
            s[0] = _step(address(routerAA), loanAmount, address(tokenA), loanAmount);
        } else if (routeKind == 1) {
            s = new BalancerArbExecutor.Step[](2);
            s[0] = _step(address(routerAB), loanAmount, address(tokenA), loanAmount);
            s[1] = _step(address(routerBA), loanAmount / 2, address(tokenB), loanAmount / 2);
        } else if (routeKind == 3) {
            // The sentinel path — approve what the route produced, not the
            // whole balance. The fixed replacement for approveAmount == 0.
            s = new BalancerArbExecutor.Step[](1);
            s[0] = BalancerArbExecutor.Step({
                target: address(routerAA),
                data: abi.encodeWithSelector(MockRouter.swap.selector, loanAmount),
                approveToken: address(tokenA),
                approveAmount: type(uint256).max // APPROVE_ROUTE_PROCEEDS
            });
        } else if (routeKind == 4) {
            // MALFORMED: an ERC20-mutating selector. Must hit ForbiddenSelector.
            s = new BalancerArbExecutor.Step[](1);
            s[0] = BalancerArbExecutor.Step({
                target: address(routerAA),
                data: abi.encodeWithSelector(bytes4(0x095ea7b3), address(0xBAD), type(uint256).max),
                approveToken: address(0),
                approveAmount: 0
            });
        } else {
            // MALFORMED: target is a borrowed token. Must hit TargetForbidden.
            s = new BalancerArbExecutor.Step[](1);
            s[0] = BalancerArbExecutor.Step({
                target: address(tokenA),
                data: abi.encodeWithSelector(MockRouter.swap.selector, loanAmount),
                approveToken: address(tokenA),
                approveAmount: loanAmount
            });
        }
    }

    function _step(address target, uint256 amountIn, address approveToken, uint256 approveAmount)
        private
        pure
        returns (BalancerArbExecutor.Step memory)
    {
        return BalancerArbExecutor.Step({
            target: target,
            data: abi.encodeWithSelector(MockRouter.swap.selector, amountIn),
            approveToken: approveToken,
            approveAmount: approveAmount
        });
    }
}
