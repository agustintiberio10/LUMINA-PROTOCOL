// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {FlashBTCShield1h} from "../../src/products/FlashBTCShield1h.sol";
import {FlashShieldAdapter} from "../../src/shields/FlashShieldAdapter.sol";
import {PolicyManagerV2} from "../../src/core/PolicyManagerV2.sol";
import {CoverRouterV2} from "../../src/core/CoverRouterV2.sol";

/// @title ShieldsE2E.t.sol — Sprint T-30c integration (Phase C, TODOs closed)
/// @notice End-to-end coverage of the new flash-shield set wired through the
///         FlashShieldAdapter into PolicyManagerV2 + CoverRouterV2, with a
///         MockBondVault standing in for the real vault (already covered by
///         BondVaultTest.t.sol). Confirms the Sprint T-30b adapter bridge
///         delivers the legacy IShieldV2 surface PolicyManagerV2 expects.
/// @dev    via_ir gotcha: all `vm.warp` calls use absolute timestamps.
///         ChainGuard requires Base Sepolia (84532) or Base mainnet (8453).

contract MockChainlinkAggregator {
    int256 public answer;
    uint256 public updatedAt;
    uint8 public constant decimals = 8;

    constructor(int256 _a, uint256 _u) {
        answer = _a;
        updatedAt = _u;
    }

    function setAnswer(int256 a, uint256 u) external {
        answer = a;
        updatedAt = u;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

contract MockSequencerFeed {
    int256 public answer;
    uint256 public startedAt;

    constructor() {
        startedAt = block.timestamp > 2 hours ? block.timestamp - 2 hours : 0;
        answer = 0;
    }

    function setDown(bool down) external {
        answer = down ? int256(1) : int256(0);
        startedAt = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, startedAt, startedAt, 1);
    }
}

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockTWAPBurner {
    uint256 public totalReceived;
    address public lastFrom;

    function receivePremium(uint256 amount) external {
        totalReceived += amount;
        lastFrom = msg.sender;
        // Pull the approved USDC so the router's allowance/balance reconciles.
        (bool ok, bytes memory data) = address(msg.sender).call(abi.encodeWithSignature("usdc()"));
        if (ok && data.length >= 32) {
            address usdcAddr = abi.decode(data, (address));
            (bool ok2,) = usdcAddr.call(
                abi.encodeWithSignature("transferFrom(address,address,uint256)", msg.sender, address(this), amount)
            );
            require(ok2, "TWAPBurner: pull failed");
        }
    }
}

contract MockBondVault {
    uint256 public cap = 1_000_000; // integer dollars
    uint256 public totalReserved;
    uint256 public lastPayoutUSD;
    address public lastTo;
    uint256 public issuedCount;

    function availableCapacityUSD() external view returns (uint256) {
        uint256 reservedDollars = totalReserved / 1e18;
        if (cap <= reservedDollars) return 0;
        return cap - reservedDollars;
    }

    function issueBond(address to, uint256 usdPayout) external {
        lastTo = to;
        lastPayoutUSD = usdPayout;
        issuedCount++;
    }

    function reserveCapacity(uint256 amount) external {
        totalReserved += amount;
    }

    function releaseReservation(uint256 amount) external {
        totalReserved -= amount;
    }

    function commitReservation(uint256 amount) external {
        totalReserved -= amount;
    }
}

contract ShieldsE2ETest is Test {
    FlashBTCShield1h shield;
    MockChainlinkAggregator oracle;
    MockSequencerFeed sequencer;

    address router = makeAddr("router");
    address holder = makeAddr("holder");

    uint256 constant T0 = 1_800_000_000;
    int256 constant STRIKE = 50_000e8;
    uint256 constant COVERAGE = 10_000e6;
    uint32 constant WINDOW = 3600;

    function setUp() public {
        vm.warp(T0);
        oracle = new MockChainlinkAggregator(STRIKE, T0);
        sequencer = new MockSequencerFeed();
        shield = FlashBTCShield1h(address(new ERC1967Proxy(address(new FlashBTCShield1h()), abi.encodeCall(FlashBTCShield1h.initialize, (router, address(oracle), address(sequencer))))));
    }

    // ── 1. purchase-through-router happy path (slim shield, no adapter) ──────
    function testPurchasePolicy_Through_CoverRouter() public {
        vm.prank(router);
        shield.createPolicy(101, holder, COVERAGE, uint64(T0), uint64(T0 + WINDOW));

        (address h, uint256 cov, uint256 strike, uint64 start, uint64 end, bool finalized) = shield.getPolicyInfo(101);
        assertEq(h, holder, "holder stored");
        assertEq(cov, COVERAGE, "coverage stored");
        assertEq(strike, uint256(STRIKE), "strike snapshot");
        assertEq(start, uint64(T0), "start ts stored");
        assertEq(end, uint64(T0 + WINDOW), "expiry stored");
        assertFalse(finalized, "policy not yet finalized");
    }

    // ── 2. trigger flow (slim shield, no adapter) ────────────────────────────
    function testTrigger_EmitsBond() public {
        vm.prank(router);
        shield.createPolicy(202, holder, COVERAGE, uint64(T0), uint64(T0 + WINDOW));

        vm.warp(T0 + 300);
        int256 dropped = (STRIKE * 9700) / 10_000;
        oracle.setAnswer(dropped, T0 + 300);

        vm.prank(router);
        (bool triggered, uint256 payout, address h, bytes32 reason) = shield.verifyAndCalculate(202);

        assertTrue(triggered, "must trigger");
        assertEq(payout, (COVERAGE * 8000) / 10_000, "payout = 80%");
        assertEq(h, holder, "holder echoed");
        assertEq(reason, bytes32("TRIGGER_DROP"), "reason TRIGGER_DROP");

        (,,,,, bool finalized) = shield.getPolicyInfo(202);
        assertTrue(finalized, "finalized after verify");
    }
}

/// @title ShieldsE2EFullTest — Sprint T-30c Phase C (full lifecycle)
/// @notice Two integration tests that close the T-30a TODOs by routing
///         purchase + trigger through the full CoverRouterV2 →
///         PolicyManagerV2 → FlashShieldAdapter → BaseFlashShield stack,
///         with a MockBondVault verifying that bond issuance fires on trigger.
contract ShieldsE2EFullTest is Test {
    FlashBTCShield1h shield;
    FlashShieldAdapter adapterImpl;
    FlashShieldAdapter adapter;
    PolicyManagerV2 pmImpl;
    PolicyManagerV2 pm;
    CoverRouterV2 routerImpl;
    CoverRouterV2 coverRouter;
    MockBondVault bondVault;
    MockUSDC usdc;
    MockTWAPBurner twapBurner;
    MockChainlinkAggregator oracle;
    MockSequencerFeed sequencer;

    address buyer = makeAddr("buyer");

    uint256 constant T0 = 1_800_000_000;
    int256 constant STRIKE = 50_000e8;
    uint256 constant COVERAGE = 10_000e6; // $10k
    uint32 constant WINDOW = 3600; // 1h
    bytes32 constant PRODUCT_ID = keccak256("FLASHBTC1H-001");

    function setUp() public {
        // Base Sepolia chain id so ChainGuard.requireValidChain() passes.
        vm.chainId(84532);
        vm.warp(T0);

        oracle = new MockChainlinkAggregator(STRIKE, T0);
        sequencer = new MockSequencerFeed();
        usdc = new MockUSDC();
        twapBurner = new MockTWAPBurner();
        bondVault = new MockBondVault();

        // PolicyManagerV2 proxy
        pmImpl = new PolicyManagerV2();
        ERC1967Proxy pmProxy = new ERC1967Proxy(
            address(pmImpl), abi.encodeWithSelector(PolicyManagerV2.initialize.selector, address(bondVault))
        );
        pm = PolicyManagerV2(address(pmProxy));

        // CoverRouterV2 proxy wired to PM + USDC + TWAPBurner
        routerImpl = new CoverRouterV2();
        ERC1967Proxy routerProxy = new ERC1967Proxy(
            address(routerImpl),
            abi.encodeWithSelector(CoverRouterV2.initialize.selector, address(usdc), address(pm), address(twapBurner))
        );
        coverRouter = CoverRouterV2(address(routerProxy));

        // Wire PM ↔ CoverRouter
        pm.setRouter(address(coverRouter));

        // Adapter proxy (uninitialized) + shield wired with adapter as router
        adapterImpl = new FlashShieldAdapter();
        ERC1967Proxy adapterProxy = new ERC1967Proxy(address(adapterImpl), "");
        adapter = FlashShieldAdapter(address(adapterProxy));
        shield = FlashBTCShield1h(address(new ERC1967Proxy(address(new FlashBTCShield1h()), abi.encodeCall(FlashBTCShield1h.initialize, (address(adapter), address(oracle), address(sequencer))))));
        adapter.initialize(address(shield), PRODUCT_ID);

        // Register product in PM + configure premium params on CoverRouter
        pm.registerProduct(PRODUCT_ID, address(adapter));
        coverRouter.configureProduct(
            PRODUCT_ID,
            8000, // payoutRatioBps (80%)
            18, // triggerProbBps (FlashBTC1h PoR x 10000 rounded)
            20000, // marginBps (2.00x)
            WINDOW,
            true
        );

        // Fund buyer with USDC and approve router for premium pull.
        usdc.mint(buyer, 1_000_000e6);
        vm.prank(buyer);
        usdc.approve(address(coverRouter), type(uint256).max);
    }

    // ── 1. Full purchase through CoverRouter (TODO #1 closed) ────────────────
    /// @notice testPurchasePolicy_Through_CoverRouter_Full
    /// @dev    Buyer calls CoverRouterV2.purchasePolicy with $10k coverage.
    ///         Verifies premium is pulled, policy is recorded in PM, the
    ///         adapter forwarded into the shield with a strike snapshot, and
    ///         the bondVault reservation was created.
    function testPurchasePolicy_Through_CoverRouter_Full() public {
        uint256 buyerBalBefore = usdc.balanceOf(buyer);
        (uint256 expectedPremium, uint256 expectedPayout) = coverRouter.quotePremium(PRODUCT_ID, COVERAGE);

        vm.prank(buyer);
        uint256 policyId = coverRouter.purchasePolicy(PRODUCT_ID, COVERAGE, bytes32("BTC"));

        assertEq(policyId, 1, "adapter assigns id=1 on first purchase");

        // Premium pulled from buyer; router forwarded full amount to TWAPBurner.
        uint256 buyerBalAfter = usdc.balanceOf(buyer);
        assertEq(buyerBalBefore - buyerBalAfter, expectedPremium, "buyer paid quoted premium");
        assertEq(twapBurner.totalReceived(), expectedPremium, "TWAPBurner received full premium");
        assertEq(usdc.balanceOf(address(twapBurner)), expectedPremium, "premium custody at TWAPBurner");

        // PolicyManager has a record at productId/policyId.
        PolicyManagerV2.PolicyRecord memory rec = pm.getPolicy(PRODUCT_ID, policyId);
        assertEq(rec.buyer, buyer, "PM stored buyer");
        assertEq(rec.coverageAmount, COVERAGE, "PM stored coverage");
        assertEq(rec.payoutAmount, expectedPayout, "PM stored payout = 80% coverage");
        assertEq(rec.shield, address(adapter), "PM stored adapter as the shield");
        assertFalse(rec.triggered, "policy not yet triggered");
        assertFalse(rec.expired, "policy not yet expired");

        // Adapter forwarded into the underlying slim shield with a strike snapshot.
        (address h, uint256 cov, uint256 strike,, uint64 end, bool finalized) = shield.getPolicyInfo(policyId);
        assertEq(h, buyer, "slim shield holder = buyer");
        assertEq(cov, COVERAGE, "slim shield coverage");
        assertEq(strike, uint256(STRIKE), "slim shield strike snapshot");
        assertEq(end, uint64(T0 + WINDOW), "slim shield expiry");
        assertFalse(finalized, "slim shield not yet finalized");

        // BondVault reservation moved in step.
        uint256 expectedReservation = (expectedPayout / 1e6) * 1e18; // 18-dec USD-wei
        assertEq(bondVault.totalReserved(), expectedReservation, "bondVault reserved capacity at purchase");
    }

    // ── 2. Full trigger flow emits bond via PolicyManagerV2 (TODO #2 closed) ──
    /// @notice testTrigger_EmitsBond_Full
    /// @dev    Purchase a policy, drop the oracle 3% (above 2.5% trigger), call
    ///         CoverRouter.submitTrigger → PM.triggerPayout → adapter →
    ///         slim shield. Verifies the policy is marked triggered, the
    ///         reservation is committed, and bondVault.issueBond was fired with
    ///         the integer-dollar payout for the buyer.
    function testTrigger_EmitsBond_Full() public {
        vm.prank(buyer);
        uint256 policyId = coverRouter.purchasePolicy(PRODUCT_ID, COVERAGE, bytes32("BTC"));

        // 5 minutes in, BTC drops 3%.
        vm.warp(T0 + 300);
        int256 dropped = (STRIKE * 9700) / 10_000;
        oracle.setAnswer(dropped, T0 + 300);

        uint256 reservedBefore = bondVault.totalReserved();
        assertGt(reservedBefore, 0, "reservation in place pre-trigger");

        // Anyone can submit a trigger; use a permissionless caller.
        address keeper = makeAddr("keeper");
        vm.prank(keeper);
        coverRouter.submitTrigger(PRODUCT_ID, policyId, "");

        // PolicyManagerV2 marked triggered + decremented active count.
        PolicyManagerV2.PolicyRecord memory rec = pm.getPolicy(PRODUCT_ID, policyId);
        assertTrue(rec.triggered, "policy marked triggered");
        assertFalse(rec.expired, "policy not expired");

        // BondVault.issueBond fired with payout = $8000 (80% of $10k coverage).
        uint256 expectedPayoutUSD = ((COVERAGE * 8000) / 10_000) / 1e6;
        assertEq(bondVault.issuedCount(), 1, "exactly one bond issued");
        assertEq(bondVault.lastTo(), buyer, "bond minted to buyer");
        assertEq(bondVault.lastPayoutUSD(), expectedPayoutUSD, "bond face value matches payout");

        // Reservation committed (totalReservedUSD decremented).
        assertEq(bondVault.totalReserved(), 0, "reservation committed at trigger");

        // Slim shield finalized.
        (,,,,, bool finalized) = shield.getPolicyInfo(policyId);
        assertTrue(finalized, "slim shield finalized after verify");

        // PolicyManagerV2 stats reflect the trigger.
        (, uint256 active,, uint256 bondsIssuedUSD,) = pm.getStats();
        assertEq(active, 0, "active policies back to 0");
        assertEq(bondsIssuedUSD, expectedPayoutUSD, "bonds issued counter advanced");
    }
}
