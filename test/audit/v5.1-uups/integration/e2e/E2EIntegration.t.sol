// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProxyDeployer} from "../../../../helpers/ProxyDeployer.sol";

import {LuminaTokenV2} from "../../../../../src/token/LuminaTokenV2.sol";
import {BondVault} from "../../../../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../../../../src/bonds/ClaimBond.sol";
import {PolicyManagerV2} from "../../../../../src/core/PolicyManagerV2.sol";
import {CoverRouterV2} from "../../../../../src/core/CoverRouterV2.sol";
import {TWAPBurner} from "../../../../../src/core/TWAPBurner.sol";
import {LuminaBondMarketplace} from "../../../../../src/marketplace/LuminaBondMarketplace.sol";
import {IDexRouter} from "../../../../../src/interfaces/IDexRouter.sol";

// ─────────────────────────────────────────────────────────────────────────
// Audit V5.1 #37 — E2E Integration tests.
//
// Three end-to-end journeys exercised on the real V5.1 contracts (only
// USDC / oracle / DEX / shield are mocks — all protocol contracts are
// the production proxies):
//
//   1. AI agent: relayer purchases policy via purchasePolicyFor, oracle
//      triggers, bond emitted to agent, agent redeems at maturity.
//   2. Bond trader: another buyer lists their bond, third party buys,
//      third party redeems at maturity.
//   3. Cross-component: agent gets bond from a triggered policy, lists
//      it on the marketplace, a third party buys it, the third party
//      eventually redeems at maturity.
//   4. Global invariants survive a multi-step run.
//
// Companion: docs/audit/v5.1-uups/37-e2e-integration/01-FLOWS.md.
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
    uint256 public price = 1e16; // 0.01 USD/LUMINA — comfortably above MIN

    function getLuminaPrice() external view returns (uint256) {
        return price;
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

/// @dev Minimal shield. The router calls `createPolicy(params)` on the
///      registered shield via PolicyManager.recordPolicy; the shield only
///      needs to mint a unique policy id.
contract MockShield {
    uint256 private _next;

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
        _next++;
        return _next;
    }
}

contract E2EIntegrationTest is Test {
    LuminaTokenV2 token;
    ClaimBond cb;
    BondVault vault;
    PolicyManagerV2 pm;
    CoverRouterV2 router;
    TWAPBurner burner;
    LuminaBondMarketplace marketplace;
    MockUSDC usdc;
    MockOracle oracle;
    MockDex dex;
    MockShield shield;

    bytes32 productId;
    address admin = address(this);
    address relayer = makeAddr("relayer");
    address aiAgent = makeAddr("aiAgent");
    address humanBuyer = makeAddr("humanBuyer");
    address humanSeller = makeAddr("humanSeller");

    function setUp() public {
        vm.chainId(8453);
        // The protocol's epoch math is rooted at 2026-01-01. Foundry's default
        // block.timestamp is 1, which trips the BASE_TS guard inside the bond
        // helpers. Warp into a sensible production-like timestamp before any
        // contract is deployed so vault/marketplace records line up.
        vm.warp(1_770_000_000); // 2026-02-02

        usdc = new MockUSDC();
        oracle = new MockOracle();

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

        burner.setReserves(makeAddr("buyback"), makeAddr("ops"), makeAddr("maintenance"));

        productId = keccak256("FLASHBTC1H-001");
        shield = new MockShield();
        pm.registerProduct(productId, address(shield));
        // 80% payout, 100bps trigger, 1.5x margin, 1h duration, active.
        router.configureProduct(productId, 8000, 100, 15000, 3600, true);

        // Marketplace + ClaimBond authorisation.
        marketplace = ProxyDeployer.deployLuminaBondMarketplace(address(cb), address(usdc), address(burner), admin);
        cb.setAuthorizedOperator(address(marketplace), true);
        burner.setAuthorizedSender(address(marketplace), true);

        // Authorize the API relayer.
        router.setRelayer(relayer, true);
    }

    // ─────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────

    function _findEpoch(address holder) internal view returns (uint256) {
        uint256 BASE_TS = 1767225600;
        uint256 monthsFromBase = (block.timestamp + 730 days - BASE_TS) / 2629746;
        for (int256 d = -3; d <= 3; d++) {
            int256 mfb = int256(monthsFromBase) + d;
            if (mfb < 0) continue;
            uint256 year = 2026 + uint256(mfb) / 12;
            uint256 month = 1 + uint256(mfb) % 12;
            uint256 epochId = year * 100 + month;
            if (cb.balanceOf(holder, epochId) > 0) return epochId;
        }
        revert("no epoch with bonds for holder");
    }

    function _agentBuysAndTriggers(address agent, uint256 coverage)
        internal
        returns (uint256 policyId, uint256 epochId, uint256 bondAmount)
    {
        usdc.mint(agent, coverage);
        vm.prank(agent);
        usdc.approve(address(router), type(uint256).max);

        // Relayer-mediated purchase (post-PR #86: buyer pays, relayer signs).
        vm.prank(relayer);
        policyId = router.purchasePolicyFor(productId, coverage, "BTC", agent);

        // Settle as the registered shield (mock direct-settle).
        vm.prank(address(shield));
        pm.settlePolicy(productId, policyId, true);

        // Find the issued bond.
        epochId = _findEpoch(agent);
        bondAmount = cb.balanceOf(agent, epochId);
        require(bondAmount > 0, "no bond issued");
    }

    // ─────────────────────────────────────────────────────────────────
    // 1. AI agent full lifecycle
    // ─────────────────────────────────────────────────────────────────
    function test_E2E_AIAgent_FullLifecycle() public {
        (uint256 policyId, uint256 epochId, uint256 bondAmount) = _agentBuysAndTriggers(aiAgent, 1_000e6);

        // Policy is owned by the agent.
        PolicyManagerV2.PolicyRecord memory rec = pm.getPolicy(productId, policyId);
        assertEq(rec.buyer, aiAgent, "policy.buyer == aiAgent");

        // Bond is registered against the agent.
        assertGt(bondAmount, 0, "agent holds bond NFT");

        // Warp past maturity and redeem.
        // [legacy-migration] F-10 per-user throttle: a single account may redeem
        // at most MAX_USER_REDEEM_BPS (10%) of the per-epoch cap per 7-day
        // throttle-epoch. With a 70M-LUMINA reserve at the mock's $0.01 price the
        // per-user cap is ~$756, below the $800 bond. Split the full redemption
        // across two consecutive throttle-epochs to keep the "fully redeemed"
        // intent while respecting the throttle.
        vm.warp(cb.maturityDate(epochId) + 1);
        uint256 luminaBefore = token.balanceOf(aiAgent);
        uint256 firstChunk = bondAmount / 2; // <= per-user cap
        vm.prank(aiAgent);
        vault.redeemBond(epochId, firstChunk);

        // Advance one throttle-epoch (7 days) so the per-user counter resets.
        vm.warp(block.timestamp + 7 days);
        vm.prank(aiAgent);
        vault.redeemBond(epochId, bondAmount - firstChunk);
        uint256 luminaAfter = token.balanceOf(aiAgent);

        assertGt(luminaAfter, luminaBefore, "agent received LUMINA at redemption");
        assertEq(cb.balanceOf(aiAgent, epochId), 0, "bond fully redeemed");
    }

    // ─────────────────────────────────────────────────────────────────
    // 2. Human bond trader: buys a listing, redeems at maturity
    // ─────────────────────────────────────────────────────────────────
    function test_E2E_BondTrader_BuyHoldRedeem() public {
        // Seed an agent so they can list bonds onto the marketplace.
        (, uint256 epochId, uint256 bondAmount) = _agentBuysAndTriggers(humanSeller, 1_000e6);
        require(bondAmount >= 100, "seller did not get enough bonds for the test");

        // Seller approves marketplace and lists 100 bonds at $50.
        vm.startPrank(humanSeller);
        cb.setApprovalForAll(address(marketplace), true);
        uint256 listingId = marketplace.list(epochId, 100, 50e6);
        vm.stopPrank();

        // Buyer pays USDC, receives bond NFT.
        usdc.mint(humanBuyer, 100e6);
        vm.startPrank(humanBuyer);
        usdc.approve(address(marketplace), type(uint256).max);
        marketplace.executeBuy(listingId);
        vm.stopPrank();
        assertEq(cb.balanceOf(humanBuyer, epochId), 100, "buyer holds 100 bonds");

        // Hold to maturity, then redeem.
        vm.warp(cb.maturityDate(epochId) + 1);
        uint256 luminaBefore = token.balanceOf(humanBuyer);
        vm.prank(humanBuyer);
        vault.redeemBond(epochId, 100);
        assertGt(token.balanceOf(humanBuyer), luminaBefore, "buyer received LUMINA on redemption");
    }

    // ─────────────────────────────────────────────────────────────────
    // 3. Cross-component: agent → trigger → bond → list → buyer redeems
    // ─────────────────────────────────────────────────────────────────
    function test_E2E_CrossComponent_AgentSellsBonds() public {
        // Agent buys policy via relayer, oracle triggers, bond emitted.
        (, uint256 epochId, uint256 bondAmount) = _agentBuysAndTriggers(aiAgent, 1_000e6);
        require(bondAmount >= 200, "agent did not get enough bonds");

        // Agent (or its owner) lists 200 bonds at $40.
        vm.startPrank(aiAgent);
        cb.setApprovalForAll(address(marketplace), true);
        uint256 listingId = marketplace.list(epochId, 200, 40e6);
        vm.stopPrank();

        // Snapshot agent's USDC before the sale completes.
        uint256 agentUsdcBefore = usdc.balanceOf(aiAgent);

        // Buyer purchases.
        usdc.mint(humanBuyer, 100e6);
        vm.startPrank(humanBuyer);
        usdc.approve(address(marketplace), type(uint256).max);
        marketplace.executeBuy(listingId);
        vm.stopPrank();

        // [legacy-migration] F-14 pull-payment: the sale credits the agent's
        // proceeds to pendingWithdrawals (balance unchanged until withdraw()).
        vm.prank(aiAgent);
        marketplace.withdraw();

        // Agent received USDC (price minus fees), buyer holds the NFT.
        assertGt(usdc.balanceOf(aiAgent), agentUsdcBefore, "agent received USDC from sale");
        assertEq(cb.balanceOf(humanBuyer, epochId), 200, "buyer holds 200 bonds");

        // Buyer redeems at maturity.
        vm.warp(cb.maturityDate(epochId) + 1);
        vm.prank(humanBuyer);
        vault.redeemBond(epochId, 200);
        assertGt(token.balanceOf(humanBuyer), 0, "buyer received LUMINA on redemption");
    }

    // ─────────────────────────────────────────────────────────────────
    // 4. Global invariants survive a multi-step lifecycle
    // ─────────────────────────────────────────────────────────────────
    function test_E2E_GlobalInvariants_HoldAfterFullLifecycle() public {
        // INV-1: total supply is 100M post-init and remains so until burns.
        uint256 totalSupplyAtBoot = token.totalSupply();
        assertEq(totalSupplyAtBoot, 100_000_000e18, "INV-1: 100M total supply at init");

        // Run the agent-sells-bonds scenario end-to-end.
        (, uint256 epochId, uint256 bondAmount) = _agentBuysAndTriggers(aiAgent, 1_000e6);

        // INV-3: every policy created via purchasePolicyFor records buyer == arg.
        // Already checked in test 1; here we sanity-check totals.
        assertEq(pm.totalPolicies(), 1, "exactly one policy created in this run");

        // INV-5: ClaimBond conservation across marketplace flows.
        uint256 bondBefore = cb.balanceOf(aiAgent, epochId);
        require(bondBefore >= 100, "need >=100 bonds for the sub-flow");

        vm.startPrank(aiAgent);
        cb.setApprovalForAll(address(marketplace), true);
        uint256 listingId = marketplace.list(epochId, 100, 50e6);
        vm.stopPrank();

        // After list: 100 bonds escrowed in marketplace, agent has bondBefore-100.
        assertEq(cb.balanceOf(aiAgent, epochId), bondBefore - 100, "100 bonds escrowed");
        assertEq(cb.balanceOf(address(marketplace), epochId), 100, "marketplace holds the escrow");

        usdc.mint(humanBuyer, 100e6);
        vm.startPrank(humanBuyer);
        usdc.approve(address(marketplace), type(uint256).max);
        marketplace.executeBuy(listingId);
        vm.stopPrank();

        // After buy: marketplace has 0, agent has bondBefore-100, buyer has 100.
        assertEq(cb.balanceOf(address(marketplace), epochId), 0, "marketplace escrow cleared");
        assertEq(cb.balanceOf(humanBuyer, epochId), 100, "buyer received 100 bonds");
        assertEq(cb.balanceOf(aiAgent, epochId), bondBefore - 100, "agent unchanged after sale");

        // INV-1 bis: token supply should not have changed during marketplace ops.
        assertEq(token.totalSupply(), totalSupplyAtBoot, "INV-1: total supply intact through marketplace flow");

        // bondAmount must equal what _agentBuysAndTriggers reported.
        assertEq(bondBefore, bondAmount, "_agentBuysAndTriggers consistency");
    }
}
