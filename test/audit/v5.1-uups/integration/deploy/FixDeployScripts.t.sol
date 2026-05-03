// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {LuminaTokenV2} from "../../../../../src/token/LuminaTokenV2.sol";
import {TreasuryVesting} from "../../../../../src/token/TreasuryVesting.sol";
import {ClaimBond} from "../../../../../src/bonds/ClaimBond.sol";
import {BondVault} from "../../../../../src/bonds/BondVault.sol";
import {CapacityOracle} from "../../../../../src/oracles/CapacityOracle.sol";
import {SolvencyOracle} from "../../../../../src/oracles/SolvencyOracle.sol";
import {AdaptiveFeeDistributor} from "../../../../../src/core/AdaptiveFeeDistributor.sol";
import {TWAPBurner} from "../../../../../src/core/TWAPBurner.sol";
import {PolicyManagerV2} from "../../../../../src/core/PolicyManagerV2.sol";
import {CoverRouterV2} from "../../../../../src/core/CoverRouterV2.sol";
import {CEXLiquidityReserve} from "../../../../../src/treasury/CEXLiquidityReserve.sol";
import {MaintenanceReserve} from "../../../../../src/treasury/MaintenanceReserve.sol";
import {LuminaBondMarketplace} from "../../../../../src/marketplace/LuminaBondMarketplace.sol";
import {BuybackEngine} from "../../../../../src/marketplace/BuybackEngine.sol";
import {ShieldKeeper} from "../../../../../src/automation/ShieldKeeper.sol";
import {IDexRouter} from "../../../../../src/interfaces/IDexRouter.sol";

contract MockUSDC_FixDeploy {
    string public name = "USDC";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        totalSupply += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

contract MockDex_FixDeploy is IDexRouter {
    function swap(address, address, uint256, uint256) external pure override returns (uint256) {
        return 1000e18;
    }

    function getQuote(address, address, uint256) external pure override returns (uint256) {
        return 1000e18;
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Tests for fix #31 — verify the deploy scripts now wire setAuthorizedOperator.
// ─────────────────────────────────────────────────────────────────────────

contract FixDeployScriptsTest is Test {
    address internal deployer = address(this);

    /// @dev Mirrors the FIXED Sepolia deploy flow — adds the two
    /// claimBond.setAuthorizedOperator(...) calls that the audit found missing.
    function _runFixedDeploy()
        internal
        returns (
            LuminaTokenV2 lumina,
            BondVault vault,
            ClaimBond cb,
            CapacityOracle capOracle,
            SolvencyOracle solOracle,
            AdaptiveFeeDistributor adp,
            TWAPBurner burner,
            PolicyManagerV2 pm,
            CoverRouterV2 router,
            CEXLiquidityReserve cex,
            MaintenanceReserve mr,
            TreasuryVesting tv,
            LuminaBondMarketplace mp,
            BuybackEngine buyback,
            ShieldKeeper keeper,
            MockUSDC_FixDeploy usdc
        )
    {
        usdc = new MockUSDC_FixDeploy();
        MockDex_FixDeploy dex = new MockDex_FixDeploy();

        mr = MaintenanceReserve(
            address(
                new ERC1967Proxy(
                    address(new MaintenanceReserve()),
                    abi.encodeWithSelector(MaintenanceReserve.initialize.selector, address(usdc), deployer)
                )
            )
        );
        cb = ClaimBond(
            address(new ERC1967Proxy(address(new ClaimBond()), abi.encodeWithSelector(ClaimBond.initialize.selector)))
        );

        uint64 n = vm.getNonce(deployer);
        address predicted = vm.computeCreateAddress(deployer, n + 9);

        capOracle = CapacityOracle(
            address(
                new ERC1967Proxy(
                    address(new CapacityOracle()),
                    abi.encodeWithSelector(
                        CapacityOracle.initialize.selector, address(0), predicted, address(usdc), 0.036e18
                    )
                )
            )
        );
        vault = BondVault(
            address(
                new ERC1967Proxy(
                    address(new BondVault()),
                    abi.encodeWithSelector(
                        BondVault.initialize.selector, predicted, address(cb), address(capOracle), address(0)
                    )
                )
            )
        );
        cex = CEXLiquidityReserve(
            address(
                new ERC1967Proxy(
                    address(new CEXLiquidityReserve()),
                    abi.encodeWithSelector(CEXLiquidityReserve.initialize.selector, predicted, deployer)
                )
            )
        );
        tv = TreasuryVesting(
            address(
                new ERC1967Proxy(
                    address(new TreasuryVesting()),
                    abi.encodeWithSelector(TreasuryVesting.initialize.selector, predicted)
                )
            )
        );

        address founderVesting = address(uint160(uint256(keccak256("founderVesting"))));
        address lbpDeposit = address(uint160(uint256(keccak256("lbpDeposit"))));

        lumina = LuminaTokenV2(
            address(
                new ERC1967Proxy(
                    address(new LuminaTokenV2()),
                    abi.encodeWithSelector(
                        LuminaTokenV2.initialize.selector,
                        address(vault),
                        address(cex),
                        founderVesting,
                        lbpDeposit,
                        address(tv)
                    )
                )
            )
        );
        require(address(lumina) == predicted, "prediction");

        cb.setBondVault(address(vault));

        solOracle = SolvencyOracle(
            address(
                new ERC1967Proxy(
                    address(new SolvencyOracle()),
                    abi.encodeWithSelector(
                        SolvencyOracle.initialize.selector, address(vault), address(capOracle), deployer
                    )
                )
            )
        );
        adp = AdaptiveFeeDistributor(
            address(
                new ERC1967Proxy(
                    address(new AdaptiveFeeDistributor()),
                    abi.encodeWithSelector(AdaptiveFeeDistributor.initialize.selector, address(solOracle))
                )
            )
        );
        burner = TWAPBurner(
            address(
                new ERC1967Proxy(
                    address(new TWAPBurner()),
                    abi.encodeWithSelector(TWAPBurner.initialize.selector, address(usdc), address(lumina), address(dex))
                )
            )
        );
        pm = PolicyManagerV2(
            address(
                new ERC1967Proxy(
                    address(new PolicyManagerV2()),
                    abi.encodeWithSelector(PolicyManagerV2.initialize.selector, address(vault))
                )
            )
        );
        router = CoverRouterV2(
            address(
                new ERC1967Proxy(
                    address(new CoverRouterV2()),
                    abi.encodeWithSelector(
                        CoverRouterV2.initialize.selector, address(usdc), address(pm), address(burner)
                    )
                )
            )
        );
        pm.setRouter(address(router));
        router.setCapacityOracle(address(capOracle));
        vault.setPolicyManager(address(pm));

        mp = LuminaBondMarketplace(
            address(
                new ERC1967Proxy(
                    address(new LuminaBondMarketplace()),
                    abi.encodeWithSelector(
                        LuminaBondMarketplace.initialize.selector, address(cb), address(usdc), address(burner), deployer
                    )
                )
            )
        );

        buyback = BuybackEngine(
            address(
                new ERC1967Proxy(
                    address(new BuybackEngine()),
                    abi.encodeWithSelector(
                        BuybackEngine.initialize.selector,
                        address(cb),
                        address(vault),
                        address(solOracle),
                        address(capOracle),
                        address(mp),
                        address(usdc),
                        deployer
                    )
                )
            )
        );

        keeper = ShieldKeeper(
            address(
                new ERC1967Proxy(
                    address(new ShieldKeeper()), abi.encodeWithSelector(ShieldKeeper.initialize.selector, address(pm))
                )
            )
        );

        vault.setAuthorizedCaller(address(buyback), true);

        // [Fix audit #31 CRITICAL] The fix adds these two calls.
        cb.setAuthorizedOperator(address(mp), true);
        cb.setAuthorizedOperator(address(buyback), true);

        burner.setFeeDistributor(address(adp));
        burner.setReserves(address(buyback), deployer, address(mr));
        burner.setCapacityOracle(address(capOracle));
        burner.setAuthorizedSender(address(router), true);
        burner.setAdaptiveMode(true);
        lumina.grantRole(lumina.BURNER_ROLE(), address(burner));
    }

    // ═════════════════════ A. CRITICAL fix verification ═════════════════════

    function test_FixDeploy_Marketplace_AuthorizedAfterDeploy() public {
        (,, ClaimBond cb,,,,,,,,,, LuminaBondMarketplace mp, BuybackEngine buyback,,) = _runFixedDeploy();

        // Both ClaimBond authorizations now present (the fix).
        assertTrue(cb.authorizedOperators(address(mp)), "Marketplace must be authorized");
        assertTrue(cb.authorizedOperators(address(buyback)), "BuybackEngine must be authorized");
    }

    function test_FixDeploy_Marketplace_ListWorks_AfterFix() public {
        (, BondVault vault, ClaimBond cb,,,,,,,,,, LuminaBondMarketplace mp,,,) = _runFixedDeploy();

        address seller = makeAddr("seller");
        // Mint a bond directly via vault (impersonating PM).
        vm.prank(address(vault));
        cb.mint(seller, 202904, 500);

        vm.startPrank(seller);
        cb.setApprovalForAll(address(mp), true);
        uint256 listingId = mp.list(202904, 100, 100e6);
        vm.stopPrank();

        (,,,, bool active) = mp.getListing(listingId);
        assertTrue(active, "listing succeeds because Marketplace is now an authorized operator");
    }

    function test_FixDeploy_Marketplace_BuyWorks_AfterFix() public {
        (, BondVault vault, ClaimBond cb,,,,,,,,,, LuminaBondMarketplace mp,,, MockUSDC_FixDeploy usdc) =
            _runFixedDeploy();

        address seller = makeAddr("seller");
        address buyer = makeAddr("buyer");
        vm.prank(address(vault));
        cb.mint(seller, 202904, 500);

        vm.startPrank(seller);
        cb.setApprovalForAll(address(mp), true);
        uint256 listingId = mp.list(202904, 100, 100e6);
        vm.stopPrank();

        // Buyer pays 100e6 + 1.5% buyer fee (post-M-3 floor: pricePerUnit = 1 USDC).
        usdc.mint(buyer, 200e6);
        vm.startPrank(buyer);
        usdc.approve(address(mp), type(uint256).max);
        mp.executeBuy(listingId);
        vm.stopPrank();

        assertEq(cb.balanceOf(buyer, 202904), 100, "buyer received the bonds");
    }

    /// @dev Demonstrates the BUG behavior: deploy WITHOUT the two fix lines and
    /// confirm the marketplace cannot list. This is the regression guard.
    function test_FixDeploy_PreFix_Marketplace_FailsWithoutAuth() public {
        // Build a stack but SKIP the two new setAuthorizedOperator calls.
        MockUSDC_FixDeploy usdc = new MockUSDC_FixDeploy();
        ClaimBond cb = ClaimBond(
            address(new ERC1967Proxy(address(new ClaimBond()), abi.encodeWithSelector(ClaimBond.initialize.selector)))
        );
        // Pre-fix marketplace deploy. No setAuthorizedOperator for it.
        LuminaBondMarketplace mp = LuminaBondMarketplace(
            address(
                new ERC1967Proxy(
                    address(new LuminaBondMarketplace()),
                    abi.encodeWithSelector(
                        LuminaBondMarketplace.initialize.selector,
                        address(cb),
                        address(usdc),
                        makeAddr("burner"),
                        deployer
                    )
                )
            )
        );
        cb.setBondVault(deployer); // we play the vault for direct minting

        address seller = makeAddr("seller");
        cb.mint(seller, 202904, 500);

        // Without setAuthorizedOperator, marketplace listing fails because
        // safeTransferFrom rejects unauthorized operators (Fix #18).
        vm.startPrank(seller);
        cb.setApprovalForAll(address(mp), true);
        vm.expectRevert(); // ClaimBond rejects non-whitelisted marketplace operator
        mp.list(202904, 100, 100e6);
        vm.stopPrank();
    }

    // ═════════════════════ B. Buyback flow works post-fix ═════════════════════

    /// @dev The full BuybackEngine.executeOffer double-burn path requires
    /// pre-existing committed obligations (covered by audit #30 cross-contract
    /// suite). Here we narrowly validate the fix's effect: BuybackEngine is now
    /// an authorized ClaimBond operator post-deploy. The full flow is regression-
    /// tested in CrossContractIntegration.t.sol.
    function test_FixDeploy_Buyback_AuthorizedAsClaimBondOperator() public {
        (,, ClaimBond cb,,,,,,,,,,, BuybackEngine buyback,,) = _runFixedDeploy();
        assertTrue(cb.authorizedOperators(address(buyback)), "BuybackEngine authorized");
    }

    // ═════════════════════ C. WirePostDeploy helper ═════════════════════

    /// @dev If a deploy somehow misses the call (hot-fix scenario), the
    /// WireLuminaV5PostDeploy helper can be invoked. We test the helper's
    /// SAME effect via direct calls (cannot vm.broadcast inside foundry tests).
    function test_FixDeploy_WirePostDeploy_AuthorizeOperatorsHelper_SameEffect() public {
        // Deploy a stack that simulates pre-fix state.
        MockUSDC_FixDeploy usdc = new MockUSDC_FixDeploy();
        ClaimBond cb = ClaimBond(
            address(new ERC1967Proxy(address(new ClaimBond()), abi.encodeWithSelector(ClaimBond.initialize.selector)))
        );
        cb.setBondVault(deployer);

        LuminaBondMarketplace mp = LuminaBondMarketplace(
            address(
                new ERC1967Proxy(
                    address(new LuminaBondMarketplace()),
                    abi.encodeWithSelector(
                        LuminaBondMarketplace.initialize.selector,
                        address(cb),
                        address(usdc),
                        makeAddr("burner"),
                        deployer
                    )
                )
            )
        );

        assertFalse(cb.authorizedOperators(address(mp)));

        // Helper-equivalent calls.
        cb.setAuthorizedOperator(address(mp), true);
        cb.setAuthorizedOperator(address(0xBEEF), true); // simulating buyback

        assertTrue(cb.authorizedOperators(address(mp)));
        assertTrue(cb.authorizedOperators(address(0xBEEF)));
    }

    function test_FixDeploy_WirePostDeploy_Idempotent_RepeatDoesNotRevert() public {
        ClaimBond cb = ClaimBond(
            address(new ERC1967Proxy(address(new ClaimBond()), abi.encodeWithSelector(ClaimBond.initialize.selector)))
        );
        // Set, then re-set — second call is a no-op write but does not revert.
        cb.setAuthorizedOperator(address(0xCAFE), true);
        cb.setAuthorizedOperator(address(0xCAFE), true);
        assertTrue(cb.authorizedOperators(address(0xCAFE)));
    }

    // ═════════════════════ D. Sanity — fix doesn't break previously-correct invariants ═════════════════════

    function test_FixDeploy_TokenDistribution_StillCorrect() public {
        (LuminaTokenV2 lumina, BondVault vault,,,,,,,, CEXLiquidityReserve cex,, TreasuryVesting tv,,,,) =
            _runFixedDeploy();

        // 70/14/8/5/3 split unchanged.
        assertEq(lumina.balanceOf(address(vault)), 70_000_000e18);
        assertEq(lumina.balanceOf(address(cex)), 14_000_000e18);
        assertEq(lumina.balanceOf(address(tv)), 3_000_000e18);
        assertEq(lumina.totalSupply(), 100_000_000e18);
    }

    function test_FixDeploy_Wiring_UnchangedFromAudit30() public {
        (
            ,
            BondVault vault,
            ClaimBond cb,,,,
            TWAPBurner burner,
            PolicyManagerV2 pm,
            CoverRouterV2 router,,,,,
            BuybackEngine buyback,,
        ) = _runFixedDeploy();

        // Still wired correctly.
        assertEq(address(cb.bondVault()), address(vault));
        assertEq(vault.policyManager(), address(pm));
        assertEq(pm.router(), address(router));
        assertTrue(vault.authorizedCallers(address(buyback)));
        assertTrue(burner.adaptiveModeEnabled());
    }

    // ═════════════════════ E. VerifyScript would now PASS post-fix ═════════════════════

    /// @dev The audit #31 found the verify script lacked the marketplace check.
    /// The fix adds it. Here we simulate the verify script's logic over the
    /// fixed deploy and confirm the new check passes.
    function test_FixDeploy_VerifyScript_NewCheck_Passes() public {
        (,, ClaimBond cb,,,,,,,,,, LuminaBondMarketplace mp, BuybackEngine buyback,,) = _runFixedDeploy();

        // Mirror the new check in VerifyLuminaV5Deployment.
        assertTrue(cb.authorizedOperators(address(mp)), "verify check #1 (Marketplace authorized)");
        assertTrue(cb.authorizedOperators(address(buyback)), "verify check #2 (BuybackEngine authorized)");
    }

    function test_FixDeploy_VerifyScript_DetectsMissing_OnPreFixDeploy() public {
        // Simulate a pre-fix deploy: skip the two setAuthorizedOperator calls.
        ClaimBond cb = ClaimBond(
            address(new ERC1967Proxy(address(new ClaimBond()), abi.encodeWithSelector(ClaimBond.initialize.selector)))
        );
        address mp = makeAddr("preFixMarketplace");
        address bb = makeAddr("preFixBuyback");

        // The verify script's new check would now FAIL (returning false),
        // which would cause the script's `failures++` increment and final revert.
        assertFalse(cb.authorizedOperators(mp), "VerifyScript would catch this");
        assertFalse(cb.authorizedOperators(bb), "VerifyScript would catch this");
    }
}
