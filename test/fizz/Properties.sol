// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

pragma experimental ABIEncoderV2;

import {Snapshots} from "./Snapshots.sol";
import {PropertiesAsserts} from "./utils/PropertiesAsserts.sol";
import {vm} from "./utils/Hevm.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";

/// @notice Contains the functions that check the properties (invariants)
abstract contract Properties is PropertiesAsserts, Snapshots {
    // Storage slots of BalancerArbExecutor's private state. Confirmed twice
    // against `forge inspect storage-layout` — once by hand, once by an
    // independent discovery agent.
    //
    // A hardcoded slot breaks SILENTLY if the contract's fields are ever
    // reordered: the property would read the wrong slot and most likely pass
    // vacuously, which is the worst failure mode a test can have.
    // property_storageLayoutUnchanged() below is the guard against that.
    uint256 internal constant SLOT_INITIATED = 3;
    uint256 internal constant SLOT_ROUTE_HASH = 4;
    uint256 internal constant SLOT_WATCHED_LEN = 5;
    uint256 internal constant SLOT_PRELOAN_MAP = 6;

    // ―――――――――――――――――――― Global properties ―――――――――――――――――――――
    // These properties must always hold after any function call.
    // They MUST BE PUBLIC so that fuzzers can find and call them.

    /// GL-01 — every piece of call-scoped state is neutral between calls.
    /// Leakage would corrupt the next route's baseline (`_watched`/`_preLoan`)
    /// or leave the callback armed for an unrelated flash loan (`_initiated`,
    /// `_routeHash`).
    function property_callScopedStateIsNeutral() public returns (bool) {
        if (uint256(vm.load(address(exec), bytes32(SLOT_INITIATED))) & 0xff != 0) return false;
        if (vm.load(address(exec), bytes32(SLOT_ROUTE_HASH)) != bytes32(0)) return false;
        if (uint256(vm.load(address(exec), bytes32(SLOT_WATCHED_LEN))) != 0) return false;

        // A cleared array with a dirty backing mapping is the subtler failure:
        // length reads 0 and looks clean while a stale _preLoan entry poisons
        // the next route that touches that token.
        address[3] memory watchable = [address(tokenA), address(tokenB), address(0)];
        for (uint256 i; i < watchable.length; ++i) {
            bytes32 slot = keccak256(abi.encode(watchable[i], SLOT_PRELOAN_MAP));
            if (uint256(vm.load(address(exec), slot)) != 0) return false;
        }
        return true;
    }

    /// Guards GL-01 against silent breakage. `owner` is at slot 0 and is the
    /// only private-state neighbour we can read publicly; if the layout shifts,
    /// slot 0 stops matching `owner()` and this fails loudly instead of GL-01
    /// quietly reading garbage and passing.
    function property_storageLayoutUnchanged() public returns (bool) {
        address ownerFromSlot = address(uint160(uint256(vm.load(address(exec), bytes32(uint256(0))))));
        return ownerFromSlot == exec.owner();
    }

    /// GL-02 — the lender can never become a callable step target.
    function property_vaultNeverAllowlisted() public view returns (bool) {
        return !exec.allowedTarget(address(exec.VAULT()));
    }

    /// GL-03 — address(0) is also NATIVE, so this doubles as "NATIVE is never
    /// a call target".
    function property_zeroAddressNeverAllowlisted() public view returns (bool) {
        return !exec.allowedTarget(address(0));
    }

    /// GL-04 — the contract can never become ownerless.
    function property_ownerNeverZero() public view returns (bool) {
        return exec.owner() != address(0);
    }

    /// GL-05 — no allowance outlives the step that granted it. This is the
    /// direct negative-space check for the "an allowlisted address is itself a
    /// token" scenario the contract's trust model calls out.
    function property_noResidualApprovals() public view returns (bool) {
        address[3] memory routers = [address(routerAB), address(routerBA), address(routerAA)];
        for (uint256 i; i < routers.length; ++i) {
            if (IERC20(address(tokenA)).allowance(address(exec), routers[i]) != 0) return false;
            if (IERC20(address(tokenB)).allowance(address(exec), routers[i]) != 0) return false;
        }
        return true;
    }

    /// GL-06 — no non-owner call to ANY owner-gated function ever succeeds.
    /// Widened from the original execute-only check: six of the seven
    /// `onlyOwner` functions had no unauthorized-caller test at all.
    function property_onlyOwnerCanAdminister() public view returns (bool) {
        return !_nonOwnerCallSucceeded;
    }

    /// GL-07 — an unsolicited flash loan changes nothing. Anyone may name this
    /// contract as recipient in their own `VAULT.flashLoan`; `msg.sender ==
    /// VAULT` is satisfied legitimately in that case, so `_initiated` and
    /// `_routeHash` are what actually hold the line.
    function property_noUnsolicitedCallback() public view returns (bool) {
        return !_unsolicitedCallbackSucceeded;
    }

    // ――――――――――――――――――― Specific properties ――――――――――――――――――――
    // These properties must hold after specific function calls.
    // They MUST BE INTERNAL and called at the end of the relevant handlers.

    /// SP-01 — the property the whole rewrite exists for.
    ///
    /// Re-derives the guarantee from OUTSIDE the contract using real balances,
    /// rather than trusting `_watched`/`_preLoan`. If the internal bookkeeping
    /// regresses, that shows up here as a genuine violation instead of being
    /// self-certified by the same code that is broken.
    function _prop_watchSetNonDecreasing(address profitToken, uint256 minProfit) internal {
        gte(
            execBalance(address(tokenA)),
            stateBefore.execTokenA + (profitToken == address(tokenA) ? minProfit : 0),
            "SP-01: tokenA ended below its floor on a successful execute"
        );
        gte(
            execBalance(address(tokenB)),
            stateBefore.execTokenB + (profitToken == address(tokenB) ? minProfit : 0),
            "SP-01: tokenB ended below its floor on a successful execute"
        );
        gte(
            execBalance(address(0)),
            stateBefore.execNative,
            "SP-01: native balance decreased on a successful execute"
        );
    }

    /// SP-08 — sweep moves exactly one token, by exactly the swept amount.
    function _prop_sweepIsExact(address token, uint256 requested, uint256 balBefore) internal {
        uint256 swept = requested == 0 ? balBefore : requested;
        eq(execBalance(token), balBefore - swept, "SP-08: sweep moved the wrong amount");
    }
}
