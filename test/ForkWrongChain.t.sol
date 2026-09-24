// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BalancerArbExecutor} from "../src/BalancerArbExecutor.sol";

/// Deployment must FAIL on a chain where 0xBA12…F2C8 is not Balancer.
/// Run against Linea, where that address holds an unrelated ~1.5KB contract:
///   forge test --match-path test/ForkWrongChain.t.sol --fork-url https://rpc.linea.build
contract ForkWrongChainTest is Test {
    address constant VAULT_ADDR = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    function test_DeploymentRefusedWhenVaultIsNotBalancer() public {
        uint256 size = VAULT_ADDR.code.length;

        // Offline, or on a chain with the real Vault, there is nothing to prove.
        if (size == 0) {
            emit log("skipped: no fork URL configured (pass --fork-url)");
            return;
        }
        if (size > 20_000) {
            emit log("skipped: this chain has the real Balancer Vault");
            return;
        }
        emit log_named_uint("code at the Vault address on this chain", size);

        // Precondition: there IS code here, so a code-length check alone would
        // have passed and deployed anyway. That is the whole point.
        vm.expectRevert(BalancerArbExecutor.VaultNotBalancer.selector);
        new BalancerArbExecutor(address(0xA11CE));

        emit log("deployment correctly refused: VaultNotBalancer");
    }
}
