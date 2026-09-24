// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

pragma experimental ABIEncoderV2;

import {Actor} from "./Actor.sol";
import {Clamp} from "./utils/Clamp.sol";
import {DecimalPrinter} from "./utils/DecimalPrinter.sol";
import {Deployer} from "./utils/Deployer.sol";
import {vm} from "./utils/Hevm.sol";
import {Logger} from "./utils/Logger.sol";
import {Math} from "./utils/Math.sol";
import {StringUtils} from "./utils/StringUtils.sol";
import {EnumerableSet} from "./utils/EnumerableSet.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {MockVault, MockRouter} from "./mocks/FuzzMocks.sol";
import {BalancerArbExecutor} from "../../src/BalancerArbExecutor.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";

/// @notice Base contract with state variables and setup functions
abstract contract Base is StringUtils, Clamp, Deployer, Math {
    using DecimalPrinter for uint256;

    string[] internal ACTOR_LABELS = ["Alice", "Bob", "Charlie"];
    uint256 internal constant BLOCK_INTERVAL = 12 seconds;
    uint256 internal constant INITIAL_ETH_BALANCE = 1_000 ether;
    uint256 internal constant INITIAL_TOKEN_BALANCE = 10_000;

    // ―――――――――――――――――――――――――― Ghosts ――――――――――――――――――――――――――

    struct Ghosts {
        uint256 _placeholder;
    }

    Ghosts internal ghosts;

    // Set when a non-owner call to ANY owner-gated function unexpectedly
    // succeeds. Widened from execute-only: six of the seven onlyOwner
    // functions previously had no unauthorized-caller test at all.
    bool internal _nonOwnerCallSucceeded;

    // Set when an unsolicited flash-loan callback gets through. Anyone can
    // name this contract as recipient in their own VAULT.flashLoan, so
    // msg.sender == VAULT is satisfied legitimately in that case.
    bool internal _unsolicitedCallbackSucceeded;

    // ―――――――――――――――――――――――――― Actors ――――――――――――――――――――――――――

    address[] internal actors;
    address internal actor;
    address internal admin;

    modifier asActor() virtual {
        vm.startPrank(actor);
        _;
        vm.stopPrank();
    }

    modifier asAdmin() virtual {
        vm.startPrank(admin);
        _;
        vm.stopPrank();
    }

    // ―――――――――――――――――――――――― Contracts ―――――――――――――――――――――――――

    // The address BalancerArbExecutor hardcodes as a constant. The mock Vault
    // has to occupy exactly this address, which is why setup uses etch.
    address internal constant VAULT_ADDR = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    BalancerArbExecutor public exec;
    MockVault public vault;

    // Deployed in ascending address order: the real Balancer Vault rejects an
    // unsorted token array (UNSORTED_TOKENS), so the harness must not generate
    // sequences the real thing would refuse.
    MockERC20 public tokenA;
    MockERC20 public tokenB;

    MockRouter public routerAB; // A to B
    MockRouter public routerBA; // B to A
    MockRouter public routerAA; // A to A, for single-token round trips

    uint256 internal constant SEED   = 1_000_000e18;
    uint256 internal constant SUPPLY = 10_000_000e18;

    // ―――――――――――――――――――――――――― Setup ―――――――――――――――――――――――――――

    function setup() internal {
        setupActors();
        deployTokens();
        deployVault();
        deployExecutor();
        seedLiquidity();
    }

    function deployTokens() internal {
        // MockERC20 mints only in its constructor, so the whole supply is
        // created here and distributed by seedLiquidity().
        while (true) {
            MockERC20 x = new MockERC20(address(this), SUPPLY, "TokenA", "A", 18);
            MockERC20 y = new MockERC20(address(this), SUPPLY, "TokenB", "B", 18);
            if (address(x) < address(y)) {
                tokenA = x;
                tokenB = y;
                break;
            }
        }
        vm.label(address(tokenA), "TokenA");
        vm.label(address(tokenB), "TokenB");
    }

    function deployVault() internal {
        MockVault impl = new MockVault();
        vm.etch(VAULT_ADDR, address(impl).code);
        vault = MockVault(VAULT_ADDR);
        vm.label(VAULT_ADDR, "BalancerVault");
    }

    function deployExecutor() internal {
        exec = new BalancerArbExecutor(admin);
        vm.label(address(exec), "Executor");

        routerAB = new MockRouter(address(tokenA), address(tokenB));
        routerBA = new MockRouter(address(tokenB), address(tokenA));
        routerAA = new MockRouter(address(tokenA), address(tokenA));

        vm.startPrank(admin);
        exec.setTarget(address(routerAB), true);
        exec.setTarget(address(routerBA), true);
        exec.setTarget(address(routerAA), true);
        vm.stopPrank();
    }

    function seedLiquidity() internal {
        // The Vault must hold what it lends.
        tokenA.transfer(VAULT_ADDR, SEED);
        tokenB.transfer(VAULT_ADDR, SEED);
        // Routers must hold what they pay out.
        tokenB.transfer(address(routerAB), SEED);
        tokenA.transfer(address(routerBA), SEED);
        tokenA.transfer(address(routerAA), SEED);
    }

    function setupActors() internal {
        admin = address(this);
        vm.label(admin, "Admin");

        for (uint256 i; i < ACTOR_LABELS.length; i++) {
            address _actor = address(new Actor{value: INITIAL_ETH_BALANCE}());
            actors.push(_actor);
            if (ACTOR_LABELS.length > i) {
                vm.label(_actor, ACTOR_LABELS[i]);
            }
        }
        actor = actors[0];
    }

    // ――――――――――――――――――――――――― Helpers ――――――――――――――――――――――――――

    /// Total holdings of a token across the executor — the quantity every
    /// conservation property is written against.
    function execBalance(address token) internal view returns (uint256) {
        return token == address(0) ? address(exec).balance : IERC20(token).balanceOf(address(exec));
    }

    // Maps an arbitrary address to an actor address
    function toActor(address addy) internal view returns (address) {
        return actors[uint256(uint160(addy)) % actors.length];
    }

    // Maps an arbitrary address to an actor address that is different from the current actor
    function toActorNotCurrent(address addy) internal view returns (address) {
        address _actor = actors[uint256(uint160(addy)) % actors.length];
        if (_actor == actor) {
            _actor = actors[(uint256(uint160(addy)) + 1) % actors.length];
        }
        return _actor;
    }

    // Sums the native token balances of all actors
    function sumActorsBalances() internal view returns (uint256 sumOfBalances) {
        for (uint256 i; i < actors.length; i++) {
            sumOfBalances += actors[i].balance;
        }
    }

    // Sums the ERC-20 token balances of all actors for a given token
    function sumActorsERC20Balances(address _token) internal view returns (uint256 sumOfBalances) {
        for (uint256 i; i < actors.length; i++) {
            bytes memory data = abi.encodeWithSignature("balanceOf(address)", actors[i]);
            (bool success, bytes memory result) = _token.staticcall(data);
            require(success, "sumActorsERC20Balances: failed to get balance");
            sumOfBalances += abi.decode(result, (uint256));
        }
    }

    function skipBlocks(uint256 blocks) internal {
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + blocks * BLOCK_INTERVAL);
    }

    function skipTime(uint256 time) internal {
        uint256 blocks = (time + BLOCK_INTERVAL - 1) / BLOCK_INTERVAL;
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + time);
    }
}
