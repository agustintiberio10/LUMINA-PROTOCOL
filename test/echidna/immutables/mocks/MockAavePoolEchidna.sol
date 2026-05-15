// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAaveV3PoolReader} from "../../../../src/token/FounderVesting.sol";

/// @notice Minimal Aave V3 pool mock for Echidna fuzzing.
contract MockAavePoolEchidna {
    uint128 private _borrowRate;

    function setBorrowRate(uint128 r) external {
        _borrowRate = r;
    }

    function getReserveData(address) external view returns (IAaveV3PoolReader.ReserveData memory data) {
        data.currentVariableBorrowRate = _borrowRate;
    }
}
