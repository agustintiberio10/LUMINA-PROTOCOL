// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProxyDeployer} from "../../../helpers/ProxyDeployer.sol";

import {LuminaTokenV2} from "../../../../src/token/LuminaTokenV2.sol";
import {BondVault} from "../../../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../../../src/bonds/ClaimBond.sol";
import {PolicyManagerV2} from "../../../../src/core/PolicyManagerV2.sol";
import {CoverRouterV2} from "../../../../src/core/CoverRouterV2.sol";
import {TWAPBurner} from "../../../../src/core/TWAPBurner.sol";
import {IDexRouter} from "../../../../src/interfaces/IDexRouter.sol";

// ─────────────────────────────────────────────────────────────────────────
// Minimal mocks - protocol contracts (Token, Vault, ClaimBond, PolicyManager,
// CoverRouter, TWAPBurner) are real; only USDC/oracle/DEX/shield are mocks.
// ─────────────────────────────────────────────────────────────────────────

contract MockUSDC is IERC20 {
    string public name = "USDC";
    string public symbol = "USDC";
    uint8 public constant decimals = 6;
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
        if (allowance[f][msg.sender] != type(uint256).max) {
            allowance[f][msg.sender] -= a;
        }
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

contract MockOracle {
    uint256 public price = 1e16; // 0.01 USD/LUMINA - well above MIN threshold

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }
    /// @dev [Fix M-6 mock] Returns the same value as `getLuminaPrice()` so
    ///      tests that don't drive the TWAP path explicitly remain unaffected.
    function getTWAP(uint32 /*secondsAgo*/) external view returns (uint256) {
        return this.getLuminaPrice();
    }

}

contract MockDex is IDexRouter {
    IERC20 public lumina;

    constructor(address l) {
        lumina = IERC20(l);
    }

    function swap(address tokenIn, address, uint256 amountIn, uint256) external override returns (uint256) {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = amountIn * 27 * 1e12;
        lumina.transfer(msg.sender, out);
        return out;
    }

    function getQuote(address, address, uint256 amountIn) external pure override returns (uint256) {
        return amountIn * 27 * 1e12;
    }
}

/// @dev Minimal shield. Conforms to the surface PolicyManagerV2 actually calls
///      from within recordPolicy (createPolicy → returns policyId).
contract MockShield {
    uint256 private _nextPolicyId;

    struct CreatePolicyParams {
        address buyer;
        uint256 coverageAmount;
        uint256 premiumAmount;
        uint32 durationSeconds;
        bytes32 asset;
        bytes32 stablecoin;
        address protocol;
        bytes extraData;
    }

    function createPolicy(CreatePolicyParams calldata) external returns (uint256) {
        _nextPolicyId++;
        return _nextPolicyId;
    }
}

// ─────────────────────────────────────────────────────────────────────────
// FIX: purchasePolicyFor must charge the BUYER, not the relayer/msg.sender.
// 8 tests covering the new semantics + non-regression of self-purchase.
// ─────────────────────────────────────────────────────────────────────────

contract RelayerPaymentFixTest is Test {
    LuminaTokenV2 token;
    ClaimBond cb;
    BondVault vault;
    PolicyManagerV2 pm;
    CoverRouterV2 router;
    TWAPBurner burner;
    MockUSDC usdc;
    MockOracle oracle;
    MockDex dex;
    MockShield shield;

    bytes32 productId;

    address admin = address(this);
    address relayer = makeAddr("relayer");
    address buyer = makeAddr("buyer");

    function setUp() public {
        usdc = new MockUSDC();
        oracle = new MockOracle();

        // Vault address must be predictable so LuminaTokenV2 can wire it on init.
        // The proxy lands at nonce + (impl=10, proxy=11) of the test contract.
        uint256 nonce = vm.getNonce(address(this));
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 10);

        token = ProxyDeployer.deployLuminaTokenV2(
            predictedVault, makeAddr("cex"), makeAddr("founder"), makeAddr("lbp"), makeAddr("treasury")
        );

        dex = new MockDex(address(token));
        deal(address(token), address(dex), 100_000_000e18);

        burner = ProxyDeployer.deployTWAPBurner(address(usdc), address(token), address(dex));
        token.grantRole(token.BURNER_ROLE(), address(burner));

        cb = ProxyDeployer.deployClaimBond();
        pm = ProxyDeployer.deployPolicyManagerV2(predictedVault);
        vault = ProxyDeployer.deployBondVault(address(token), address(cb), address(oracle), address(pm));
        require(address(vault) == predictedVault, "vault address mismatch");

        cb.setBondVault(address(vault));

        router = ProxyDeployer.deployCoverRouterV2(address(usdc), address(pm), address(burner));
        router.setCapacityOracle(address(oracle));
        pm.setRouter(address(router));

        // Reserves wiring required by TWAPBurner before it accepts premium.
        burner.setReserves(makeAddr("buyback"), makeAddr("ops"), makeAddr("maintenance"));

        // Register product + shield
        productId = keccak256("FLASHBTC1H-001");
        shield = new MockShield();
        pm.registerProduct(productId, address(shield));
        router.configureProduct(productId, 8000, 100, 15000, 3600, true);

        // Authorize the relayer for purchasePolicyFor calls.
        router.setRelayer(relayer, true);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 1. Buyer pays the premium; relayer balance does not move.
    // ─────────────────────────────────────────────────────────────────────
    function test_FixRelayer_BuyerPaysPremium_NotRelayer() public {
        usdc.mint(buyer, 10_000e6);
        vm.prank(buyer);
        usdc.approve(address(router), type(uint256).max);

        // Relayer holds zero USDC. Before fix, this would revert with Panic 0x11
        // (underflow in safeTransferFrom) because the contract pulled from msg.sender.
        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 relayerBefore = usdc.balanceOf(relayer);
        assertEq(relayerBefore, 0, "relayer must hold zero USDC for this test");

        vm.prank(relayer);
        uint256 policyId = router.purchasePolicyFor(productId, 1_000e6, "BTC", buyer);

        uint256 buyerAfter = usdc.balanceOf(buyer);
        uint256 relayerAfter = usdc.balanceOf(relayer);

        assertGt(policyId, 0, "policy created");
        assertEq(relayerAfter, 0, "relayer balance must remain zero - relayer never paid");
        assertLt(buyerAfter, buyerBefore, "buyer balance must decrease - buyer paid");

        // Coverage 1 000 USDC, payoutRatio 8 000 bps, triggerProb 100 bps,
        // marginBps 15 000 → premium = 1e9 × 8000 × 100 × 15000 / 1e12 = 1.2e7.
        assertEq(buyerBefore - buyerAfter, 12_000_000, "premium = 12 USDC for 1 000 USDC coverage");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2. Buyer with USDC but no approval - must revert.
    // ─────────────────────────────────────────────────────────────────────
    function test_FixRelayer_BuyerWithoutApproval_Reverts() public {
        usdc.mint(buyer, 10_000e6);
        // Deliberately skip approve.

        vm.prank(relayer);
        vm.expectRevert(); // SafeERC20: ERC20 transferFrom underflow on allowance==0
        router.purchasePolicyFor(productId, 1_000e6, "BTC", buyer);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 3. Buyer with approval but no USDC balance - must revert.
    // ─────────────────────────────────────────────────────────────────────
    function test_FixRelayer_BuyerWithoutUSDC_Reverts() public {
        vm.prank(buyer);
        usdc.approve(address(router), type(uint256).max);
        // Deliberately skip mint - buyer has zero balance.

        vm.prank(relayer);
        vm.expectRevert(); // ERC20: transfer from zero balance underflow
        router.purchasePolicyFor(productId, 1_000e6, "BTC", buyer);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 4. Non-authorized relayer cannot call purchasePolicyFor.
    // ─────────────────────────────────────────────────────────────────────
    function test_FixRelayer_NonAuthorizedRelayer_Reverts() public {
        usdc.mint(buyer, 10_000e6);
        vm.prank(buyer);
        usdc.approve(address(router), type(uint256).max);

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(CoverRouterV2.NotAuthorizedRelayer.selector, attacker));
        router.purchasePolicyFor(productId, 1_000e6, "BTC", buyer);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 5. Zero buyer rejected.
    // ─────────────────────────────────────────────────────────────────────
    function test_FixRelayer_ZeroBuyer_Reverts() public {
        vm.prank(relayer);
        vm.expectRevert(bytes("Zero buyer"));
        router.purchasePolicyFor(productId, 1_000e6, "BTC", address(0));
    }

    // ─────────────────────────────────────────────────────────────────────
    // 6. PolicyManager records the BUYER as the policy owner, not the relayer.
    // ─────────────────────────────────────────────────────────────────────
    function test_FixRelayer_PolicyOwnedByBuyer_NotRelayer() public {
        usdc.mint(buyer, 10_000e6);
        vm.prank(buyer);
        usdc.approve(address(router), type(uint256).max);

        vm.prank(relayer);
        uint256 policyId = router.purchasePolicyFor(productId, 1_000e6, "BTC", buyer);

        PolicyManagerV2.PolicyRecord memory rec = pm.getPolicy(productId, policyId);
        assertEq(rec.buyer, buyer, "policy owner is buyer");
        assertTrue(rec.buyer != relayer, "policy owner is NOT the relayer");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 7. purchasePolicy (self-purchase) still works - fix is scoped to For.
    // ─────────────────────────────────────────────────────────────────────
    function test_FixRelayer_SelfPurchase_StillWorks() public {
        address selfBuyer = makeAddr("selfBuyer");
        usdc.mint(selfBuyer, 10_000e6);
        vm.startPrank(selfBuyer);
        usdc.approve(address(router), type(uint256).max);
        uint256 selfBefore = usdc.balanceOf(selfBuyer);
        uint256 policyId = router.purchasePolicy(productId, 1_000e6, "BTC");
        uint256 selfAfter = usdc.balanceOf(selfBuyer);
        vm.stopPrank();

        assertGt(policyId, 0);
        assertLt(selfAfter, selfBefore, "self-buyer paid the premium");

        PolicyManagerV2.PolicyRecord memory rec = pm.getPolicy(productId, policyId);
        assertEq(rec.buyer, selfBuyer, "policy owner is the self-buyer");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 8. Equivalence: purchasePolicy and purchasePolicyFor produce identical
    //    economic outcomes for the buyer (same premium charged, same policy
    //    record). Relayer-pattern is a pure delivery mechanism.
    // ─────────────────────────────────────────────────────────────────────
    function test_FixRelayer_DirectAndRelayer_EconomicallyEquivalent() public {
        address buyerA = makeAddr("buyerA");
        address buyerB = makeAddr("buyerB");
        usdc.mint(buyerA, 10_000e6);
        usdc.mint(buyerB, 10_000e6);

        vm.prank(buyerA);
        usdc.approve(address(router), type(uint256).max);
        vm.prank(buyerB);
        usdc.approve(address(router), type(uint256).max);

        uint256 aBefore = usdc.balanceOf(buyerA);
        uint256 bBefore = usdc.balanceOf(buyerB);

        // A purchases directly.
        vm.prank(buyerA);
        uint256 idA = router.purchasePolicy(productId, 1_000e6, "BTC");

        // B has the relayer purchase on its behalf.
        vm.prank(relayer);
        uint256 idB = router.purchasePolicyFor(productId, 1_000e6, "BTC", buyerB);

        uint256 aPaid = aBefore - usdc.balanceOf(buyerA);
        uint256 bPaid = bBefore - usdc.balanceOf(buyerB);
        assertEq(aPaid, bPaid, "premiums charged are identical");

        PolicyManagerV2.PolicyRecord memory recA = pm.getPolicy(productId, idA);
        PolicyManagerV2.PolicyRecord memory recB = pm.getPolicy(productId, idB);
        assertEq(recA.coverageAmount, recB.coverageAmount, "coverage equal");
        assertEq(recA.payoutAmount, recB.payoutAmount, "payout equal");
        assertEq(recA.premiumPaid, recB.premiumPaid, "premium equal");
    }
}
