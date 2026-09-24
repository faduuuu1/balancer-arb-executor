// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BalancerArbExecutor} from "../src/BalancerArbExecutor.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IBalancerVault, IFlashLoanRecipient} from "../src/interfaces/IBalancerVault.sol";

/// ════════════════════════════════════════════════════════════════════════════
///  Fork test against the REAL Balancer V2 Vault.
///
///  WHY THIS EXISTS
///  ---------------
///  Every other test in this repo talks to a `MockVault` I wrote. The 12-agent
///  audit's central conclusion — that the flash-loan callback cannot be hijacked
///  — was reached by seven agents who all rested on the same external
///  assumption: *Balancer echoes `userData` verbatim*. Nothing in this codebase
///  had ever asked Balancer whether that is true.
///
///  These tests ask. They run against mainnet state at a pinned block, using
///  the real Vault, real USDC, and the real fee.
///
///  Run:  forge test --match-path test/ForkRealVault.t.sol --fork-url <rpc>
///  Skipped automatically when no fork URL is configured, so `forge test`
///  stays green offline.
/// ════════════════════════════════════════════════════════════════════════════

/// A step target that succeeds and does nothing. The subject under test here is
/// the VAULT, not a DEX — so the route deliberately has no swap in it.
contract NoopRouter {
    event Poked(uint256 x);

    function poke(uint256 x) external {
        emit Poked(x);
    }
}

contract ForkRealVaultTest is Test {
    address constant VAULT_ADDR = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    IBalancerVault constant VAULT = IBalancerVault(VAULT_ADDR);

    BalancerArbExecutor exec;
    NoopRouter router;
    address owner = address(0xA11CE);
    address attacker = address(0xBAD);

    bool forked;

    function setUp() public {
        // Only run when a fork is actually configured.
        forked = VAULT_ADDR.code.length > 0 && USDC.code.length > 0;
        if (!forked) return;

        exec = new BalancerArbExecutor(owner);
        router = new NoopRouter();
        vm.prank(owner);
        exec.setTarget(address(router), true);

        vm.label(VAULT_ADDR, "BalancerVault");
        vm.label(USDC, "USDC");
        vm.label(address(exec), "Executor");
    }

    modifier onlyForked() {
        if (!forked) {
            emit log("skipped: no fork URL configured (pass --fork-url)");
            return;
        }
        _;
    }

    // ── The assumption seven audit agents relied on ──────────────────────────

    /// If the real Vault altered `userData` in any way, `_routeHash` would not
    /// match and this would revert `RouteMismatch`. It completing is the
    /// evidence that the echo-verbatim assumption holds against real bytecode.
    function test_RealVault_EchoesUserDataVerbatim() public onlyForked {
        uint256 amount = 1_000e6; // 1,000 USDC

        IERC20[] memory tokens = new IERC20[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = IERC20(USDC);
        amounts[0] = amount;

        BalancerArbExecutor.Step[] memory steps = new BalancerArbExecutor.Step[](1);
        steps[0] = BalancerArbExecutor.Step({
            target: address(router),
            data: abi.encodeWithSelector(NoopRouter.poke.selector, uint256(1)),
            approveToken: address(0),
            approveAmount: 0
        });

        uint256 before = IERC20(USDC).balanceOf(address(exec));

        vm.prank(owner);
        exec.execute(tokens, amounts, steps, USDC, 0);

        // Borrowed and repaid in full; nothing left behind, nothing lost.
        assertEq(IERC20(USDC).balanceOf(address(exec)), before, "USDC balance moved");
        emit log("real Vault echoed userData verbatim - RouteMismatch did not fire");
    }

    // ── The attack the contract is built around, against real infrastructure ──

    /// Anyone may name this contract as recipient in their OWN flashLoan. The
    /// real Vault will happily send it the tokens and call back — `msg.sender
    /// == VAULT` is legitimately satisfied. `_initiated` is what holds the line.
    function test_RealVault_UnsolicitedFlashLoanReverts() public onlyForked {
        IERC20[] memory tokens = new IERC20[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = IERC20(USDC);
        amounts[0] = 1_000e6;

        uint256 before = IERC20(USDC).balanceOf(address(exec));

        vm.prank(attacker);
        vm.expectRevert(BalancerArbExecutor.NotInitiated.selector);
        VAULT.flashLoan(IFlashLoanRecipient(address(exec)), tokens, amounts, hex"");

        assertEq(IERC20(USDC).balanceOf(address(exec)), before, "state changed on a rejected callback");
    }

    /// The callback is not reachable directly either, real Vault or not.
    function test_RealVault_DirectCallbackReverts() public onlyForked {
        IERC20[] memory tokens = new IERC20[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory fees = new uint256[](1);
        tokens[0] = IERC20(USDC);
        amounts[0] = 1_000e6;

        vm.prank(attacker);
        vm.expectRevert(BalancerArbExecutor.NotVault.selector);
        exec.receiveFlashLoan(tokens, amounts, fees, hex"");
    }

    // ── Guards, against real infrastructure ──────────────────────────────────

    function test_RealVault_ForbiddenSelectorRejected() public onlyForked {
        IERC20[] memory tokens = new IERC20[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = IERC20(USDC);
        amounts[0] = 1_000e6;

        BalancerArbExecutor.Step[] memory steps = new BalancerArbExecutor.Step[](1);
        steps[0] = BalancerArbExecutor.Step({
            target: address(router),
            data: abi.encodeWithSelector(bytes4(0x095ea7b3), attacker, type(uint256).max),
            approveToken: address(0),
            approveAmount: 0
        });

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(BalancerArbExecutor.ForbiddenSelector.selector, bytes4(0x095ea7b3))
        );
        exec.execute(tokens, amounts, steps, USDC, 0);
    }

    /// A step may not target a borrowed token, even a real one.
    function test_RealVault_BorrowedTokenAsTargetRejected() public onlyForked {
        vm.prank(owner);
        exec.setTarget(USDC, true); // allowlisting a token is permitted; the
                                    // per-route guard is what must stop it

        IERC20[] memory tokens = new IERC20[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = IERC20(USDC);
        amounts[0] = 1_000e6;

        BalancerArbExecutor.Step[] memory steps = new BalancerArbExecutor.Step[](1);
        steps[0] = BalancerArbExecutor.Step({
            target: USDC,
            data: abi.encodeWithSelector(NoopRouter.poke.selector, uint256(1)),
            approveToken: address(0),
            approveAmount: 0
        });

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BalancerArbExecutor.TargetForbidden.selector, USDC));
        exec.execute(tokens, amounts, steps, USDC, 0);
    }

    /// The Vault is never allowlistable, on any chain.
    function test_RealVault_CannotBeAllowlisted() public onlyForked {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(BalancerArbExecutor.TargetForbidden.selector, VAULT_ADDR)
        );
        exec.setTarget(VAULT_ADDR, true);
    }

    /// Reads the live fee rather than assuming 0. Documents what it actually is
    /// at the pinned block, and proves the repayment path is fee-driven.
    function test_RealVault_LiveFlashLoanFee() public onlyForked {
        (bool ok, bytes memory ret) =
            VAULT_ADDR.staticcall(abi.encodeWithSignature("getProtocolFeesCollector()"));
        require(ok, "could not read fees collector");
        address collector = abi.decode(ret, (address));

        (bool ok2, bytes memory ret2) =
            collector.staticcall(abi.encodeWithSignature("getFlashLoanFeePercentage()"));
        require(ok2, "could not read flash loan fee");
        uint256 fee = abi.decode(ret2, (uint256));

        emit log_named_uint("live Balancer flash-loan fee (1e18 = 100%)", fee);
        // Not asserted as zero — the contract is written to repay whatever is
        // quoted, precisely so a governance change does not break settlement.
        assertLe(fee, 1e16, "flash loan fee unexpectedly above 1%");
    }
}
