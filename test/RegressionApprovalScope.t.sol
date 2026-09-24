// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BalancerArbExecutor} from "../src/BalancerArbExecutor.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IFlashLoanRecipient} from "../src/interfaces/IBalancerVault.sol";
import {NoReturnToken, MockVault, MockRouter} from "./BalancerArbExecutor.t.sol";

/// Router that records the allowance it was granted at call time.
contract SpyRouter {
    NoReturnToken public immutable tokenIn;
    NoReturnToken public immutable tokenOut;
    uint256 public rateBps = 10_000;
    uint256 public seenAllowance;

    constructor(NoReturnToken _in, NoReturnToken _out) {
        tokenIn = _in;
        tokenOut = _out;
    }

    function setRate(uint256 bps) external {
        rateBps = bps;
    }

    function swap(uint256 amountIn) external {
        seenAllowance = tokenIn.allowance(msg.sender, address(this));
        tokenIn.transferFrom(msg.sender, address(this), amountIn);
        tokenOut.transfer(msg.sender, (amountIn * rateBps) / 10_000);
    }
}

contract RegressionApprovalScope is Test {
    address constant VAULT_ADDR = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    BalancerArbExecutor exec;
    MockVault vault;
    NoReturnToken tokenA; // "USDC" — the declared profitToken
    NoReturnToken tokenB; // "WETH" — the silently drained asset
    MockRouter routerA;
    MockRouter routerB;

    address owner = address(0xA11CE);

    event ArbExecuted(address indexed profitToken, uint256 profit, uint256 steps);

    function setUp() public {
        // Deploy until addresses are ascending, so `tokens` is sorted the way
        // the real Balancer Vault demands (UNSORTED_TOKENS otherwise).
        while (true) {
            NoReturnToken x = new NoReturnToken();
            NoReturnToken y = new NoReturnToken();
            if (address(x) < address(y)) {
                tokenA = x;
                tokenB = y;
                break;
            }
        }

        MockVault impl = new MockVault();
        vm.etch(VAULT_ADDR, address(impl).code);
        vault = MockVault(VAULT_ADDR);

        exec = new BalancerArbExecutor(owner);

        routerA = new MockRouter(tokenA, tokenA);
        routerB = new MockRouter(tokenB, tokenB);
        vm.startPrank(owner);
        exec.setTarget(address(routerA), true);
        exec.setTarget(address(routerB), true);
        vm.stopPrank();

        tokenA.mint(VAULT_ADDR, 1_000_000e18);
        tokenB.mint(VAULT_ADDR, 1_000_000e18);
        tokenA.mint(address(routerA), 1_000_000e18);
        tokenB.mint(address(routerB), 1_000_000e18);
    }

    // ── Regression guards ────────────────────────────────────────────────────
    // These began as exploit PoCs written by the audit agents; each PASSED,
    // proving a vulnerability. They now assert the fixes hold.

    /// WAS: a two-token loan where the profit check covered only one of them, so
    /// a loss on the other was invisible. NOW: every borrowed token is watched.
    function test_Regression_MultiTokenLossNowReverts() public {
        IERC20[] memory t = new IERC20[](2);
        uint256[] memory a = new uint256[](2);
        t[0] = IERC20(address(tokenA));
        t[1] = IERC20(address(tokenB));
        a[0] = 10e18;
        a[1] = 10e18;

        routerA.setRate(20_000); // A leg doubles  → +10 A
        routerB.setRate(0);      // B leg is a total loss → -10 B

        BalancerArbExecutor.Step[] memory s = new BalancerArbExecutor.Step[](2);
        s[0] = BalancerArbExecutor.Step({
            target: address(routerA),
            data: abi.encodeWithSelector(MockRouter.swap.selector, 10e18),
            approveToken: address(tokenA),
            approveAmount: 10e18
        });
        s[1] = BalancerArbExecutor.Step({
            target: address(routerB),
            data: abi.encodeWithSelector(MockRouter.swap.selector, 10e18),
            approveToken: address(tokenB),
            approveAmount: 10e18
        });

        vm.prank(owner);
        // tokenB is now watched, so its loss is caught instead of ignored.
        vm.expectRevert();
        exec.execute(t, a, s, address(tokenA), 1e18);
    }

    /// WAS: `approveAmount == 0` meant "approve my entire balance", so a 100
    /// loan against 500 of unswept profit granted a 600 allowance.
    /// NOW: the sentinel is APPROVE_ROUTE_PROCEEDS and grants only what the
    /// route itself produced — the standing 500 is never exposed.
    function test_Regression_SentinelApprovesRouteProceedsOnly() public {
        tokenB.mint(address(exec), 500e18); // unswept profit

        SpyRouter spy = new SpyRouter(tokenB, tokenB);
        tokenB.mint(address(spy), 1_000_000e18);
        spy.setRate(10_100);
        vm.prank(owner);
        exec.setTarget(address(spy), true);

        IERC20[] memory t = new IERC20[](1);
        t[0] = IERC20(address(tokenB));
        uint256[] memory a = new uint256[](1);
        a[0] = 100e18;

        BalancerArbExecutor.Step[] memory s = new BalancerArbExecutor.Step[](1);
        s[0] = BalancerArbExecutor.Step({
            target: address(spy),
            data: abi.encodeWithSelector(SpyRouter.swap.selector, 100e18),
            approveToken: address(tokenB),
            approveAmount: exec.APPROVE_ROUTE_PROCEEDS()
        });

        vm.prank(owner);
        exec.execute(t, a, s, address(tokenB), 1e18);

        emit log_named_decimal_uint("loan size        ", 100e18, 18);
        emit log_named_decimal_uint("allowance granted", spy.seenAllowance(), 18);
        assertEq(spy.seenAllowance(), 100e18, "only the loan, never the standing 500");
    }

    /// A plain `0` must now mean what every caller reads it as: approve nothing.
    function test_Regression_ZeroApproveAmountApprovesNothing() public {
        tokenB.mint(address(exec), 500e18);

        SpyRouter spy = new SpyRouter(tokenB, tokenB);
        tokenB.mint(address(spy), 1_000_000e18);
        spy.setRate(10_100);
        vm.prank(owner);
        exec.setTarget(address(spy), true);

        IERC20[] memory t = new IERC20[](1);
        t[0] = IERC20(address(tokenB));
        uint256[] memory a = new uint256[](1);
        a[0] = 100e18;

        BalancerArbExecutor.Step[] memory s = new BalancerArbExecutor.Step[](1);
        s[0] = BalancerArbExecutor.Step({
            target: address(spy),
            data: abi.encodeWithSelector(SpyRouter.swap.selector, 100e18),
            approveToken: address(tokenB),
            approveAmount: 0
        });

        vm.prank(owner);
        vm.expectRevert(); // the router's transferFrom finds no allowance
        exec.execute(t, a, s, address(tokenB), 1e18);
    }

    /// WAS: sweep() to a codeless "token" returned ok=true and emitted Swept
    /// while moving nothing. NOW: the helpers check for code first.
    function test_Regression_SweepOnCodelessAddressNowReverts() public {
        address ghost = address(0xDEADBEEF);
        assertEq(ghost.code.length, 0);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(BalancerArbExecutor.NotAContract.selector, ghost)
        );
        exec.sweep(ghost, owner, 1_000_000e18);
    }

    /// A step may not be the direct caller of an ERC20 mutation — an allowlisted
    /// address that is itself a token (a Uniswap V2 pair is its own LP token)
    /// could otherwise be handed an allowance that outlives the transaction.
    function test_Regression_StepCannotCallApproveDirectly() public {
        SpyRouter spy = new SpyRouter(tokenB, tokenB);
        vm.prank(owner);
        exec.setTarget(address(spy), true);

        IERC20[] memory t = new IERC20[](1);
        t[0] = IERC20(address(tokenA));
        uint256[] memory a = new uint256[](1);
        a[0] = 1e18;

        BalancerArbExecutor.Step[] memory s = new BalancerArbExecutor.Step[](1);
        s[0] = BalancerArbExecutor.Step({
            target: address(spy),
            data: abi.encodeWithSelector(bytes4(0x095ea7b3), address(0xBAD), type(uint256).max),
            approveToken: address(0),
            approveAmount: 0
        });

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(BalancerArbExecutor.ForbiddenSelector.selector, bytes4(0x095ea7b3))
        );
        exec.execute(t, a, s, address(tokenA), 0);
    }
}
