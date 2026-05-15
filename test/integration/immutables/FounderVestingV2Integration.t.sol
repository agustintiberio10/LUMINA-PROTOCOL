// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {FounderVestingV2, IAaveV3PoolReader} from "../../../src/token/FounderVestingV2.sol";

// ─── Local mocks (proper OZ ERC20, Chainlink-equivalent oracle, Aave-V3 reserve reader) ───

contract FVI2_Oracle {
    int256 public ethPrice;
    int256 public btcPrice;

    function setPrices(int256 e, int256 b) external {
        ethPrice = e;
        btcPrice = b;
    }

    function getLatestPrice(bytes32 asset) external view returns (int256) {
        if (asset == bytes32("ETH")) return ethPrice;
        if (asset == bytes32("BTC")) return btcPrice;
        return 0;
    }
}

contract FVI2_Aave {
    uint128 public rate;

    function setRate(uint128 r) external {
        rate = r;
    }

    function getReserveData(address) external view returns (IAaveV3PoolReader.ReserveData memory d) {
        d.currentVariableBorrowRate = rate;
    }
}

contract FVI2_Lumina is ERC20 {
    constructor() ERC20("LUMINA", "LUM") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

/// @title FounderVestingV2Integration
/// @notice Sprint Z.2 Phase D — e2e flow with a real OpenZeppelin ERC20 backing,
///         verifying that V2 tranche releases (a) actually move tokens, (b) emit events
///         indexable by The Graph / Ponder, and (c) preserve balance invariants
///         across all three tranches.
contract FounderVestingV2IntegrationTest is Test {
    FounderVestingV2 vesting;
    FVI2_Oracle oracle;
    FVI2_Aave aave;
    FVI2_Lumina lumina;
    address usdc = address(0xDEAD);
    address founder = makeAddr("founder");

    event TrancheReleased(uint256 trancheNumber, uint256 amount, address recipient);

    function setUp() public {
        vm.chainId(8453);
        oracle = new FVI2_Oracle();
        aave = new FVI2_Aave();
        lumina = new FVI2_Lumina();
        vesting = new FounderVestingV2(address(oracle), address(aave), address(lumina), usdc, founder);
        // Production-equivalent: LuminaTokenV2.initialize() pre-mints the 8M allotment to the vesting contract.
        lumina.mint(address(vesting), 8_000_000 * 1e18);
        // Trigger via fallback to keep this test deterministic and independent of oracle state.
        vm.warp(vesting.deployedAt() + vesting.FALLBACK_DURATION() + 1);
        vesting.triggerFallback();
    }

    function test_TrancheRelease_TransfersTokensRealOZ() public {
        uint256 founderBalBefore = lumina.balanceOf(founder);
        uint256 vestingBalBefore = lumina.balanceOf(address(vesting));
        vesting.releaseTranche();
        uint256 delta = lumina.balanceOf(founder) - founderBalBefore;
        assertEq(delta, vesting.TRANCHE_AMOUNT(), "founder receives tranche amount");
        assertEq(lumina.balanceOf(address(vesting)), vestingBalBefore - delta, "vesting decreases by same delta");
    }

    function test_TrancheRelease_EmitsIndexableEvent() public {
        vm.expectEmit(true, true, true, true);
        emit TrancheReleased(1, vesting.TRANCHE_AMOUNT(), founder);
        vesting.releaseTranche();
    }

    function test_AllThreeTranches_BalanceConsistencyEnd2End() public {
        // setUp() already triggered fallback; capture that anchor for via_ir-safe absolute warps.
        uint256 t0 = vesting.triggerTimestamp();
        // T1: immediate.
        vesting.releaseTranche();
        // T2: +31d.
        vm.warp(t0 + 31 days);
        vesting.releaseTranche();
        // T3: +62d (carries remainder to absorb rounding dust).
        vm.warp(t0 + 62 days);
        vesting.releaseTranche();
        assertEq(vesting.tranchesReleased(), 3);
        assertEq(vesting.totalReleased(), 8_000_000 * 1e18, "exact 8M released");
        assertEq(lumina.balanceOf(founder), 8_000_000 * 1e18, "founder holds 100%");
        assertEq(lumina.balanceOf(address(vesting)), 0, "vesting emptied");
    }
}
