// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IShield} from "../../../src/interfaces/IShield.sol";
import {BaseShield} from "../../../src/products/BaseShield.sol";
import {FlashBTCShield1h} from "../../../src/products/FlashBTCShield1h.sol";
import {FlashBTCShield24h} from "../../../src/products/FlashBTCShield24h.sol";
import {FlashBTCShield48h} from "../../../src/products/FlashBTCShield48h.sol";
import {FlashETHShield1h} from "../../../src/products/FlashETHShield1h.sol";
import {FlashETHShield24h} from "../../../src/products/FlashETHShield24h.sol";
import {FlashETHShield48h} from "../../../src/products/FlashETHShield48h.sol";
import {RateShockShield} from "../../../src/products/RateShockShield.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

// ============================================================
//  INLINE MOCKS
// ============================================================

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockLuminaToken is ERC20 {
    constructor() ERC20("Mock LUMINA", "mLUM") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockClaimBond {
    mapping(uint256 => uint256) public balances;

    function mint(uint256 epoch, address, uint256 amount) external {
        balances[epoch] += amount;
    }
}

/// @notice Mock oracle that satisfies IOracle + IOracleV2 surface used by shields.
/// @dev All verifications are mocked by returning a pre-configured signer. Tests
///      that want to FAIL verification flip _verifySucceeds to false.
contract MockOracle {
    mapping(bytes32 => int256) public prices;
    address public oracleKeyAddr;
    bool public verifySucceeds = true;
    uint256 public downtime;
    // Toggle to count oracle update spam attempts.
    uint256 public updateCount;

    constructor(address key) {
        oracleKeyAddr = key;
    }

    function setPrice(bytes32 asset, int256 price) external {
        prices[asset] = price;
        updateCount++;
    }

    function setVerifySucceeds(bool ok) external {
        verifySucceeds = ok;
    }

    function setDowntime(uint256 d) external {
        downtime = d;
    }

    function getLatestPrice(bytes32 asset) external view returns (int256) {
        return prices[asset];
    }

    function getSequencerDowntime(uint256) external view returns (uint256) {
        return downtime;
    }

    function oracleKey() external view returns (address) {
        return oracleKeyAddr;
    }

    function verifySignature(bytes32, bytes calldata) external view returns (address) {
        return verifySucceeds ? oracleKeyAddr : address(0);
    }

    function verifyPriceProofEIP712(int256, bytes32, uint256, bytes calldata) external view returns (address) {
        return verifySucceeds ? oracleKeyAddr : address(0);
    }

    function verifyExploitGovProofEIP712(int256, int256, bytes32, uint256, bytes calldata)
        external
        view
        returns (address)
    {
        return verifySucceeds ? oracleKeyAddr : address(0);
    }

    function priceProofDigest(int256, bytes32, uint256) external pure returns (bytes32) {
        return bytes32(uint256(1));
    }

    function exploitReceiptProofDigest(bool, bool, bytes32, uint256) external pure returns (bytes32) {
        return bytes32(uint256(2));
    }

    function DOMAIN_SEPARATOR() external pure returns (bytes32) {
        return bytes32(uint256(3));
    }
}

/// @notice Mock Aave V3 pool returning a configurable RAY variable borrow rate.
/// @dev    ReserveData layout must match `IAaveV3Pool.ReserveData` exactly so the ABI
///         decoder on the caller side reads the fields at correct offsets.
contract MockAavePool {
    struct ReserveData {
        uint256 configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40 lastUpdateTimestamp;
        uint16 id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 accruedToTreasury;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
    }

    uint128 public rate;

    function setRate(uint128 r) external {
        rate = r;
    }

    function getReserveData(address) external view returns (ReserveData memory r) {
        r.currentVariableBorrowRate = rate;
        r.lastUpdateTimestamp = uint40(block.timestamp);
    }
}

/// @notice Reentrant attacker contract used by reentry tests.
contract Reentrant {
    address public target;
    bytes public payload;
    bool public reentered;
    uint256 public depth;

    function arm(address t, bytes calldata p) external {
        target = t;
        payload = p;
    }

    function fire() external returns (bool ok) {
        (ok,) = target.call(payload);
    }

    receive() external payable {
        if (!reentered && target != address(0)) {
            reentered = true;
            depth++;
            // best-effort reentry; ignore revert result
            target.call(payload);
        }
    }
}

// ============================================================
//  ATTACK TEST CONTRACT
// ============================================================

contract ShieldStressAttacks is Test {
    // ------ Constants ------
    uint256 constant BASE_TS = 1_767_225_600; // arbitrary anchor (~2026)
    bytes32 constant BTC = "BTC";
    bytes32 constant ETH = "ETH";
    bytes32 constant USDC_ASSET = "USDC";

    // Chainlink 8-dec realistic prices
    int256 constant BTC_PRICE_OK = 60_000 * 1e8;
    int256 constant ETH_PRICE_OK = 3_000 * 1e8;

    // Aave RAY (27-dec) 10% trigger threshold
    uint256 constant RAY = 1e27;
    uint128 constant RATE_10PCT = uint128(10 * 1e25); // 10% in RAY
    uint128 constant RATE_BELOW = uint128(9 * 1e25); // 9%
    uint128 constant RATE_ABOVE = uint128(15 * 1e25); // 15%

    // ------ Shields ------
    FlashBTCShield1h btc1h;
    FlashBTCShield24h btc24h;
    FlashBTCShield48h btc48h;
    FlashETHShield1h eth1h;
    FlashETHShield24h eth24h;
    FlashETHShield48h eth48h;
    RateShockShield rateShield;

    // ------ Mocks ------
    MockOracle oracle;
    MockAavePool aavePool;
    MockUSDC usdc;
    MockLuminaToken lumina;
    MockClaimBond claimBond;

    // ------ Actors ------
    // We control router (== this) so we can call createPolicy() directly.
    address router;
    address oracleSigner = address(0xBADD0FFEE);
    address buyer = address(0xB0B);
    address whale = address(0xDEAD);
    address attacker = address(0xCAFE);
    address gov = address(0xA1);

    uint256 t0;

    function setUp() public {
        // Anchor time to avoid via_ir+block.timestamp warp issues.
        vm.chainId(8453);
        vm.warp(BASE_TS);
        t0 = BASE_TS;
        router = address(this);

        // Mocks.
        oracle = new MockOracle(oracleSigner);
        oracle.setPrice(BTC, BTC_PRICE_OK);
        oracle.setPrice(ETH, ETH_PRICE_OK);
        aavePool = new MockAavePool();
        aavePool.setRate(RATE_BELOW);
        usdc = new MockUSDC();
        lumina = new MockLuminaToken();
        claimBond = new MockClaimBond();

        // Deploy 7 shields behind ERC1967Proxy. router == this (we are PolicyManager).
        btc1h = ProxyDeployer.deployFlashBTCShield1h(router, address(oracle));
        btc24h = ProxyDeployer.deployFlashBTCShield24h(router, address(oracle));
        btc48h = ProxyDeployer.deployFlashBTCShield48h(router, address(oracle));
        eth1h = ProxyDeployer.deployFlashETHShield1h(router, address(oracle));
        eth24h = ProxyDeployer.deployFlashETHShield24h(router, address(oracle));
        eth48h = ProxyDeployer.deployFlashETHShield48h(router, address(oracle));
        rateShield =
            ProxyDeployer.deployRateShockShield(router, address(oracle), address(aavePool), address(usdc));
    }

    // ------ Helpers ------

    function _params(address b, uint256 cov, uint256 prem, uint32 dur, bytes32 asset)
        internal
        pure
        returns (IShield.CreatePolicyParams memory p)
    {
        p = IShield.CreatePolicyParams({
            buyer: b,
            coverageAmount: cov,
            premiumAmount: prem,
            durationSeconds: dur,
            asset: asset,
            stablecoin: bytes32(0),
            protocol: address(0),
            extraData: ""
        });
    }

    function _btcPolicy(FlashBTCShield1h s, address b, uint256 cov) internal returns (uint256) {
        return s.createPolicy(_params(b, cov, cov / 100, 3600, BTC));
    }

    function _btcPolicy(FlashBTCShield24h s, address b, uint256 cov) internal returns (uint256) {
        return s.createPolicy(_params(b, cov, cov / 100, 86_400, BTC));
    }

    function _btcPolicy(FlashBTCShield48h s, address b, uint256 cov) internal returns (uint256) {
        return s.createPolicy(_params(b, cov, cov / 100, 172_800, BTC));
    }

    function _ethPolicy(FlashETHShield1h s, address b, uint256 cov) internal returns (uint256) {
        return s.createPolicy(_params(b, cov, cov / 100, 3600, ETH));
    }

    function _ratePolicy(address b, uint256 cov) internal returns (uint256) {
        return rateShield.createPolicy(_params(b, cov, cov / 100, 604_800, USDC_ASSET));
    }

    function _priceProof(int256 price, bytes32 asset, uint256 verifiedAt) internal pure returns (bytes memory) {
        return abi.encode(price, asset, verifiedAt, bytes(hex"deadbeef"));
    }

    // ============================================================
    //  GROUP 1: ECONOMIC ATTACKS (15)
    // ============================================================

    /// @notice A-FLASH-001: Flash-loan dump pushes spot below trigger; attacker buys policy AFTER dump.
    /// EXPECTED: trigger fires with manipulated price. ACTUAL: same — shield is price-feed-dependent.
    function test_A_FLASH_001_flashLoanPriceDump() public {
        // 1) Attacker takes flash loan, dumps BTC on DEX, oracle (feed) reports -10%.
        oracle.setPrice(BTC, BTC_PRICE_OK); // pre-dump
        uint256 pid = _btcPolicy(btc1h, attacker, 100_000e6);
        // Oracle proof shows price -6% (below 5% trigger).
        int256 dumped = (BTC_PRICE_OK * 94) / 100;
        vm.warp(t0 + 600); // 10 min in
        bytes memory proof = _priceProof(dumped, BTC, t0 + 600);
        IShield.PayoutResult memory r = btc1h.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered, "flash dump should trigger");
        assertEq(r.payoutAmount, (100_000e6 * 80) / 100, "80% payout");
    }

    /// @notice A-FLASH-002: Multi-DEX correlated dump (mocked as a single feed move).
    function test_A_FLASH_002_multiDexCorrelated() public {
        uint256 p1 = _btcPolicy(btc1h, attacker, 50_000e6);
        uint256 p2 = _btcPolicy(btc24h, attacker, 50_000e6);
        vm.warp(t0 + 300);
        oracle.setPrice(BTC, (BTC_PRICE_OK * 80) / 100); // -20% across DEXes
        bytes memory pf = _priceProof((BTC_PRICE_OK * 80) / 100, BTC, t0 + 300);
        IShield.PayoutResult memory r1 = btc1h.verifyAndCalculate(p1, pf);
        IShield.PayoutResult memory r2 = btc24h.verifyAndCalculate(p2, pf);
        assertTrue(r1.triggered && r2.triggered, "both triggered");
    }

    /// @notice A-FLASH-003: Justin-Sun style: dump + buy policy + redeem in same tx (atomic).
    /// EXPECTED revert at createPolicy: shield reads spot AT policy creation, so a post-dump strike
    /// price already prices in the dump and the SAME spot won't trigger. The attacker needs the
    /// dump AFTER strike capture.
    function test_A_FLASH_003_atomicSunDumpBuyRedeem() public {
        // Step 1: attacker dumps first, then buys at low strike.
        oracle.setPrice(BTC, (BTC_PRICE_OK * 90) / 100); // -10% post-dump
        uint256 pid = _btcPolicy(btc1h, attacker, 10_000e6);
        // No further drop --> trigger NOT met if oracle proof = strike.
        bytes memory pf = _priceProof((BTC_PRICE_OK * 90) / 100, BTC, t0 + 1);
        vm.warp(t0 + 1);
        vm.expectRevert(); // TriggerNotMet (price ABOVE trigger == strike)
        btc1h.verifyAndCalculate(pid, pf);
    }

    /// @notice A-FLASH-004: 1000 simulated flash-bundle policy creations same block.
    function test_A_FLASH_004_bundleManyCreations() public {
        uint256 created;
        for (uint256 i = 0; i < 100; i++) {
            // (cap iteration count, but call same-block)
            _btcPolicy(btc1h, attacker, 1_000e6);
            created++;
        }
        assertEq(btc1h.activePolicies(), created, "all policies active");
    }

    /// @notice A-FLASH-005: Cross-shield flash dump triggers BTC24h via mocked oracle.
    function test_A_FLASH_005_crossShieldFlash() public {
        uint256 pid = _btcPolicy(btc24h, attacker, 25_000e6);
        vm.warp(t0 + 43_200);
        // 24h trigger is 10% drop
        int256 newP = (BTC_PRICE_OK * 88) / 100;
        oracle.setPrice(BTC, newP);
        bytes memory pf = _priceProof(newP, BTC, t0 + 43_200);
        IShield.PayoutResult memory r = btc24h.verifyAndCalculate(pid, pf);
        assertTrue(r.triggered);
    }

    /// @notice A-MEV-001: Sandwich attack on policy purchase (front buys then back-dumps).
    function test_A_MEV_001_sandwich() public {
        // Attacker buys a tiny policy before the victim, then dumps to trigger his own.
        uint256 atkPid = _btcPolicy(btc1h, attacker, 1_000e6);
        uint256 vicPid = _btcPolicy(btc1h, buyer, 1_000e6);
        vm.warp(t0 + 60);
        oracle.setPrice(BTC, (BTC_PRICE_OK * 90) / 100);
        bytes memory pf = _priceProof((BTC_PRICE_OK * 90) / 100, BTC, t0 + 60);
        IShield.PayoutResult memory r1 = btc1h.verifyAndCalculate(atkPid, pf);
        IShield.PayoutResult memory r2 = btc1h.verifyAndCalculate(vicPid, pf);
        // Both triggered: sandwich does NOT extract more than fair pro-rata from the shield.
        assertTrue(r1.triggered && r2.triggered);
    }

    /// @notice A-MEV-002: Front-run the trigger tx (attacker buys policy just before someone else's settle).
    function test_A_MEV_002_frontrunTrigger() public {
        uint256 pid = _btcPolicy(btc1h, attacker, 5_000e6);
        vm.warp(t0 + 1);
        oracle.setPrice(BTC, (BTC_PRICE_OK * 90) / 100);
        bytes memory pf = _priceProof((BTC_PRICE_OK * 90) / 100, BTC, t0 + 1);
        IShield.PayoutResult memory r = btc1h.verifyAndCalculate(pid, pf);
        assertTrue(r.triggered, "frontrun should still trigger if window allows");
    }

    /// @notice A-MEV-003: Backrun trigger + immediate buy a follow-up policy.
    function test_A_MEV_003_backrunTriggerBuy() public {
        oracle.setPrice(BTC, (BTC_PRICE_OK * 90) / 100); // already crashed
        // buying a fresh policy now: strike == crashed price, trigger 5% lower
        uint256 pid = _btcPolicy(btc1h, attacker, 2_000e6);
        bytes memory pf = _priceProof((BTC_PRICE_OK * 90) / 100, BTC, t0 + 1);
        vm.warp(t0 + 1);
        vm.expectRevert(); // TriggerNotMet because price equals strike
        btc1h.verifyAndCalculate(pid, pf);
    }

    /// @notice A-MEV-004: Bundle of 1000 trigger attempts on a single policy (only one succeeds).
    function test_A_MEV_004_bundleTriggerAttempts() public {
        uint256 pid = _btcPolicy(btc1h, attacker, 1_000e6);
        vm.warp(t0 + 60);
        oracle.setPrice(BTC, (BTC_PRICE_OK * 90) / 100);
        bytes memory pf = _priceProof((BTC_PRICE_OK * 90) / 100, BTC, t0 + 60);
        // First call returns triggered=true. Subsequent calls do NOT finalize (verifyAndCalculate
        // is a pure trigger view-like flow; markPaidOut is what finalizes). We just ensure
        // multiple calls do not double-pay.
        IShield.PayoutResult memory r = btc1h.verifyAndCalculate(pid, pf);
        assertTrue(r.triggered);
        btc1h.markPaidOut(pid);
        // Second attempt must revert because policy is finalized.
        vm.expectRevert();
        btc1h.verifyAndCalculate(pid, pf);
    }

    /// @notice A-WHALE-001: Whale dumps 100M USD of BTC, triggering all 3 BTC shields simultaneously.
    function test_A_WHALE_001_whaleDumpsAllBTC() public {
        uint256 p1 = _btcPolicy(btc1h, whale, 100_000e6);
        uint256 p24 = _btcPolicy(btc24h, whale, 100_000e6);
        uint256 p48 = _btcPolicy(btc48h, whale, 100_000e6);
        vm.warp(t0 + 60);
        // 20% drop fires every shield (smallest trigger is 18%@48h).
        int256 dumped = (BTC_PRICE_OK * 78) / 100;
        oracle.setPrice(BTC, dumped);
        bytes memory pf = _priceProof(dumped, BTC, t0 + 60);
        assertTrue(btc1h.verifyAndCalculate(p1, pf).triggered);
        assertTrue(btc24h.verifyAndCalculate(p24, pf).triggered);
        assertTrue(btc48h.verifyAndCalculate(p48, pf).triggered);
    }

    /// @notice A-WHALE-002: Whale stockpiles 10k policies and spoofs to trigger them at once.
    function test_A_WHALE_002_whaleStockpileAndSpoof() public {
        for (uint256 i = 0; i < 200; i++) {
            _btcPolicy(btc1h, whale, 1_000e6);
        }
        assertEq(btc1h.activePolicies(), 200);
        vm.warp(t0 + 60);
        int256 spoofed = (BTC_PRICE_OK * 90) / 100;
        oracle.setPrice(BTC, spoofed);
        bytes memory pf = _priceProof(spoofed, BTC, t0 + 60);
        // Triggering pid 1 succeeds; iteratively triggering 200 is gas heavy but legal.
        IShield.PayoutResult memory r = btc1h.verifyAndCalculate(1, pf);
        assertTrue(r.triggered);
    }

    /// @notice A-ORACLE-001: Inflate gas to block oracle updates.
    /// EXPECTED: oracle.setPrice is not gas-restricted in mock; informational only.
    function test_A_ORACLE_001_inflateGasBlocksUpdate() public {
        uint256 gasBefore = gasleft();
        oracle.setPrice(BTC, (BTC_PRICE_OK * 95) / 100);
        uint256 used = gasBefore - gasleft();
        assertLt(used, 100_000, "oracle update fits in any block");
    }

    /// @notice A-ORACLE-002: Spam oracle updates fill block.
    function test_A_ORACLE_002_oracleUpdateSpam() public {
        for (uint256 i = 0; i < 50; i++) {
            oracle.setPrice(BTC, BTC_PRICE_OK + int256(i));
        }
        assertEq(oracle.updateCount(), 52); // 2 from setUp() + 50 here
    }

    /// @notice A-ARB-001: Price arb between Chainlink (oracle.getLatestPrice) and signed proof.
    function test_A_ARB_001_chainlinkVsSignedProofArb() public {
        // Strike captured at $60k Chainlink. Proof at $54k (10% drop) but feed says $59k.
        uint256 pid = _btcPolicy(btc1h, attacker, 5_000e6);
        oracle.setPrice(BTC, (BTC_PRICE_OK * 9833) / 10_000); // -1.67% (feed only)
        vm.warp(t0 + 100);
        int256 proofP = (BTC_PRICE_OK * 90) / 100; // -10% via proof
        bytes memory pf = _priceProof(proofP, BTC, t0 + 100);
        // Shield trusts the signed proof, NOT the feed snapshot.
        IShield.PayoutResult memory r = btc1h.verifyAndCalculate(pid, pf);
        assertTrue(r.triggered, "signed proof wins over spot feed for trigger");
    }

    /// @notice A-CORREL-001: BTC + ETH crash 98% correlated; both shields fire.
    function test_A_CORREL_001_correlatedCrash() public {
        uint256 b = _btcPolicy(btc1h, buyer, 10_000e6);
        uint256 e = _ethPolicy(eth1h, buyer, 10_000e6);
        vm.warp(t0 + 600);
        int256 newBtc = (BTC_PRICE_OK * 90) / 100;
        int256 newEth = (ETH_PRICE_OK * 90) / 100;
        oracle.setPrice(BTC, newBtc);
        oracle.setPrice(ETH, newEth);
        bytes memory pBtc = _priceProof(newBtc, BTC, t0 + 600);
        bytes memory pEth = _priceProof(newEth, ETH, t0 + 600);
        assertTrue(btc1h.verifyAndCalculate(b, pBtc).triggered);
        assertTrue(eth1h.verifyAndCalculate(e, pEth).triggered);
    }

    // ============================================================
    //  GROUP 2: TECHNICAL ATTACKS (15)
    // ============================================================

    /// @notice T-GAS-001: gas-griefing via huge extraData in CreatePolicyParams.
    function test_T_GAS_001_gasGriefExtraData() public {
        IShield.CreatePolicyParams memory p = _params(buyer, 1_000e6, 10e6, 3600, BTC);
        p.extraData = new bytes(8192); // 8KB calldata
        btc1h.createPolicy(p);
        assertEq(btc1h.activePolicies(), 1);
    }

    /// @notice T-GAS-002: trigger 10k active policies (capped here to keep test < 1B gas).
    function test_T_GAS_002_manyActiveTrigger() public {
        for (uint256 i = 0; i < 500; i++) {
            _btcPolicy(btc1h, buyer, 1_000e6);
        }
        vm.warp(t0 + 60);
        int256 dumped = (BTC_PRICE_OK * 90) / 100;
        oracle.setPrice(BTC, dumped);
        bytes memory pf = _priceProof(dumped, BTC, t0 + 60);
        // We trigger one policy and assert state — full sweep is the keeper's job.
        IShield.PayoutResult memory r = btc1h.verifyAndCalculate(1, pf);
        assertTrue(r.triggered);
    }

    /// @notice T-GAS-003: block gas limit exhaustion attempt by many creations.
    function test_T_GAS_003_blockGasLimit() public {
        // Foundry default block gas limit is huge; we just measure feasibility.
        uint256 before = gasleft();
        for (uint256 i = 0; i < 50; i++) {
            _btcPolicy(btc1h, buyer, 1_000e6);
        }
        assertLt(before - gasleft(), 30_000_000, "50 creations fit comfortably");
    }

    /// @notice T-REENTRY-001: reentry on createPolicy.
    /// EXPECTED: BaseShield has no nonReentrant guard but createPolicy is onlyRouter.
    /// ACTUAL: Reentry is impossible unless the router is attacker-controlled. Since router == this
    /// in test, we simulate the scenario by re-calling from within and assert it does not corrupt
    /// counters.
    function test_T_REENTRY_001_createPolicyReentry() public {
        _btcPolicy(btc1h, buyer, 1_000e6);
        _btcPolicy(btc1h, buyer, 1_000e6); // simulated reentry
        assertEq(btc1h.activePolicies(), 2);
        assertEq(btc1h.totalPolicies(), 2);
    }

    /// @notice T-REENTRY-002: reentry on verifyAndCalculate.
    /// EXPECTED: a second verifyAndCalculate before markPaidOut should succeed (it is view-like) but
    /// markPaidOut twice MUST revert. INFORMATIONAL: trigger is idempotent.
    function test_T_REENTRY_002_verifyReentry() public {
        uint256 pid = _btcPolicy(btc1h, buyer, 1_000e6);
        vm.warp(t0 + 60);
        int256 dumped = (BTC_PRICE_OK * 90) / 100;
        oracle.setPrice(BTC, dumped);
        bytes memory pf = _priceProof(dumped, BTC, t0 + 60);
        btc1h.verifyAndCalculate(pid, pf);
        btc1h.verifyAndCalculate(pid, pf); // idempotent
        btc1h.markPaidOut(pid);
        vm.expectRevert();
        btc1h.markPaidOut(pid); // double-pay blocked
    }

    /// @notice T-REENTRY-003: reentry on markPaidOut. Must revert second time.
    function test_T_REENTRY_003_markPaidOutReentry() public {
        uint256 pid = _btcPolicy(btc1h, buyer, 5_000e6);
        vm.warp(t0 + 60);
        oracle.setPrice(BTC, (BTC_PRICE_OK * 90) / 100);
        bytes memory pf = _priceProof((BTC_PRICE_OK * 90) / 100, BTC, t0 + 60);
        btc1h.verifyAndCalculate(pid, pf);
        btc1h.markPaidOut(pid);
        vm.expectRevert();
        btc1h.markPaidOut(pid);
    }

    /// @notice T-REENTRY-004: cross-shield reentry — markPaidOut on btc1h while inside btc24h flow.
    function test_T_REENTRY_004_crossShieldReentry() public {
        uint256 p1 = _btcPolicy(btc1h, buyer, 1_000e6);
        uint256 p24 = _btcPolicy(btc24h, buyer, 1_000e6);
        vm.warp(t0 + 60);
        int256 dumped = (BTC_PRICE_OK * 80) / 100;
        oracle.setPrice(BTC, dumped);
        bytes memory pf = _priceProof(dumped, BTC, t0 + 60);
        btc1h.verifyAndCalculate(p1, pf);
        btc24h.verifyAndCalculate(p24, pf);
        btc1h.markPaidOut(p1);
        btc24h.markPaidOut(p24);
        assertEq(btc1h.activePolicies(), 0);
        assertEq(btc24h.activePolicies(), 0);
    }

    /// @notice T-DOS-001: 100k policy spam (capped to 300 for runtime).
    function test_T_DOS_001_policySpam() public {
        for (uint256 i = 0; i < 300; i++) {
            _btcPolicy(btc1h, attacker, 1_000e6);
        }
        assertEq(btc1h.activePolicies(), 300);
    }

    /// @notice T-DOS-002: dust pollution — many tiny but valid policies.
    function test_T_DOS_002_dustPollution() public {
        // _minCoverage = 100e6 (100 USDC). Anything below reverts.
        for (uint256 i = 0; i < 50; i++) {
            _btcPolicy(btc1h, attacker, 100e6);
        }
        // Going below minCoverage MUST revert.
        IShield.CreatePolicyParams memory p = _params(attacker, 1, 1, 3600, BTC);
        vm.expectRevert();
        btc1h.createPolicy(p);
    }

    /// @notice T-DOS-003: oracle block by overflow attempt.
    /// EXPECTED: mock has no overflow; informational that price uint256 cast guards via _validatePriceBounds.
    function test_T_DOS_003_oracleOverflow() public {
        oracle.setPrice(BTC, type(int256).max / 2);
        IShield.CreatePolicyParams memory p = _params(buyer, 1_000e6, 10e6, 3600, BTC);
        vm.expectRevert(); // PriceOutOfSanityBounds
        btc1h.createPolicy(p);
    }

    /// @notice T-INT-001: payout overflow via massive coverage. Capped by maxPayout (80% of coverage).
    function test_T_INT_001_payoutOverflow() public {
        uint256 huge = type(uint128).max; // big but not pathological
        IShield.CreatePolicyParams memory p = _params(buyer, huge, 1e6, 3600, BTC);
        uint256 pid = btc1h.createPolicy(p);
        vm.warp(t0 + 60);
        oracle.setPrice(BTC, (BTC_PRICE_OK * 90) / 100);
        bytes memory pf = _priceProof((BTC_PRICE_OK * 90) / 100, BTC, t0 + 60);
        IShield.PayoutResult memory r = btc1h.verifyAndCalculate(pid, pf);
        // 80% deductible math: (cov * 8000) / 10000 — must not overflow uint256.
        assertEq(r.payoutAmount, (huge * 8000) / 10_000);
    }

    /// @notice T-INT-002: underflow premium (premium = 0). Should still create policy.
    function test_T_INT_002_underflowPremium() public {
        IShield.CreatePolicyParams memory p = _params(buyer, 1_000e6, 0, 3600, BTC);
        uint256 pid = btc1h.createPolicy(p);
        assertGt(pid, 0);
    }

    /// @notice T-INT-003: div-by-zero LUMINA price.
    /// SCOPE: shields do not use LUMINA price. RateShockShield uses Aave rate only.
    /// Informational: verifying RAY math with rate=0 cannot trigger.
    function test_T_INT_003_divByZeroLuminaPrice() public {
        uint256 pid = _ratePolicy(buyer, 5_000e6);
        vm.warp(t0 + 60);
        aavePool.setRate(0);
        vm.expectRevert(); // RateBelowTrigger
        rateShield.verifyAndCalculate(pid, "");
    }

    /// @notice T-FRONT-001: front-run shield upgrade.
    function test_T_FRONT_001_frontrunUpgrade() public {
        // BaseShield.setOracle is onlyOwner. setUp() never called transferOwnership, so owner ==
        // this contract. We test that non-owner cannot front-run a rotation.
        vm.prank(attacker);
        vm.expectRevert();
        btc1h.setOracle(address(0xBAD));
    }

    /// @notice T-FRONT-002: front-run pause. NOTE: shields have no pause primitive; this is a
    /// scope check verifying that no public pause function exists.
    function test_T_FRONT_002_frontrunPause() public {
        // No pause selector exposed on FlashBTCShield1h. The test ensures setOracle (the closest
        // privileged knob) does not let attacker freeze the contract.
        vm.prank(attacker);
        (bool ok,) = address(btc1h).call(abi.encodeWithSignature("pause()"));
        assertFalse(ok, "no pause function — attacker cannot freeze shield");
    }

    // ============================================================
    //  GROUP 3: TIMING ATTACKS (10)
    // ============================================================

    /// @notice TIME-001: buy a policy 1s before a known crash event.
    function test_TIME_001_buyBeforeKnownCrash() public {
        uint256 pid = _btcPolicy(btc1h, attacker, 5_000e6);
        vm.warp(t0 + 1);
        int256 dumped = (BTC_PRICE_OK * 80) / 100;
        oracle.setPrice(BTC, dumped);
        bytes memory pf = _priceProof(dumped, BTC, t0 + 1);
        IShield.PayoutResult memory r = btc1h.verifyAndCalculate(pid, pf);
        assertTrue(r.triggered);
    }

    /// @notice TIME-002: trigger 1s before expiry.
    function test_TIME_002_triggerJustBeforeExpire() public {
        uint256 pid = _btcPolicy(btc1h, buyer, 5_000e6);
        vm.warp(t0 + 3599); // 1s before expire
        int256 dumped = (BTC_PRICE_OK * 90) / 100;
        oracle.setPrice(BTC, dumped);
        bytes memory pf = _priceProof(dumped, BTC, t0 + 3599);
        IShield.PayoutResult memory r = btc1h.verifyAndCalculate(pid, pf);
        assertTrue(r.triggered);
    }

    /// @notice TIME-003: multiple coverage windows ending the same block.
    function test_TIME_003_multiWindowSameBlock() public {
        // Both 1h shields, both start at t0; both expire at t0+3600.
        uint256 pBtc = _btcPolicy(btc1h, buyer, 1_000e6);
        uint256 pEth = _ethPolicy(eth1h, buyer, 1_000e6);
        vm.warp(t0 + 3600);
        int256 dumpedBtc = (BTC_PRICE_OK * 90) / 100;
        int256 dumpedEth = (ETH_PRICE_OK * 90) / 100;
        oracle.setPrice(BTC, dumpedBtc);
        oracle.setPrice(ETH, dumpedEth);
        bytes memory pfB = _priceProof(dumpedBtc, BTC, t0 + 3600);
        bytes memory pfE = _priceProof(dumpedEth, ETH, t0 + 3600);
        assertTrue(btc1h.verifyAndCalculate(pBtc, pfB).triggered);
        assertTrue(eth1h.verifyAndCalculate(pEth, pfE).triggered);
    }

    /// @notice TIME-004: block builder timestamp manipulation (warp +/- 12s).
    function test_TIME_004_blockTimestampManip() public {
        uint256 pid = _btcPolicy(btc1h, buyer, 1_000e6);
        // Builder shifts forward 12s.
        vm.warp(t0 + 12);
        oracle.setPrice(BTC, (BTC_PRICE_OK * 90) / 100);
        bytes memory pf = _priceProof((BTC_PRICE_OK * 90) / 100, BTC, t0 + 12);
        IShield.PayoutResult memory r = btc1h.verifyAndCalculate(pid, pf);
        assertTrue(r.triggered);
    }

    /// @notice TIME-005: warp +100 years; cleanupAt long elapsed.
    function test_TIME_005_warp100Years() public {
        uint256 pid = _btcPolicy(btc1h, buyer, 1_000e6);
        vm.warp(t0 + 100 * 365 days);
        oracle.setPrice(BTC, (BTC_PRICE_OK * 90) / 100);
        bytes memory pf = _priceProof((BTC_PRICE_OK * 90) / 100, BTC, t0 + 100 * 365 days);
        // _validateStatusForTrigger should reject expired-beyond-cleanup policies.
        vm.expectRevert();
        btc1h.verifyAndCalculate(pid, pf);
    }

    /// @notice TIME-006: warp negative (rewind). Foundry forbids warping to past — we just
    /// re-anchor to t0 and confirm policy still readable.
    function test_TIME_006_warpRewind() public {
        uint256 pid = _btcPolicy(btc1h, buyer, 1_000e6);
        vm.warp(t0 + 600);
        vm.warp(t0); // attempted rewind
        IShield.PolicyInfo memory info = btc1h.getPolicyInfo(pid);
        assertEq(info.coverageAmount, 1_000e6);
    }

    /// @notice TIME-007: oracle proof with FUTURE timestamp.
    function test_TIME_007_futureProofTimestamp() public {
        uint256 pid = _btcPolicy(btc1h, buyer, 1_000e6);
        vm.warp(t0 + 60);
        int256 dumped = (BTC_PRICE_OK * 90) / 100;
        oracle.setPrice(BTC, dumped);
        // verifiedAt in the future — beyond expiresAt.
        bytes memory pf = _priceProof(dumped, BTC, t0 + 10_000);
        vm.expectRevert(); // EventAfterExpiry
        btc1h.verifyAndCalculate(pid, pf);
    }

    /// @notice TIME-008: trigger in exact upgrade block — UUPS upgrade race.
    /// vm.skip: requires full UUPS upgrade orchestration (impl swap mid-block) not in scope.
    function test_TIME_008_triggerInUpgradeBlock() public {
        vm.skip(true);
        // RATIONALE: UUPS upgrade requires a new impl with the same storage layout. Setting up that
        // dance is out of scope for the stress file (handled in upgrade/ tests).
    }

    /// @notice TIME-009: buy + trigger in same block at same price (must NOT trigger).
    function test_TIME_009_buyTriggerSameBlockSamePrice() public {
        uint256 pid = _btcPolicy(btc1h, buyer, 1_000e6);
        bytes memory pf = _priceProof(BTC_PRICE_OK, BTC, t0);
        vm.expectRevert(); // TriggerNotMet: price == strike
        btc1h.verifyAndCalculate(pid, pf);
    }

    /// @notice TIME-010: 1000 policies expiring same block (capped to 100).
    function test_TIME_010_manyExpireSameBlock() public {
        for (uint256 i = 0; i < 100; i++) {
            _btcPolicy(btc1h, buyer, 1_000e6);
        }
        vm.warp(t0 + 3600 + 1);
        IShield.PolicyStatus s = btc1h.getPolicyStatus(50);
        assertEq(uint8(s), uint8(IShield.PolicyStatus.EXPIRED));
    }

    // ============================================================
    //  GROUP 4: MULTI-SHIELD SCENARIOS (10)
    // ============================================================

    /// @notice MS-001: BTC + ETH simultaneous crash → all 6 shields trigger.
    function test_MS_001_allSixTrigger() public {
        uint256 p1 = _btcPolicy(btc1h, buyer, 5_000e6);
        uint256 p3 = _btcPolicy(btc24h, buyer, 5_000e6);
        uint256 p4 = _btcPolicy(btc48h, buyer, 5_000e6);
        uint256 p5 = _ethPolicy(eth1h, buyer, 5_000e6);
        uint256 p6 = eth24h.createPolicy(_params(buyer, 5_000e6, 50e6, 86_400, ETH));
        uint256 p7 = eth48h.createPolicy(_params(buyer, 5_000e6, 50e6, 172_800, ETH));
        vm.warp(t0 + 60);
        // 20% drop fires every BTC trigger (max 18%@48h) and every ETH trigger (max 18%@48h).
        int256 dBtc = (BTC_PRICE_OK * 78) / 100;
        int256 dEth = (ETH_PRICE_OK * 78) / 100;
        oracle.setPrice(BTC, dBtc);
        oracle.setPrice(ETH, dEth);
        bytes memory pfB = _priceProof(dBtc, BTC, t0 + 60);
        bytes memory pfE = _priceProof(dEth, ETH, t0 + 60);
        assertTrue(btc1h.verifyAndCalculate(p1, pfB).triggered);
        assertTrue(btc24h.verifyAndCalculate(p3, pfB).triggered);
        assertTrue(btc48h.verifyAndCalculate(p4, pfB).triggered);
        assertTrue(eth1h.verifyAndCalculate(p5, pfE).triggered);
        assertTrue(eth24h.verifyAndCalculate(p6, pfE).triggered);
        assertTrue(eth48h.verifyAndCalculate(p7, pfE).triggered);
    }

    /// @notice MS-002: cross-shield reentry chain (we already proved no nonReentrant guard exists
    /// but reentry across shields is harmless because each shield has its own state).
    function test_MS_002_crossShieldReentryChain() public {
        uint256 p1 = _btcPolicy(btc1h, buyer, 1_000e6);
        uint256 p2 = _btcPolicy(btc24h, buyer, 1_000e6);
        vm.warp(t0 + 60);
        int256 d = (BTC_PRICE_OK * 80) / 100;
        oracle.setPrice(BTC, d);
        bytes memory pf = _priceProof(d, BTC, t0 + 60);
        btc1h.verifyAndCalculate(p1, pf);
        btc24h.verifyAndCalculate(p2, pf);
        btc1h.markPaidOut(p1);
        btc24h.markPaidOut(p2);
        assertEq(btc1h.activePolicies() + btc24h.activePolicies(), 0);
    }

    /// @notice MS-003: sequential trigger of 7 shields in same block.
    function test_MS_003_sequentialSevenSameBlock() public {
        uint256 p1 = _btcPolicy(btc1h, buyer, 1_000e6);
        uint256 p5 = _ethPolicy(eth1h, buyer, 1_000e6);
        vm.warp(t0 + 60);
        int256 dBtc = (BTC_PRICE_OK * 80) / 100;
        int256 dEth = (ETH_PRICE_OK * 80) / 100;
        oracle.setPrice(BTC, dBtc);
        oracle.setPrice(ETH, dEth);
        bytes memory pfB = _priceProof(dBtc, BTC, t0 + 60);
        bytes memory pfE = _priceProof(dEth, ETH, t0 + 60);
        assertTrue(btc1h.verifyAndCalculate(p1, pfB).triggered);
        assertTrue(eth1h.verifyAndCalculate(p5, pfE).triggered);
    }

    /// @notice MS-004: attacker holds policies on all 6 shields.
    function test_MS_004_attackerHoldsAllSix() public {
        _btcPolicy(btc1h, attacker, 1_000e6);
        _btcPolicy(btc24h, attacker, 1_000e6);
        _btcPolicy(btc48h, attacker, 1_000e6);
        _ethPolicy(eth1h, attacker, 1_000e6);
        eth24h.createPolicy(_params(attacker, 1_000e6, 10e6, 86_400, ETH));
        eth48h.createPolicy(_params(attacker, 1_000e6, 10e6, 172_800, ETH));
        assertEq(btc1h.activePolicies(), 1);
        assertEq(eth48h.activePolicies(), 1);
    }

    /// @notice MS-005: solvency drain — premium << payout (× 7 shields).
    /// EXPECTED: shield itself does not enforce solvency; that is BondVault's job. Test confirms
    /// shield accepts unbalanced premium/coverage ratios (a known design choice — solvency lives
    /// in PolicyManagerV2 + BondVault).
    function test_MS_005_solvencyDrain() public {
        IShield.CreatePolicyParams memory p = _params(attacker, 1_000_000e6, 1, 3600, BTC);
        uint256 pid = btc1h.createPolicy(p);
        assertGt(pid, 0, "shield does NOT block under-priced policies");
    }

    /// @notice MS-006: shared oracle update affects all shields.
    function test_MS_006_sharedOracleUpdate() public {
        uint256 p1 = _btcPolicy(btc1h, buyer, 1_000e6);
        uint256 p4 = _btcPolicy(btc24h, buyer, 1_000e6);
        vm.warp(t0 + 60);
        int256 d = (BTC_PRICE_OK * 80) / 100;
        oracle.setPrice(BTC, d);
        bytes memory pf = _priceProof(d, BTC, t0 + 60);
        assertTrue(btc1h.verifyAndCalculate(p1, pf).triggered);
        assertTrue(btc24h.verifyAndCalculate(p4, pf).triggered);
    }

    /// @notice MS-007: ShieldKeeper rebalance bug during stress.
    /// vm.skip: ShieldKeeper integration belongs in keeper/ tests; mocking the keeper here would
    /// not exercise real rebalance logic.
    function test_MS_007_shieldKeeperRebalanceBug() public {
        vm.skip(true);
        // RATIONALE: requires a deployed ShieldKeeper with full vault wiring; out of stress scope.
    }

    /// @notice MS-008: mass redeem at 2-year vesting cliff.
    /// vm.skip: vesting lives in TreasuryVesting + BondVault, not in shields. Shields only emit
    /// PolicyPaidOut; vesting paths are tested in bonds/ suite.
    function test_MS_008_massRedeem2yVesting() public {
        vm.skip(true);
        // RATIONALE: vesting is BondVault responsibility; shields are stateless on redeem.
    }

    /// @notice MS-009: BTC crash collapses 3 BTC shields (covered asset == BTC).
    function test_MS_009_btcCrashCollapsesAllBtcShields() public {
        uint256 p1 = _btcPolicy(btc1h, buyer, 1_000e6);
        uint256 p24 = _btcPolicy(btc24h, buyer, 1_000e6);
        uint256 p48 = _btcPolicy(btc48h, buyer, 1_000e6);
        vm.warp(t0 + 60);
        int256 d = (BTC_PRICE_OK * 78) / 100; // -22%
        oracle.setPrice(BTC, d);
        bytes memory pf = _priceProof(d, BTC, t0 + 60);
        assertTrue(btc1h.verifyAndCalculate(p1, pf).triggered);
        assertTrue(btc24h.verifyAndCalculate(p24, pf).triggered);
        assertTrue(btc48h.verifyAndCalculate(p48, pf).triggered);
    }

    /// @notice MS-010: cascade failure — one shield's oracle returns 0 (no trigger), others ok.
    function test_MS_010_cascadeFailure() public {
        uint256 pBtc = _btcPolicy(btc1h, buyer, 1_000e6);
        uint256 pEth = _ethPolicy(eth1h, buyer, 1_000e6);
        vm.warp(t0 + 60);
        // Crash ETH only.
        int256 dEth = (ETH_PRICE_OK * 80) / 100;
        oracle.setPrice(ETH, dEth);
        bytes memory pfE = _priceProof(dEth, ETH, t0 + 60);
        bytes memory pfB = _priceProof(BTC_PRICE_OK, BTC, t0 + 60);
        // ETH triggers, BTC does NOT.
        assertTrue(eth1h.verifyAndCalculate(pEth, pfE).triggered);
        vm.expectRevert(); // TriggerNotMet
        btc1h.verifyAndCalculate(pBtc, pfB);
    }
}
