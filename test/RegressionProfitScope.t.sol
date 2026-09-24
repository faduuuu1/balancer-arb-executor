// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {BalancerArbExecutor} from "../src/BalancerArbExecutor.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IFlashLoanRecipient} from "../src/interfaces/IBalancerVault.sol";

contract Tkn {
    string public name;
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n) {
        name = n;
    }

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
        require(balanceOf[f] >= a, "bal");
        balanceOf[f] -= a;
        balanceOf[t] += a;
    }

    function approve(address s, uint256 a) external {
        allowance[msg.sender][s] = a;
    }
}

contract MockVault {
    /// The executor probes this at construction to confirm it is really
    /// talking to Balancer and not to an unrelated contract that happens to
    /// occupy the address on this chain.
    function getProtocolFeesCollector() external pure returns (address) {
        return 0xce88686553686DA562CE7Cea497CE749DA109f9F;
    }
    function flashLoan(
        IFlashLoanRecipient recipient,
        IERC20[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external {
        uint256[] memory fees = new uint256[](tokens.length);
        uint256[] memory pre = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            pre[i] = Tkn(address(tokens[i])).balanceOf(address(this));
            Tkn(address(tokens[i])).transfer(address(recipient), amounts[i]);
        }
        recipient.receiveFlashLoan(tokens, amounts, fees, userData);
        for (uint256 i; i < tokens.length; ++i) {
            require(
                Tkn(address(tokens[i])).balanceOf(address(this)) >= pre[i] + fees[i],
                "FLASH_LOAN_NOT_REPAID"
            );
        }
    }
}

/// tokenIn -> tokenOut at a rate the "market" (i.e. an attacker) can move.
contract Router {
    Tkn public immutable tin;
    Tkn public immutable tout;
    uint256 public rateBps = 10_000;

    constructor(Tkn a, Tkn b) {
        tin = a;
        tout = b;
    }

    function setRate(uint256 bps) external {
        rateBps = bps;
    }

    function swap(uint256 amountIn) external {
        tin.transferFrom(msg.sender, address(this), amountIn);
        tout.transfer(msg.sender, (amountIn * rateBps) / 10_000);
    }
}

contract RegressionProfitScope is Test {
    address constant VAULT_ADDR = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    BalancerArbExecutor exec;
    Tkn A; // borrowed token, e.g. WETH
    Tkn B; // profit token, e.g. some altcoin
    Router rAB;
    Router rBA;
    address owner = address(0xA11CE);

    function setUp() public {
        A = new Tkn("A");
        B = new Tkn("B");
        MockVault impl = new MockVault();
        vm.etch(VAULT_ADDR, address(impl).code);

        exec = new BalancerArbExecutor(owner);
        rAB = new Router(A, B);
        rBA = new Router(B, A);

        vm.startPrank(owner);
        exec.setTarget(address(rAB), true);
        exec.setTarget(address(rBA), true);
        vm.stopPrank();

        A.mint(VAULT_ADDR, 1_000_000e18);
        B.mint(address(rAB), 1_000_000e18);
        A.mint(address(rBA), 1_000_000e18);
    }

    function _steps(uint256 aIn, uint256 bIn)
        internal
        view
        returns (BalancerArbExecutor.Step[] memory s)
    {
        s = new BalancerArbExecutor.Step[](2);
        s[0] = BalancerArbExecutor.Step({
            target: address(rAB),
            data: abi.encodeWithSelector(Router.swap.selector, aIn),
            approveToken: address(A),
            approveAmount: aIn
        });
        s[1] = BalancerArbExecutor.Step({
            target: address(rBA),
            data: abi.encodeWithSelector(Router.swap.selector, bIn),
            approveToken: address(B),
            approveAmount: bIn
        });
    }

    function _loan(uint256 amt) internal view returns (IERC20[] memory t, uint256[] memory a) {
        t = new IERC20[](1);
        a = new uint256[](1);
        t[0] = IERC20(address(A));
        a[0] = amt;
    }


    // ── Regression guards ────────────────────────────────────────────────────
    // These began as exploit PoCs written by the audit agents. Each one used to
    // PASS, proving the vulnerability. They now assert the fix holds. If any of
    // them starts passing-as-exploit again, the profit guard has regressed.

    /// WAS: `test_ProfitGuardDoesNotProtectNonProfitToken` — the guard booked a
    /// B-denominated profit while 4 A of standing capital silently walked out.
    /// NOW: every watched asset must be non-decreasing, so the A leak reverts.
    function test_Regression_LossOnUnmeasuredAssetNowReverts() public {
        A.mint(address(exec), 10e18); // standing profit from an earlier arb

        rBA.setRate(10_000); // attacker moved the B->A leg against the owner

        (IERC20[] memory t, uint256[] memory amt) = _loan(100e18);
        vm.prank(owner);
        // A would end at 6e18 against a pre-loan 10e18 — caught now, not booked.
        vm.expectRevert(
            abi.encodeWithSelector(
                BalancerArbExecutor.UnprofitableRoute.selector, address(A), 6e18, 10e18
            )
        );
        exec.execute(t, amt, _steps(100e18, 96e18), address(B), 1e18);
    }

    /// The fix must DISCRIMINATE, not blanket-revert. At the rate the owner
    /// actually quoted, the same route is A-neutral and must still execute.
    function test_Regression_HonestRateStillSucceeds() public {
        A.mint(address(exec), 10e18);

        rBA.setRate(10_417); // the quote the owner routed against

        uint256 aBefore = A.balanceOf(address(exec));
        (IERC20[] memory t, uint256[] memory amt) = _loan(100e18);
        vm.prank(owner);
        exec.execute(t, amt, _steps(100e18, 96e18), address(B), 1e18);

        assertGe(A.balanceOf(address(exec)), aBefore, "A must not decrease");
        assertGe(B.balanceOf(address(exec)), 1e18, "B profit still booked");
    }

    /// Control, unchanged from the audit: with no standing balance the Vault's
    /// own repayment check is what stops the route. Its behaviour must not move
    /// when the contract's guard changes — that is what makes it a control.
    function test_Control_ZeroStandingBalanceReverts() public {
        rBA.setRate(10_000);
        (IERC20[] memory t, uint256[] memory amt) = _loan(100e18);
        vm.prank(owner);
        vm.expectRevert(); // FLASH_LOAN_NOT_REPAID
        exec.execute(t, amt, _steps(100e18, 96e18), address(B), 1e18);
    }
}
