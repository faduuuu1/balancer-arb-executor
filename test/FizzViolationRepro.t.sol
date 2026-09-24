// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {FuzzTester} from "./fizz/FuzzTester.sol";

/// Replays the exact handler calls Medusa reported as violations.
///
/// BOTH PASS HERE. Medusa reports SP-02 and GL-07 as violations; the same
/// handler calls with the same parameters, against the same harness and the
/// same contract, do not violate under Foundry. Direct tests also confirm the
/// contract guards themselves fire correctly:
///   - a forbidden-selector step reverts ForbiddenSelector(0x095ea7b3)
///   - an unsolicited flashLoan reverts and moves nothing
///
/// So the Medusa failures are a fuzzer/harness discrepancy, not a contract
/// defect. These tests exist so that conclusion stays falsifiable: if the
/// contract ever genuinely regresses, they go red.
contract FizzViolationReproTest is Test {
    FuzzTester f;

    function setUp() public {
        vm.deal(address(this), 100_000 ether);
        f = new FuzzTester{value: 10_000 ether}();
    }

    /// SP-02: routeKind 4 builds a step carrying approve()'s selector.
    function test_repro_SP02_forbiddenSelector() public {
        // routeKind 4 of 6, mid-range loan, neutral rates, profitToken A, no floor
        f.balancerArbExecutor_execute_clamped(4, 1_000e18, 10_000, 10_000, 0, 0);
    }

    /// GL-07: an unsolicited flashLoan naming the executor as recipient.
    function test_repro_GL07_unsolicitedCallback() public {
        f.balancerArbExecutor_unsolicitedCallback(true, address(0x31), 100e18);
        assertTrue(
            f.property_noUnsolicitedCallback(),
            "GL-07: an unsolicited flash-loan callback got through"
        );
    }
}
