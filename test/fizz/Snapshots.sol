// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import {Base} from "./Base.sol";

/// @notice Used to take snapshots of the state before and after a function call
abstract contract Snapshots is Base {
    struct State {
        // The executor's own holdings — the quantity every profit property is
        // written against. The scaffold's placeholder tracked actor.balance,
        // which is not what this contract's guarantees are about.
        uint256 execTokenA;
        uint256 execTokenB;
        uint256 execNative;
        address owner;
        address pendingOwner;
    }

    State internal stateBefore;
    State internal stateAfter;

    function _takeSnapshot(State storage state) private {
        state.execTokenA = execBalance(address(tokenA));
        state.execTokenB = execBalance(address(tokenB));
        state.execNative = execBalance(address(0));
        state.owner = exec.owner();
        state.pendingOwner = exec.pendingOwner();
    }

    function snapshotBefore() internal {
        _takeSnapshot(stateBefore);
    }

    function snapshotAfter() internal {
        _takeSnapshot(stateAfter);
    }
}
