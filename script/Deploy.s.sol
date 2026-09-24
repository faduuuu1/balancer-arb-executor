// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {BalancerArbExecutor} from "../src/BalancerArbExecutor.sol";

/// @notice Deploys the executor with NO targets allowlisted.
///
/// @dev Deliberately does not allowlist anything. A freshly deployed executor
///      can borrow but cannot call out anywhere, so a mistake in this script
///      cannot move funds. You allowlist routers afterwards, one at a time,
///      having checked each address on the explorer for the chain you are on.
///
///      Signing is yours to arrange — pass `--account <keystore-name>` (or a
///      hardware wallet flag). Do not put a private key in this repo, on the
///      command line, or in .env: shell history and `ps` both leak it.
///
///      forge script script/Deploy.s.sol:Deploy \
///        --rpc-url <url> --account <keystore-name> --broadcast --verify
contract Deploy is Script {
    function run() external returns (BalancerArbExecutor executor) {
        address owner = vm.envOr("EXECUTOR_OWNER", msg.sender);

        vm.startBroadcast();
        executor = new BalancerArbExecutor(owner);
        vm.stopBroadcast();

        console2.log("BalancerArbExecutor:", address(executor));
        console2.log("owner:              ", owner);
        console2.log("");
        console2.log("No targets are allowlisted. Add routers with setTarget()");
        console2.log("before this contract can execute anything.");
    }
}
