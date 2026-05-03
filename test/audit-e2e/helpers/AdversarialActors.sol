// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ReentrancyAttacker
/// @notice Tries to call `target.victim(...)` recursively via fallback while a
///         token transfer is mid-flight. Used to validate reentrancy guards.
contract ReentrancyAttacker {
    address public target;
    bytes public payload;
    uint256 public reentryCount;

    function arm(address _target, bytes calldata _payload) external {
        target = _target;
        payload = _payload;
        reentryCount = 0;
    }

    function trigger() external {
        (bool ok, ) = target.call(payload);
        require(ok, "trigger failed");
    }

    receive() external payable {
        if (reentryCount < 1) {
            reentryCount++;
            (bool ok, ) = target.call(payload);
            // We don't require ok here - a properly guarded contract should
            // revert on the second entry, which is the test's success
            // condition.
            ok;
        }
    }

    fallback() external payable {
        if (reentryCount < 1) {
            reentryCount++;
            (bool ok, ) = target.call(payload);
            ok;
        }
    }
}

/// @title FlashloanSandwicher
/// @notice Mock attacker contract that runs (front, victim, back) inside a
///         single tx. Used to test MEV-resistance of buyback / redeem flows.
contract FlashloanSandwicher {
    function sandwich(address target, bytes calldata frontCall, bytes calldata backCall) external {
        (bool a, ) = target.call(frontCall);
        require(a, "front failed");
        // Victim tx happens implicitly between front and back when this is
        // composed with bundlerSimul.
        (bool b, ) = target.call(backCall);
        require(b, "back failed");
    }
}

/// @title GriefBomber
/// @notice Spams a target with low-value calls to test rate-limit / spam-floor
///         defenses (M-3 anti-spam, etc.).
contract GriefBomber {
    function spam(address target, bytes calldata payload, uint256 count) external {
        for (uint256 i; i < count; i++) {
            (bool ok, ) = target.call(payload);
            ok; // ignore failures - we only care that target stays correct
        }
    }
}
