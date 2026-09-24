// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BalancerArbExecutor} from "../src/BalancerArbExecutor.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IFlashLoanRecipient} from "../src/interfaces/IBalancerVault.sol";

/// Minimal ERC20 that returns no bool, like USDT — the executor must cope.
contract NoReturnToken {
    string public name = "NoReturn";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function transfer(address to, uint256 a) external {
        require(balanceOf[msg.sender] >= a, "bal");
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
    }

    function transferFrom(address f, address t, uint256 a) external {
        require(allowance[f][msg.sender] >= a, "allow");
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
    }

    function approve(address s, uint256 a) external {
        allowance[msg.sender][s] = a;
    }
}

/// Stands in for Balancer's Vault: hands over tokens, then demands them back.
contract MockVault {
    /// The executor probes this at construction to confirm it is really
    /// talking to Balancer and not to an unrelated contract that happens to
    /// occupy the address on this chain.
    function getProtocolFeesCollector() external pure returns (address) {
        return 0xce88686553686DA562CE7Cea497CE749DA109f9F;
    }
    bool public feeOn;

    function setFeeOn(bool v) external {
        feeOn = v;
    }

    function flashLoan(
        IFlashLoanRecipient recipient,
        IERC20[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external {
        uint256[] memory fees = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            fees[i] = feeOn ? amounts[i] / 1000 : 0;
            NoReturnToken(address(tokens[i])).transfer(address(recipient), amounts[i]);
        }

        uint256[] memory before = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            before[i] = NoReturnToken(address(tokens[i])).balanceOf(address(this));
        }

        recipient.receiveFlashLoan(tokens, amounts, fees, userData);

        for (uint256 i; i < tokens.length; ++i) {
            uint256 got = NoReturnToken(address(tokens[i])).balanceOf(address(this)) - before[i];
            require(got >= amounts[i] + fees[i], "FLASH_LOAN_NOT_REPAID");
        }
    }
}

/// A "DEX" that pays out a configurable rate, so a route can be made to profit
/// or to lose on demand.
contract MockRouter {
    NoReturnToken public immutable tokenIn;
    NoReturnToken public immutable tokenOut;
    uint256 public rateBps = 10_000; // 10_000 = 1:1

    constructor(NoReturnToken _in, NoReturnToken _out) {
        tokenIn = _in;
        tokenOut = _out;
    }

    function setRate(uint256 bps) external {
        rateBps = bps;
    }

    function swap(uint256 amountIn) external {
        tokenIn.transferFrom(msg.sender, address(this), amountIn);
        tokenOut.transfer(msg.sender, (amountIn * rateBps) / 10_000);
    }
}

contract BalancerArbExecutorTest is Test {
    // The executor hard-codes the real Vault address, so the mock is etched there.
    address constant VAULT_ADDR = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    BalancerArbExecutor exec;
    MockVault vault;
    NoReturnToken tokenA;
    MockRouter router;

    address owner = address(0xA11CE);
    address attacker = address(0xBAD);

    function setUp() public {
        tokenA = new NoReturnToken();

        MockVault impl = new MockVault();
        vm.etch(VAULT_ADDR, address(impl).code);
        vault = MockVault(VAULT_ADDR);

        exec = new BalancerArbExecutor(owner);

        router = new MockRouter(tokenA, tokenA);
        vm.prank(owner);
        exec.setTarget(address(router), true);

        tokenA.mint(VAULT_ADDR, 1_000_000e18);
        tokenA.mint(address(router), 1_000_000e18);
    }

    function _oneStep(uint256 amountIn) internal view returns (BalancerArbExecutor.Step[] memory s) {
        s = new BalancerArbExecutor.Step[](1);
        s[0] = BalancerArbExecutor.Step({
            target: address(router),
            data: abi.encodeWithSelector(MockRouter.swap.selector, amountIn),
            approveToken: address(tokenA),
            approveAmount: amountIn
        });
    }

    function _loan(uint256 amt)
        internal
        view
        returns (IERC20[] memory t, uint256[] memory a)
    {
        t = new IERC20[](1);
        a = new uint256[](1);
        t[0] = IERC20(address(tokenA));
        a[0] = amt;
    }

    // ── The attack this contract is shaped around ────────────────────────────

    /// An attacker naming us as recipient means `msg.sender == VAULT` is TRUE.
    /// Only the initiation flag stops the route from running.
    function test_RevertWhen_VaultCallsButWeDidNotInitiate() public {
        BalancerArbExecutor.Step[] memory steps = _oneStep(1e18);
        (IERC20[] memory t, uint256[] memory a) = _loan(1e18);

        vm.prank(attacker);
        vm.expectRevert(BalancerArbExecutor.NotInitiated.selector);
        vault.flashLoan(IFlashLoanRecipient(address(exec)), t, a, abi.encode(steps));
    }

    function test_RevertWhen_CallbackCalledDirectly() public {
        BalancerArbExecutor.Step[] memory steps = _oneStep(1e18);
        (IERC20[] memory t, uint256[] memory a) = _loan(1e18);
        uint256[] memory fees = new uint256[](1);

        vm.prank(attacker);
        vm.expectRevert(BalancerArbExecutor.NotVault.selector);
        exec.receiveFlashLoan(t, a, fees, abi.encode(steps));
    }

    // ── Access control ───────────────────────────────────────────────────────

    function test_RevertWhen_NonOwnerExecutes() public {
        BalancerArbExecutor.Step[] memory steps = _oneStep(1e18);
        (IERC20[] memory t, uint256[] memory a) = _loan(1e18);

        vm.prank(attacker);
        vm.expectRevert(BalancerArbExecutor.NotOwner.selector);
        exec.execute(t, a, steps, address(tokenA), 0);
    }

    function test_RevertWhen_TargetNotAllowed() public {
        BalancerArbExecutor.Step[] memory steps = _oneStep(1e18);
        steps[0].target = address(0xDEAD);
        (IERC20[] memory t, uint256[] memory a) = _loan(1e18);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(BalancerArbExecutor.TargetNotAllowed.selector, address(0xDEAD))
        );
        exec.execute(t, a, steps, address(tokenA), 0);
    }

    function test_RevertWhen_TargetIsTheVault() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(BalancerArbExecutor.TargetForbidden.selector, VAULT_ADDR)
        );
        exec.setTarget(VAULT_ADDR, true);
    }

    /// A borrowed token must never be a call target, or an approval walks out.
    function test_RevertWhen_TargetIsABorrowedToken() public {
        vm.prank(owner);
        exec.setTarget(address(tokenA), true);

        BalancerArbExecutor.Step[] memory steps = _oneStep(1e18);
        steps[0].target = address(tokenA);
        (IERC20[] memory t, uint256[] memory a) = _loan(1e18);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(BalancerArbExecutor.TargetForbidden.selector, address(tokenA))
        );
        exec.execute(t, a, steps, address(tokenA), 0);
    }

    // ── Economics ────────────────────────────────────────────────────────────

    function test_ProfitableRouteSucceeds() public {
        router.setRate(10_100); // +1%
        uint256 amt = 1000e18;

        vm.prank(owner);
        exec.execute(_t(), _a(amt), _oneStep(amt), address(tokenA), 1e18);

        assertGt(tokenA.balanceOf(address(exec)), 0, "profit should remain in the executor");
    }

    function test_RevertWhen_RouteLosesMoney() public {
        router.setRate(9_900); // -1%
        uint256 amt = 1000e18;

        vm.prank(owner);
        vm.expectRevert(); // repayment shortfall — the Vault rejects it
        exec.execute(_t(), _a(amt), _oneStep(amt), address(tokenA), 0);
    }

    /// Break-even must still fail when a floor is set: gas is not free.
    function test_RevertWhen_ProfitBelowMinProfit() public {
        router.setRate(10_000); // exactly 1:1
        uint256 amt = 1000e18;

        vm.prank(owner);
        vm.expectRevert();
        exec.execute(_t(), _a(amt), _oneStep(amt), address(tokenA), 1e18);
    }

    /// Balancer's fee is 0 today but governance can raise it; repayment must
    /// follow the quoted fee rather than assuming zero.
    function test_RepaysQuotedFeeWhenFeeIsOn() public {
        vault.setFeeOn(true);
        router.setRate(10_200);
        uint256 amt = 1000e18;

        vm.prank(owner);
        exec.execute(_t(), _a(amt), _oneStep(amt), address(tokenA), 1e18);

        assertGt(tokenA.balanceOf(address(exec)), 0);
    }

    // ── Housekeeping ─────────────────────────────────────────────────────────

    function test_NoStandingAllowanceAfterRoute() public {
        router.setRate(10_100);
        uint256 amt = 1000e18;

        vm.prank(owner);
        exec.execute(_t(), _a(amt), _oneStep(amt), address(tokenA), 1e18);

        assertEq(
            tokenA.allowance(address(exec), address(router)), 0, "allowance must be reset to 0"
        );
    }

    function test_SweepOnlyOwner() public {
        tokenA.mint(address(exec), 5e18);

        vm.prank(attacker);
        vm.expectRevert(BalancerArbExecutor.NotOwner.selector);
        exec.sweep(address(tokenA), attacker, 0);

        vm.prank(owner);
        exec.sweep(address(tokenA), owner, 0);
        assertEq(tokenA.balanceOf(owner), 5e18);
    }

    function test_TwoStepOwnershipTransfer() public {
        address next = address(0xC0FFEE);

        vm.prank(owner);
        exec.transferOwnership(next);
        assertEq(exec.owner(), owner, "owner must not change until accepted");

        vm.prank(attacker);
        vm.expectRevert(BalancerArbExecutor.NotOwner.selector);
        exec.acceptOwnership();

        vm.prank(next);
        exec.acceptOwnership();
        assertEq(exec.owner(), next);
    }

    // helpers
    function _t() internal view returns (IERC20[] memory t) {
        t = new IERC20[](1);
        t[0] = IERC20(address(tokenA));
    }

    function _a(uint256 amt) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = amt;
    }
}
