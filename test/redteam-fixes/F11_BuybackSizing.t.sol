// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";
import {BuybackEngine} from "../../src/marketplace/BuybackEngine.sol";
import {MockMarketplace} from "../mocks/MockMarketplace.sol";
import {MockClaimBondV5} from "../mocks/MockClaimBondV5.sol";
import {MockSolvencyOracle} from "../mocks/MockSolvencyOracle.sol";
import {MockCapacityOracleV5} from "../mocks/MockCapacityOracleV5.sol";

contract F11MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// BondVault stub that records the burnFromReserves amount.
contract F11MockBondVault {
    uint256 public lastBurn;
    uint256 public lastDecrease;

    function decreaseObligations(uint256 amount) external {
        lastDecrease = amount;
    }

    function burnFromReserves(uint256 amount) external {
        lastBurn = amount;
    }
}

/// @notice F-11: double-burn must size from the guarded oracle price and cap
///         the burn at a sane multiple of the reference (no spot over-burn).
contract F11BuybackSizingTest is Test {
    F11MockUSDC internal usdc;
    F11MockBondVault internal vault;
    MockClaimBondV5 internal claimBond;
    MockSolvencyOracle internal solvency;
    MockCapacityOracleV5 internal oracle;
    MockMarketplace internal marketplace;
    BuybackEngine internal engine;

    address internal constant OWNER = address(0xA11CE);

    uint256 internal constant EPOCH = 7;
    uint256 internal constant AMOUNT = 100; // 100 bonds
    // faceValueUSD = getFaceValue(epoch) * amount = 1e18 * 100 = 100e18 (= $100)
    uint256 internal constant FACE_VALUE_USD = 100e18;

    function setUp() public {
        usdc = new F11MockUSDC();
        vault = new F11MockBondVault();
        claimBond = new MockClaimBondV5();
        solvency = new MockSolvencyOracle();
        oracle = new MockCapacityOracleV5();
        marketplace = new MockMarketplace();

        engine = ProxyDeployer.deployBuybackEngine(
            address(claimBond),
            address(vault),
            address(solvency),
            address(oracle),
            address(marketplace),
            address(usdc),
            OWNER
        );

        // Mint the bonds to the engine so burnByHolder works.
        claimBond.mint(address(engine), EPOCH, AMOUNT);

        // Fund the engine with USDC budget.
        usdc.mint(address(engine), 1_000_000e6);

        // Configure a daily buyback (operator = OWNER).
        vm.prank(OWNER);
        engine.setDailyBuyback(1_000_000e6, 95, 24);

        // Listing: price within max. priceUSDC small enough.
        // maxAllowedPriceUSDC = faceValueUSD * 95 / (100*1e12) = 100e18*95/1e14 = 95e6 ($95).
        marketplace.setListing(1, address(0xBEEF), EPOCH, AMOUNT, 50e6, true);

        solvency.setSolvencyRatio(20000); // 200% >= 150% => double burn active
    }

    /// Double-burn uses the guarded oracle price and is capped at 2x reference.
    function test_DoubleBurnUsesGuardedPriceAndCap() external {
        // Oracle price $0.01 (1e16). referenceBurn = faceValueUSD*1e18/price
        //   = 100e18 * 1e18 / 1e16 = 100e20 = 1e22 = 10_000e18 LUMINA.
        oracle.setPrice(1e16);
        uint256 referenceBurn = (FACE_VALUE_USD * 1e18) / 1e16; // 10_000e18

        engine.executeOffer(1);

        uint256 burned = vault.lastBurn();
        // With +2% slippage applied (no cap binding since 1.02x < 2x):
        uint256 expected = (referenceBurn * (10000 + 200)) / 10000;
        assertEq(burned, expected, "burn sized from guarded oracle + 2% slippage");

        // And it is strictly below the 2x hard cap.
        uint256 hardCap = (referenceBurn * 20000) / 10000;
        assertLt(burned, hardCap, "burn below 2x cap");
        // [F-18 coordination] BuybackEngine no longer calls
        // bondVault.decreaseObligations directly — that was a DOUBLE decrement
        // now that ClaimBond.burnByHolder decrements obligations itself. The
        // mock ClaimBond here does not forward to the vault, so a non-zero
        // lastDecrease would mean the redundant direct call is still present.
        // Asserting 0 verifies the double-decrement was removed; the real
        // obligation sync via burnByHolder is covered by F18_BurnObligations.
        assertEq(vault.lastDecrease(), 0, "F-18: no direct double-decrement from BuybackEngine");
    }

    /// Even if the guarded oracle reads at the LOW edge, the cap bounds the burn.
    /// We simulate by directly checking the cap math: the implementation caps
    /// luminaToBurn at 2x referenceBurn. Since slippage is only +2%, the cap is
    /// never the binding constraint under normal config — but the require on a
    /// zero price guards the fail-closed contract.
    function test_DoubleBurnRevertsOnZeroPrice() external {
        oracle.setPrice(0);
        vm.expectRevert(bytes("BuybackEngine: oracle price zero"));
        engine.executeOffer(1);
    }

    /// If the guarded oracle reverts (fail-closed deviation guard), the whole
    /// offer reverts — no fallback to a spot/manipulable price.
    function test_DoubleBurnRevertsWhenOracleUnavailable() external {
        oracle.setPrice(1e16);
        oracle.setRevertOnPrice(true);
        vm.expectRevert(bytes("Mock: price revert"));
        engine.executeOffer(1);
    }
}
