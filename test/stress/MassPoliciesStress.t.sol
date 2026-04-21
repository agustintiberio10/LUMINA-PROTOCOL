// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BondVault} from "../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../src/bonds/ClaimBond.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

// ═══════ INLINE MOCKS ═══════

contract StressMockERC20 is ERC20 {
    constructor() ERC20("MockLUMINA", "mLUM") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

contract StressMockPriceOracle {
    uint256 public price;

    constructor(uint256 _price) {
        price = _price;
    }

    function setPrice(uint256 _price) external {
        price = _price;
    }

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }
}

// ═══════ TEST CONTRACT ═══════

contract MassPoliciesStress is Test {
    uint256 constant BASE_TS = 1767225600; // Jan 1 2026 UTC

    BondVault vault;
    ClaimBond claimBond;
    StressMockERC20 lumina;
    StressMockPriceOracle oracle;

    function setUp() public {
        vm.warp(BASE_TS + 60 days);

        lumina = new StressMockERC20();
        oracle = new StressMockPriceOracle(0.036e18); // $0.036
        claimBond = ProxyDeployer.deployClaimBond();

        // Deploy BondVault with address(this) as policyManager
        vault = ProxyDeployer.deployBondVault(
            address(lumina),
            address(claimBond),
            address(oracle),
            address(this) // policyManager = this test contract
        );

        // Wire ClaimBond -> BondVault
        claimBond.setBondVault(address(vault));

        // Fund vault with 70M LUMINA
        lumina.mint(address(vault), 70_000_000e18);
    }

    /// @notice 100 different addresses each issue a bond via BondVault.
    ///         Verify totalCommittedUSD accumulates correctly.
    function test_Stress_100ConcurrentPolicies() public {
        uint256 payoutPerBond = 100; // $100 each

        for (uint256 i = 0; i < 100; i++) {
            address user = address(uint160(0xBEEF0000 + i));
            vault.issueBond(user, payoutPerBond);
        }

        // totalCommittedUSD is stored in 18-dec USD-wei
        uint256 expectedCommitted = 100 * payoutPerBond * 1e18;
        assertEq(vault.totalCommittedUSD(), expectedCommitted, "totalCommittedUSD mismatch after 100 bonds");
    }

    /// @notice 1000 sequential issueBond calls. Verify system scales.
    function test_Stress_1000PoliciesSequential() public {
        address user = address(0xCAFE);
        uint256 payoutPerBond = 10; // $10 each

        for (uint256 i = 0; i < 1000; i++) {
            vault.issueBond(user, payoutPerBond);
        }

        uint256 expectedCommitted = 1000 * payoutPerBond * 1e18;
        assertEq(vault.totalCommittedUSD(), expectedCommitted, "totalCommittedUSD mismatch after 1000 bonds");
    }

    /// @notice Issue 50 bonds, warp past maturity, redeem all.
    ///         Verify totalCommittedUSD returns to 0.
    function test_Stress_MassiveTriggerEvent() public {
        address user = address(0xDADA);
        uint256 payoutPerBond = 50; // $50 each
        uint256 bondCount = 50;

        // Issue 50 bonds
        for (uint256 i = 0; i < bondCount; i++) {
            vault.issueBond(user, payoutPerBond);
        }

        uint256 expectedCommitted = bondCount * payoutPerBond * 1e18;
        assertEq(vault.totalCommittedUSD(), expectedCommitted, "pre-redeem committed mismatch");

        // Calculate the epoch these bonds mature into
        uint256 maturityTs = block.timestamp + 730 days;
        uint256 monthsFromBase = (maturityTs - BASE_TS) / 2629746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 month = 1 + monthsFromBase % 12;
        uint256 epochId = year * 100 + month;

        // Warp past maturity
        uint256 epochMaturity = _timestampFromYearMonth(year, month);
        vm.warp(epochMaturity + 1);

        // Redeem all bonds as the user
        // Each bond is payoutPerBond tokens in the epoch. Total = bondCount * payoutPerBond
        uint256 totalBondTokens = bondCount * payoutPerBond;
        vm.prank(user);
        vault.redeemBond(epochId, totalBondTokens);

        assertEq(vault.totalCommittedUSD(), 0, "totalCommittedUSD should be 0 after full redemption");
    }

    // ═══════ HELPER ═══════

    function _timestampFromYearMonth(uint256 year, uint256 month) internal pure returns (uint256) {
        uint256 monthsFromBase = (year - 2026) * 12 + (month - 1);
        return BASE_TS + (monthsFromBase * 2629746);
    }
}
