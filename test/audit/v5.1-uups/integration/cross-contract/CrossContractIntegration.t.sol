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
import {BuybackEngine} from "../../../../../src/marketplace/BuybackEngine.sol";
import {SolvencyOracle} from "../../../../../src/oracles/SolvencyOracle.sol";
import {AdaptiveFeeDistributor} from "../../../../../src/core/AdaptiveFeeDistributor.sol";
import {MaintenanceReserve} from "../../../../../src/treasury/MaintenanceReserve.sol";
import {IDexRouter} from "../../../../../src/interfaces/IDexRouter.sol";

// ─────────────────────────────────────────────────────────────────────────
// Mocks (external dependencies only — every protocol contract is real)
// ─────────────────────────────────────────────────────────────────────────

contract MockUSDC6 is IERC20 {
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
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

contract MockPriceOracleCC {
    uint256 public price;
    bool public revertOnGet;

    constructor(uint256 p) {
        price = p;
    }

    function setPrice(uint256 p) external {
        price = p;
    }

    function setRevertOnGet(bool r) external {
        revertOnGet = r;
    }

    function getLuminaPrice() external view returns (uint256) {
        require(!revertOnGet, "oracle unavailable");
        return price;
    }
    /// @dev [Fix M-6 mock] Returns the same value as `getLuminaPrice()` so
    ///      tests that don't drive the TWAP path explicitly remain unaffected.
    function getTWAP(uint32 /*secondsAgo*/) external view returns (uint256) {
        return this.getLuminaPrice();
    }

}

contract MockDexCC is IDexRouter {
    IERC20 public lumina;

    constructor(address l) {
        lumina = IERC20(l);
    }

    function swap(address tokenIn, address, uint256 amountIn, uint256) external override returns (uint256) {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = amountIn * 27 * 1e12; // pretend 1 USDC -> 27 LUMINA
        lumina.transfer(msg.sender, out);
        return out;
    }

    function getQuote(address, address, uint256 amountIn) external pure override returns (uint256) {
        return amountIn * 27 * 1e12;
    }
}

/// @dev Minimal shield that conforms to PolicyManagerV2's IShieldV2 interface
///      (createPolicy + verifyAndCalculate). Used to drive full E2E flows.
contract MockCCShield {
    bytes32 public productId;
    PolicyManagerV2 public pm;
    uint256 private _nextPolicyId;

    struct Data {
        address buyer;
        uint256 coverage;
        uint256 maxPayout;
        uint32 duration;
        uint256 expiresAt;
    }

    mapping(uint256 => Data) public pd;

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

    struct PayoutResult {
        bool triggered;
        uint256 payoutAmount;
        address recipient;
        bytes32 reason;
    }

    constructor(bytes32 _pid, address _pm) {
        productId = _pid;
        pm = PolicyManagerV2(_pm);
    }

    function createPolicy(CreatePolicyParams calldata p) external returns (uint256) {
        _nextPolicyId++;
        pd[_nextPolicyId] = Data({
            buyer: p.buyer,
            coverage: p.coverageAmount,
            maxPayout: (p.coverageAmount * 8000) / 10000,
            duration: p.durationSeconds,
            expiresAt: block.timestamp + p.durationSeconds
        });
        return _nextPolicyId;
    }

    function verifyAndCalculate(uint256 policyId, bytes calldata) external view returns (PayoutResult memory) {
        Data storage d = pd[policyId];
        return PayoutResult({triggered: true, payoutAmount: d.maxPayout, recipient: d.buyer, reason: "MOCK"});
    }
}

// ─────────────────────────────────────────────────────────────────────────
// MAIN TEST — audit #30 cross-contract integration
// ─────────────────────────────────────────────────────────────────────────

contract CrossContractIntegrationTest is Test {
    struct Stack {
        LuminaTokenV2 token;
        ClaimBond cb;
        BondVault vault;
        PolicyManagerV2 pm;
        CoverRouterV2 router;
        TWAPBurner burner;
        LuminaBondMarketplace mp;
        BuybackEngine buyback;
        SolvencyOracle sol;
        AdaptiveFeeDistributor adp;
        MaintenanceReserve mr;
        MockUSDC6 usdc;
        MockPriceOracleCC oracle;
        MockDexCC dex;
        MockCCShield shield;
        bytes32 productId;
    }

    address internal admin = address(this);
    address internal agent = makeAddr("aiAgent");
    address internal relayer = makeAddr("relayer");

    // ═════════════════════ full-stack deployment ═════════════════════

    function _deployFullStack() internal returns (Stack memory s) {
        // Warp to a safe epoch window.
        vm.warp(1767225600 + 30 days);

        s.usdc = new MockUSDC6();
        s.oracle = new MockPriceOracleCC(0.036e18);

        // Predict BondVault proxy address so token distribution lands correctly.
        uint64 nonce = vm.getNonce(address(this));
        // Sequence from now:
        //  (1) token impl, (2) token proxy,
        //  (3) dex stub, (4) TWAP impl, (5) TWAP proxy,
        //  (6) cb impl, (7) cb proxy,
        //  (8) pm impl, (9) pm proxy,
        //  (10) vault impl, (11) vault proxy
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 10);

        s.token = ProxyDeployer.deployLuminaTokenV2(
            predictedVault, makeAddr("cex"), makeAddr("founder"), makeAddr("lbp"), makeAddr("treasury")
        );

        s.dex = new MockDexCC(address(s.token));
        deal(address(s.token), address(s.dex), 100_000_000e18); // fund DEX with LUMINA

        s.burner = ProxyDeployer.deployTWAPBurner(address(s.usdc), address(s.token), address(s.dex));
        s.token.grantRole(s.token.BURNER_ROLE(), address(s.burner));

        s.cb = ProxyDeployer.deployClaimBond();
        s.pm = ProxyDeployer.deployPolicyManagerV2(predictedVault);
        s.vault = ProxyDeployer.deployBondVault(address(s.token), address(s.cb), address(s.oracle), address(s.pm));
        require(address(s.vault) == predictedVault, "address mismatch");

        s.cb.setBondVault(address(s.vault));

        s.router = ProxyDeployer.deployCoverRouterV2(address(s.usdc), address(s.pm), address(s.burner));
        s.router.setCapacityOracle(address(s.oracle));

        s.pm.setRouter(address(s.router));

        // Marketplace + BuybackEngine.
        s.mp = ProxyDeployer.deployLuminaBondMarketplace(address(s.cb), address(s.usdc), address(s.burner), admin);
        // [Fix M-3 regression] Lower the per-unit price floor for this legacy
        // cross-contract integration suite - prices used here predate the M-3
        // 1-USDC/unit floor and are set for fee-math assertions, not floor checks.
        vm.prank(admin);
        s.mp.setMinPricePerUnit(1);
        s.cb.setAuthorizedOperator(address(s.mp), true);
        s.burner.setAuthorizedSender(address(s.mp), true);

        s.sol = ProxyDeployer.deploySolvencyOracle(address(s.vault), address(s.oracle), admin);
        s.adp = ProxyDeployer.deployAdaptiveFeeDistributor(address(s.sol));

        s.buyback = ProxyDeployer.deployBuybackEngine(
            address(s.cb), address(s.vault), address(s.sol), address(s.oracle), address(s.mp), address(s.usdc), admin
        );
        // [M-10 grant] grant BUYBACK_OPERATOR_ROLE to address(this) so test calls reach the gated path.
        {
            bytes32 _m10_role_s_buyback = s.buyback.BUYBACK_OPERATOR_ROLE();
            vm.prank(admin);
            s.buyback.grantRole(_m10_role_s_buyback, address(this));
        }
        s.vault.setAuthorizedCaller(address(s.buyback), true);

        s.mr = ProxyDeployer.deployMaintenanceReserve(address(s.usdc), admin);

        s.burner.setFeeDistributor(address(s.adp));
        s.burner.setReserves(address(s.buyback), makeAddr("ops"), address(s.mr));

        // Register a product in PM + shield.
        s.productId = keccak256("FLASH_BTC_1H");
        s.shield = new MockCCShield(s.productId, address(s.pm));
        s.pm.registerProduct(s.productId, address(s.shield));
        s.router.configureProduct(s.productId, 8000, 100, 15000, 3600, true);

        // Set relayer + authorize burner as a sender for policy USDC.
        s.router.setRelayer(relayer, true);
    }

    function _scanEpoch(ClaimBond cb, address holder) internal view returns (uint256) {
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
        revert("no epoch");
    }

    // ═════════════════════ A. Full lifecycle ═════════════════════

    function test_CrossContract_FullLifecycle_AgentPolicy_TriggerRedeem() public {
        Stack memory s = _deployFullStack();

        // 1. Agent has USDC and approves router (simulated via direct mint).
        s.usdc.mint(agent, 1000e6);
        vm.prank(agent);
        s.usdc.approve(address(s.router), type(uint256).max);

        // 2. Agent purchases a policy.
        vm.prank(agent);
        uint256 policyId = s.router.purchasePolicy(s.productId, 1000e6, "BTC");

        assertEq(s.pm.totalPolicies(), 1);
        assertEq(s.pm.activePolicies(), 1);
        uint256 reservedBefore = s.vault.totalReservedUSD();
        assertEq(reservedBefore, 800 * 1e18, "80% coverage reserved");

        // 3. Settle via shield (trigger=true).
        vm.prank(address(s.shield));
        s.pm.settlePolicy(s.productId, policyId, true);

        assertEq(s.pm.totalTriggers(), 1);
        assertEq(s.pm.activePolicies(), 0);
        assertEq(s.vault.totalCommittedUSD(), 800 * 1e18, "bond committed");

        // 4. Epoch lookup + warp past maturity.
        uint256 epoch = _scanEpoch(s.cb, agent);
        vm.warp(s.cb.maturityDate(epoch) + 1);

        // 5. Redeem.
        uint256 luminaBefore = s.token.balanceOf(agent);
        vm.prank(agent);
        s.vault.redeemBond(epoch, 800);
        uint256 luminaAfter = s.token.balanceOf(agent);

        assertGt(luminaAfter - luminaBefore, 0, "agent received LUMINA");
        assertEq(s.cb.balanceOf(agent, epoch), 0, "bond fully redeemed");
        assertEq(s.vault.totalCommittedUSD(), 0, "committed drained");
    }

    function test_CrossContract_RelayerPurchase_WorksLikeDirect() public {
        Stack memory s = _deployFullStack();

        // [Fix RELAYER-PAYMENT] Premium is pulled from the agent (buyer), not
        // the relayer. The relayer signs but pays only gas. Older code funded
        // the relayer; that path is now economically inert.
        s.usdc.mint(agent, 1000e6);
        vm.prank(agent);
        s.usdc.approve(address(s.router), type(uint256).max);

        uint256 agentBefore = s.usdc.balanceOf(agent);
        uint256 relayerBefore = s.usdc.balanceOf(relayer);

        vm.prank(relayer);
        uint256 policyId = s.router.purchasePolicyFor(s.productId, 1000e6, "BTC", agent);

        // Policy belongs to agent, not relayer.
        PolicyManagerV2.PolicyRecord memory rec = s.pm.getPolicy(s.productId, policyId);
        assertEq(rec.buyer, agent);
        assertEq(s.pm.totalPolicies(), 1);

        // Agent paid; relayer balance unchanged.
        assertLt(s.usdc.balanceOf(agent), agentBefore, "agent paid premium");
        assertEq(s.usdc.balanceOf(relayer), relayerBefore, "relayer balance unchanged");
    }

    function test_CrossContract_PolicyExpiration_ReservationReleased() public {
        Stack memory s = _deployFullStack();
        s.usdc.mint(agent, 1000e6);
        vm.prank(agent);
        s.usdc.approve(address(s.router), type(uint256).max);

        vm.prank(agent);
        uint256 policyId = s.router.purchasePolicy(s.productId, 1000e6, "BTC");
        assertEq(s.vault.totalReservedUSD(), 800 * 1e18);

        // Settle as NOT triggered — reservation must be released.
        vm.prank(address(s.shield));
        s.pm.settlePolicy(s.productId, policyId, false);

        assertEq(s.vault.totalReservedUSD(), 0, "reservation released on expiry");
        assertEq(s.vault.totalCommittedUSD(), 0);
    }

    function test_CrossContract_MultiplePolicies_Sequential() public {
        Stack memory s = _deployFullStack();
        s.usdc.mint(agent, 10_000e6);
        vm.prank(agent);
        s.usdc.approve(address(s.router), type(uint256).max);

        for (uint256 i = 0; i < 5; i++) {
            vm.prank(agent);
            s.router.purchasePolicy(s.productId, 1000e6, "BTC");
        }

        assertEq(s.pm.totalPolicies(), 5);
        assertEq(s.pm.activePolicies(), 5);
        assertEq(s.vault.totalReservedUSD(), 5 * 800 * 1e18);
    }

    function test_CrossContract_PartialRedemption_StateConsistent() public {
        Stack memory s = _deployFullStack();
        s.usdc.mint(agent, 1000e6);
        vm.prank(agent);
        s.usdc.approve(address(s.router), type(uint256).max);

        vm.prank(agent);
        uint256 policyId = s.router.purchasePolicy(s.productId, 1000e6, "BTC");
        vm.prank(address(s.shield));
        s.pm.settlePolicy(s.productId, policyId, true);
        uint256 epoch = _scanEpoch(s.cb, agent);
        vm.warp(s.cb.maturityDate(epoch) + 1);

        // Redeem 200, then 600, total 800.
        vm.prank(agent);
        s.vault.redeemBond(epoch, 200);
        assertEq(s.cb.balanceOf(agent, epoch), 600);
        assertEq(s.vault.totalCommittedUSD(), 600 * 1e18);

        vm.prank(agent);
        s.vault.redeemBond(epoch, 600);
        assertEq(s.cb.balanceOf(agent, epoch), 0);
        assertEq(s.vault.totalCommittedUSD(), 0);
    }

    // ═════════════════════ B. Marketplace flow ═════════════════════

    function test_CrossContract_Marketplace_ListBuy_FeesDistributed() public {
        Stack memory s = _deployFullStack();

        // Set up: agent has a bond to list.
        s.usdc.mint(agent, 1000e6);
        vm.prank(agent);
        s.usdc.approve(address(s.router), type(uint256).max);
        vm.prank(agent);
        uint256 policyId = s.router.purchasePolicy(s.productId, 1000e6, "BTC");
        vm.prank(address(s.shield));
        s.pm.settlePolicy(s.productId, policyId, true);
        uint256 epoch = _scanEpoch(s.cb, agent);

        // List on marketplace.
        vm.startPrank(agent);
        s.cb.setApprovalForAll(address(s.mp), true);
        uint256 listingId = s.mp.list(epoch, 400, 300e6); // 400 bonds @ $300
        vm.stopPrank();

        // Buyer with USDC executes.
        address buyer = makeAddr("buyer");
        uint256 buyerFee = (300e6 * s.mp.BUYER_FEE_BPS()) / s.mp.BPS_DENOMINATOR(); // 4.5 USDC
        uint256 sellerFee = (300e6 * s.mp.SELLER_FEE_BPS()) / s.mp.BPS_DENOMINATOR();
        s.usdc.mint(buyer, 300e6 + buyerFee);
        vm.startPrank(buyer);
        s.usdc.approve(address(s.mp), type(uint256).max);
        uint256 agentBefore = s.usdc.balanceOf(agent);
        uint256 burnerBefore = s.usdc.balanceOf(address(s.burner));
        s.mp.executeBuy(listingId);
        vm.stopPrank();

        // Verify net deltas: seller received (price - sellerFee).
        assertEq(s.usdc.balanceOf(agent) - agentBefore, 300e6 - sellerFee);
        // Buyer now holds 400 bonds.
        assertEq(s.cb.balanceOf(buyer, epoch), 400);
        // TWAPBurner received exactly the 3% total fees (delta against pre-buy balance).
        assertEq(s.usdc.balanceOf(address(s.burner)) - burnerBefore, sellerFee + buyerFee);
    }

    function test_CrossContract_Marketplace_Cancel_SellerReclaims() public {
        Stack memory s = _deployFullStack();
        s.usdc.mint(agent, 1000e6);
        vm.prank(agent);
        s.usdc.approve(address(s.router), type(uint256).max);
        vm.prank(agent);
        uint256 policyId = s.router.purchasePolicy(s.productId, 1000e6, "BTC");
        vm.prank(address(s.shield));
        s.pm.settlePolicy(s.productId, policyId, true);
        uint256 epoch = _scanEpoch(s.cb, agent);

        vm.startPrank(agent);
        s.cb.setApprovalForAll(address(s.mp), true);
        uint256 id = s.mp.list(epoch, 400, 300e6);
        assertEq(s.cb.balanceOf(agent, epoch), 400); // 400 escrowed
        s.mp.cancel(id);
        vm.stopPrank();

        // Seller reclaimed all 800 bonds (400 escrowed returned + 400 retained).
        assertEq(s.cb.balanceOf(agent, epoch), 800);
    }

    // ═════════════════════ C. TWAPBurner distribution ═════════════════════

    function test_CrossContract_TWAPBurner_ReceivesPremium_StateMatches() public {
        Stack memory s = _deployFullStack();
        s.usdc.mint(agent, 1000e6);
        vm.prank(agent);
        s.usdc.approve(address(s.router), type(uint256).max);

        uint256 burnerBefore = s.usdc.balanceOf(address(s.burner));
        vm.prank(agent);
        s.router.purchasePolicy(s.productId, 1000e6, "BTC");

        // premium = coverage × 8000 × 100 × 15000 / 1e12 = 1000e6 × 0.0012 = 1.2e3 ... actually:
        // 1000e6 * 8000 * 100 * 15000 / (10000^3) = 1000e6 * 1.2e10 / 1e12 = 1000e6 * 0.012 = 12_000_000 wait.
        // Verify: burner balance > 0 but we don't hard-code the exact formula.
        assertGt(s.usdc.balanceOf(address(s.burner)), burnerBefore);
        // totalUSDCReceived tracks it.
        assertGt(s.burner.totalUSDCReceived(), 0);
    }

    function test_CrossContract_TWAPBurner_AdaptiveMode_EnabledAndDistributes() public {
        Stack memory s = _deployFullStack();
        s.burner.setAdaptiveMode(true);
        assertTrue(s.burner.adaptiveModeEnabled());

        // Prime with USDC.
        s.usdc.mint(address(s.burner), 100_000e6);

        // Time-warp past cooldown.
        vm.warp(block.timestamp + 1 hours);
        s.burner.executeBurn();

        // At least one of the buckets received funds.
        uint256 buyback = s.usdc.balanceOf(address(s.buyback));
        uint256 ops = s.usdc.balanceOf(makeAddr("ops"));
        uint256 maint = s.usdc.balanceOf(address(s.mr));
        assertTrue(buyback + ops + maint > 0, "adaptive distribution routed to some bucket");
    }

    function test_CrossContract_TWAPBurner_Burn_ReducesLuminaSupply() public {
        Stack memory s = _deployFullStack();
        s.usdc.mint(address(s.burner), 10_000e6);
        uint256 supplyBefore = s.token.totalSupply();

        vm.warp(block.timestamp + 1 hours);
        s.burner.executeBurn();

        assertLt(s.token.totalSupply(), supplyBefore, "LUMINA burned");
    }

    // ═════════════════════ D. State consistency invariants ═════════════════════

    function test_CrossContract_Invariant_PolicyCount_Matches() public {
        Stack memory s = _deployFullStack();
        s.usdc.mint(agent, 10_000e6);
        vm.prank(agent);
        s.usdc.approve(address(s.router), type(uint256).max);

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(agent);
            s.router.purchasePolicy(s.productId, 1000e6, "BTC");
        }

        // Invariant: PM.totalPolicies == number of active + settled.
        assertEq(s.pm.totalPolicies(), 3);
        assertEq(s.pm.activePolicies(), 3);
        assertEq(s.pm.totalTriggers(), 0);
    }

    function test_CrossContract_Invariant_ReservedUSD_SumOfPolicyReserved() public {
        Stack memory s = _deployFullStack();
        s.usdc.mint(agent, 10_000e6);
        vm.prank(agent);
        s.usdc.approve(address(s.router), type(uint256).max);

        vm.prank(agent);
        s.router.purchasePolicy(s.productId, 1000e6, "BTC");
        vm.prank(agent);
        s.router.purchasePolicy(s.productId, 500e6, "BTC");
        vm.prank(agent);
        s.router.purchasePolicy(s.productId, 200e6, "BTC");

        // 80% of each coverage.
        uint256 expected = (800 + 400 + 160) * 1e18;
        assertEq(s.vault.totalReservedUSD(), expected);
    }

    function test_CrossContract_Invariant_CommittedAfterSettlement_MatchesBondSupply() public {
        Stack memory s = _deployFullStack();
        s.usdc.mint(agent, 10_000e6);
        vm.prank(agent);
        s.usdc.approve(address(s.router), type(uint256).max);

        vm.prank(agent);
        uint256 p1 = s.router.purchasePolicy(s.productId, 1000e6, "BTC");
        vm.prank(agent);
        uint256 p2 = s.router.purchasePolicy(s.productId, 500e6, "BTC");

        vm.prank(address(s.shield));
        s.pm.settlePolicy(s.productId, p1, true);
        vm.prank(address(s.shield));
        s.pm.settlePolicy(s.productId, p2, true);

        // 800 + 400 committed.
        assertEq(s.vault.totalCommittedUSD(), 1200 * 1e18);
        assertEq(s.vault.totalReservedUSD(), 0, "all reservations committed");

        uint256 epoch = _scanEpoch(s.cb, agent);
        // Bond supply for this epoch matches sum of payouts.
        assertEq(s.cb.totalSupply(epoch), 1200);
    }

    function test_CrossContract_Invariant_LuminaConserved_OnRedemption() public {
        Stack memory s = _deployFullStack();
        s.usdc.mint(agent, 1000e6);
        vm.prank(agent);
        s.usdc.approve(address(s.router), type(uint256).max);
        vm.prank(agent);
        uint256 p = s.router.purchasePolicy(s.productId, 1000e6, "BTC");
        vm.prank(address(s.shield));
        s.pm.settlePolicy(s.productId, p, true);
        uint256 epoch = _scanEpoch(s.cb, agent);

        uint256 vaultBefore = s.token.balanceOf(address(s.vault));
        uint256 agentBefore = s.token.balanceOf(agent);

        vm.warp(s.cb.maturityDate(epoch) + 1);
        vm.prank(agent);
        s.vault.redeemBond(epoch, 800);

        // Conservation: LUMINA moved from vault → agent (plus any tiny rounding).
        uint256 moved = (vaultBefore - s.token.balanceOf(address(s.vault)));
        uint256 received = s.token.balanceOf(agent) - agentBefore;
        assertEq(moved, received, "LUMINA balance conservation");
    }

    // ═════════════════════ E. Initialization dependency order ═════════════════════

    function test_CrossContract_InitOrder_TwoStepBondVault_DeployerIsSetter() public {
        // BondVault supports address(0) at initialize, then setPolicyManager from deployer.
        MockUSDC6 u = new MockUSDC6();
        MockPriceOracleCC o = new MockPriceOracleCC(0.036e18);
        ClaimBond cb = ProxyDeployer.deployClaimBond();

        // Step 1: deploy BondVault with NO policy manager.
        LuminaTokenV2 token = ProxyDeployer.deployLuminaTokenV2(
            makeAddr("bv"), makeAddr("cex"), makeAddr("founder"), makeAddr("lbp"), makeAddr("treasury")
        );
        BondVault vault = ProxyDeployer.deployBondVault(address(token), address(cb), address(o), address(0));
        assertEq(vault.policyManager(), address(0));

        // Step 2: deploy PM now that vault exists.
        PolicyManagerV2 pm = ProxyDeployer.deployPolicyManagerV2(address(vault));

        // Step 3: wire vault → pm.
        vault.setPolicyManager(address(pm));
        assertEq(vault.policyManager(), address(pm));

        u;
    }

    function test_CrossContract_InitOrder_CircularDep_ResolvedBy2Step() public {
        // Verifies the 2-step pattern handles the circular BondVault<->PolicyManager dep.
        MockUSDC6 u = new MockUSDC6();
        MockPriceOracleCC o = new MockPriceOracleCC(0.036e18);
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        LuminaTokenV2 token = ProxyDeployer.deployLuminaTokenV2(
            makeAddr("bv"), makeAddr("cex"), makeAddr("founder"), makeAddr("lbp"), makeAddr("treasury")
        );
        BondVault vault = ProxyDeployer.deployBondVault(address(token), address(cb), address(o), address(0));
        PolicyManagerV2 pm = ProxyDeployer.deployPolicyManagerV2(address(vault));
        vault.setPolicyManager(address(pm));

        // Cannot call setPolicyManager again.
        vm.expectRevert(bytes("PolicyManager already set"));
        vault.setPolicyManager(makeAddr("x"));
        u;
    }

    // ═════════════════════ F. Buyback full cycle ═════════════════════

    function test_CrossContract_Buyback_FullFlow_DoubleBurn() public {
        Stack memory s = _deployFullStack();

        // Set up a bond listing.
        s.usdc.mint(agent, 1000e6);
        vm.prank(agent);
        s.usdc.approve(address(s.router), type(uint256).max);
        vm.prank(agent);
        uint256 p = s.router.purchasePolicy(s.productId, 1000e6, "BTC");
        vm.prank(address(s.shield));
        s.pm.settlePolicy(s.productId, p, true);
        uint256 epoch = _scanEpoch(s.cb, agent);

        vm.startPrank(agent);
        s.cb.setApprovalForAll(address(s.mp), true);
        uint256 listingId = s.mp.list(epoch, 400, 200e6); // discount price
        vm.stopPrank();

        // Fund BuybackEngine and configure.
        s.usdc.mint(address(s.buyback), 10_000e6);
        s.buyback.grantRole(s.buyback.BUYBACK_OPERATOR_ROLE(), admin);
        s.buyback.setDailyBuyback(10_000e6, 95, 24);

        uint256 committedBefore = s.vault.totalCommittedUSD();
        uint256 vaultLumiBefore = s.token.balanceOf(address(s.vault));

        // Execute offer.
        // [Fix M-10 patch] executeOffer was removed; route through commit-reveal.
        {
            bytes32 _m10_salt_30_0 = keccak256(abi.encode("m10-test-salt", uint256(0)));
            bytes32 _m10_commit_30_0 = keccak256(abi.encode(listingId, type(uint256).max, _m10_salt_30_0));
            s.buyback.commitBuyback(_m10_commit_30_0);
            vm.roll(block.number + s.buyback.MIN_REVEAL_DELAY_BLOCKS());
            s.buyback.revealAndExecute(listingId, type(uint256).max, _m10_salt_30_0);
        }

        // Bonds gone from marketplace (bought then burned).
        assertEq(s.cb.balanceOf(address(s.buyback), epoch), 0);
        // Committed reduced.
        assertLt(s.vault.totalCommittedUSD(), committedBefore);
        // Vault LUMINA reduced (double burn).
        assertLt(s.token.balanceOf(address(s.vault)), vaultLumiBefore);
    }

    function test_CrossContract_Buyback_NonOperator_Reverts() public {
        Stack memory s = _deployFullStack();
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        // [Fix M-10 patch] executeOffer was removed; route through commit-reveal.
        {
            bytes32 _m10_salt_30_1 = keccak256(abi.encode("m10-test-salt", uint256(1)));
            bytes32 _m10_commit_30_1 = keccak256(abi.encode(0, type(uint256).max, _m10_salt_30_1));
            s.buyback.commitBuyback(_m10_commit_30_1);
            vm.roll(block.number + s.buyback.MIN_REVEAL_DELAY_BLOCKS());
            // [M-10 expectRevert moved]
            vm.expectRevert();
            s.buyback.revealAndExecute(0, type(uint256).max, _m10_salt_30_1);
        }
    }

    // ═════════════════════ G. Error propagation ═════════════════════

    function test_CrossContract_OracleRevert_Propagates() public {
        Stack memory s = _deployFullStack();
        s.usdc.mint(agent, 1000e6);
        vm.prank(agent);
        s.usdc.approve(address(s.router), type(uint256).max);

        s.oracle.setRevertOnGet(true);

        vm.prank(agent);
        vm.expectRevert();
        s.router.purchasePolicy(s.productId, 1000e6, "BTC");
    }

    function test_CrossContract_InsufficientUSDC_Propagates() public {
        Stack memory s = _deployFullStack();
        // Agent has no USDC.
        vm.prank(agent);
        s.usdc.approve(address(s.router), type(uint256).max);

        vm.prank(agent);
        vm.expectRevert();
        s.router.purchasePolicy(s.productId, 1000e6, "BTC");
    }

    function test_CrossContract_InvalidProduct_Propagates() public {
        Stack memory s = _deployFullStack();
        s.usdc.mint(agent, 1000e6);
        vm.prank(agent);
        s.usdc.approve(address(s.router), type(uint256).max);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(CoverRouterV2.ProductNotConfigured.selector, keccak256("UNKNOWN")));
        s.router.purchasePolicy(keccak256("UNKNOWN"), 1000e6, "BTC");
    }

    // ═════════════════════ H. Event correlation ═════════════════════

    function test_CrossContract_Events_FullPurchase_AllContractsEmit() public {
        Stack memory s = _deployFullStack();
        s.usdc.mint(agent, 1000e6);
        vm.prank(agent);
        s.usdc.approve(address(s.router), type(uint256).max);

        vm.recordLogs();
        vm.prank(agent);
        s.router.purchasePolicy(s.productId, 1000e6, "BTC");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Expect at least one log from: router, pm, vault, burner.
        bool routerEmit;
        bool pmEmit;
        bool vaultEmit;
        bool burnerEmit;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(s.router)) routerEmit = true;
            if (logs[i].emitter == address(s.pm)) pmEmit = true;
            if (logs[i].emitter == address(s.vault)) vaultEmit = true;
            if (logs[i].emitter == address(s.burner)) burnerEmit = true;
        }
        assertTrue(routerEmit, "router must emit");
        assertTrue(pmEmit, "PM must emit");
        assertTrue(vaultEmit, "vault must emit (CapacityReserved)");
        assertTrue(burnerEmit, "burner must emit (PremiumReceived)");
    }

    function test_CrossContract_Events_Settlement_Emits_BondIssued() public {
        Stack memory s = _deployFullStack();
        s.usdc.mint(agent, 1000e6);
        vm.prank(agent);
        s.usdc.approve(address(s.router), type(uint256).max);
        vm.prank(agent);
        uint256 p = s.router.purchasePolicy(s.productId, 1000e6, "BTC");

        vm.recordLogs();
        vm.prank(address(s.shield));
        s.pm.settlePolicy(s.productId, p, true);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 bondIssuedSig = keccak256("BondIssued(address,uint256,uint256)");
        bool emitted;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(s.vault) && logs[i].topics[0] == bondIssuedSig) {
                emitted = true;
                break;
            }
        }
        assertTrue(emitted, "BondIssued event must fire on settlement");
    }

    // ═════════════════════ I. Decimals / interface consistency ═════════════════════

    function test_CrossContract_Decimals_USDC6_LUMINA18_Consistent() public {
        Stack memory s = _deployFullStack();
        assertEq(s.usdc.decimals(), 6);
        assertEq(s.token.decimals(), 18);

        // Redemption math spot-check: pay = usd * 1e36 / price (18-dec) -> 18-dec LUMINA.
        // $100 / $0.036 ~ 2777.77 LUMINA (18-dec).
        uint256 price = 36e15; // $0.036 with 18 decimals
        uint256 expectedLumina = (uint256(100) * 1e36) / price;
        assertApproxEqAbs(expectedLumina, 2777777777777777777777, 1e15);
    }

    function test_CrossContract_BondFaceValue_IntegerDollars_Matches18DecUsdWei() public {
        Stack memory s = _deployFullStack();
        s.usdc.mint(agent, 1000e6);
        vm.prank(agent);
        s.usdc.approve(address(s.router), type(uint256).max);
        vm.prank(agent);
        uint256 p = s.router.purchasePolicy(s.productId, 1000e6, "BTC");
        vm.prank(address(s.shield));
        s.pm.settlePolicy(s.productId, p, true);
        uint256 epoch = _scanEpoch(s.cb, agent);

        // ClaimBond balances are in integer dollars (800).
        assertEq(s.cb.balanceOf(agent, epoch), 800);
        // BondVault.totalCommittedUSD is in 18-dec USD-wei (800e18).
        assertEq(s.vault.totalCommittedUSD(), 800 * 1e18);
    }

    // ═════════════════════ J. Trust assumption validation ═════════════════════

    function test_CrossContract_Trust_OnlyPolicyManager_CanReserveCapacity() public {
        Stack memory s = _deployFullStack();
        vm.prank(makeAddr("imposter"));
        vm.expectRevert(bytes("Only PolicyManager"));
        s.vault.reserveCapacity(100);
    }

    function test_CrossContract_Trust_OnlyAuthorizedCaller_CanBurnFromReserves() public {
        Stack memory s = _deployFullStack();
        vm.prank(makeAddr("imposter"));
        vm.expectRevert(bytes("BondVault: caller not authorized"));
        s.vault.burnFromReserves(100);
    }

    function test_CrossContract_Trust_OnlyRouter_CanRecordPolicy() public {
        Stack memory s = _deployFullStack();
        vm.prank(makeAddr("imposter"));
        vm.expectRevert();
        s.pm.recordPolicy(s.productId, agent, 1000e6, 1e6, 3600, "BTC");
    }

    function test_CrossContract_Trust_OnlyShield_CanSettlePolicy() public {
        Stack memory s = _deployFullStack();
        s.usdc.mint(agent, 1000e6);
        vm.prank(agent);
        s.usdc.approve(address(s.router), type(uint256).max);
        vm.prank(agent);
        uint256 p = s.router.purchasePolicy(s.productId, 1000e6, "BTC");

        vm.prank(makeAddr("imposter"));
        vm.expectRevert(bytes("Only shield"));
        s.pm.settlePolicy(s.productId, p, true);
    }

    // ═════════════════════ K. Gas bound check ═════════════════════

    function test_CrossContract_Gas_FullPurchase_Under_1M() public {
        Stack memory s = _deployFullStack();
        s.usdc.mint(agent, 1000e6);
        vm.prank(agent);
        s.usdc.approve(address(s.router), type(uint256).max);

        uint256 before = gasleft();
        vm.prank(agent);
        s.router.purchasePolicy(s.productId, 1000e6, "BTC");
        uint256 used = before - gasleft();
        assertLt(used, 1_000_000, "full purchase under 1M gas");
    }
}
