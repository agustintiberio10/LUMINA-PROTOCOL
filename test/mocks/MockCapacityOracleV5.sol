// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockCapacityOracleV5 {
    uint256 public mockPrice;
    bool public revertOnPrice;

    // [Fix M-6] Independent TWAP control. By default mirrors `mockPrice`
    // (so existing tests that don't care about TWAP keep working); set
    // explicitly via `setTwapPrice` to drive the M-6 capacity-TWAP path.
    bool public twapOverridden;
    uint256 public mockTwapPrice;
    bool public revertOnTwap;

    function setPrice(uint256 p) external {
        mockPrice = p;
    }

    function setRevertOnPrice(bool r) external {
        revertOnPrice = r;
    }

    function setTwapPrice(uint256 p) external {
        mockTwapPrice = p;
        twapOverridden = true;
    }

    function clearTwapOverride() external {
        twapOverridden = false;
        mockTwapPrice = 0;
    }

    function setRevertOnTwap(bool r) external {
        revertOnTwap = r;
    }

    function getLuminaPrice() external view returns (uint256) {
        require(!revertOnPrice, "Mock: price revert");
        return mockPrice;
    }

    /// @notice [Fix M-6] Mirrors CapacityOracle.getTWAP signature so the
    ///         BondVault `IPriceOracle` interface is satisfied. `secondsAgo`
    ///         is ignored — tests drive the value via `setTwapPrice`.
    function getTWAP(uint32 /*secondsAgo*/ ) external view returns (uint256) {
        require(!revertOnTwap, "Mock: twap revert");
        return twapOverridden ? mockTwapPrice : mockPrice;
    }
}
