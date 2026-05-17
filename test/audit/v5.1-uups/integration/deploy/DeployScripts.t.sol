// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {LuminaTokenV2} from "../../../../../src/token/LuminaTokenV2.sol";
import {TreasuryVesting} from "../../../../../src/token/TreasuryVesting.sol";
import {FounderVesting} from "../../../../../src/token/FounderVesting.sol";
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
import {FlashBTCShield1h} from "../../../../../src/products/FlashBTCShield1h.sol";
import {FlashBTCShield4h} from "../../../../../src/products/FlashBTCShield4h.sol";
import {FlashBTCShield24h} from "../../../../../src/products/FlashBTCShield24h.sol";
import {FlashBTCShield48h} from "../../../../../src/products/FlashBTCShield48h.sol";
import {FlashETHShield1h} from "../../../../../src/products/FlashETHShield1h.sol";
import {FlashETHShield24h} from "../../../../../src/products/FlashETHShield24h.sol";
import {FlashETHShield48h} from "../../../../../src/products/FlashETHShield48h.sol";
import {RateShockShield} from "../../../../../src/products/RateShockShield.sol";
import {IDexRouter} from "../../../../../src/interfaces/IDexRouter.sol";

// ─────────────────────────────────────────────────────────────────────────
// Mocks (mirror the Sepolia script's inline mocks)
// ─────────────────────────────────────────────────────────────────────────

contract MockUSDC_Deploy {
    string public name = "USDC";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockDex_Deploy is IDexRouter {
    function swap(address, address, uint256, uint256) external pure override returns (uint256) {
        return 1000e18;
    }

    function getQuote(address, address, uint256) external pure override returns (uint256) {
        return 1000e18;
    }
}

contract MockShieldOracle_Deploy {
    function getLatestPrice(bytes32 asset) external pure returns (int256) {
        if (asset == bytes32("BTC") || asset == keccak256(abi.encodePacked("BTC"))) return 65000e8;
        if (asset == bytes32("ETH") || asset == keccak256(abi.encodePacked("ETH"))) return 3200e8;
        if (asset == bytes32("USDT") || asset == bytes32("USDC")) return 1e8;
        return 1e10; // default mid-range
    }

    function verifySignature(bytes32, bytes calldata) external pure returns (bool) {
        return true;
    }

    function oracleKey() external pure returns (address) {
        return address(0xdead);
    }
}

// ─────────────────────────────────────────────────────────────────────────
// MAIN TEST - audit #31 deploy scripts
// ─────────────────────────────────────────────────────────────────────────

contract DeployScriptsTest is Test {
    /// @dev State struct mirroring the Sepolia script's deployed addresses.
    struct Deployment {
        LuminaTokenV2 lumina;
        BondVault vault;
        ClaimBond cb;
        CapacityOracle capOracle;
        SolvencyOracle solOracle;
        AdaptiveFeeDistributor adp;
        TWAPBurner burner;
        PolicyManagerV2 pm;
        CoverRouterV2 router;
        CEXLiquidityReserve cex;
        MaintenanceReserve mr;
        TreasuryVesting tv;
        LuminaBondMarketplace mp;
        BuybackEngine buyback;
        ShieldKeeper keeper;
        MockUSDC_Deploy usdc;
        MockDex_Deploy dex;
        MockShieldOracle_Deploy shieldOracle;
        address founderVesting;
        address lbpDeposit;
        // 8 shields
        FlashBTCShield1h btc1h;
        FlashBTCShield4h btc4h;
        FlashBTCShield24h btc24h;
        FlashBTCShield48h btc48h;
        FlashETHShield1h eth1h;
        FlashETHShield24h eth24h;
        FlashETHShield48h eth48h;
        RateShockShield rateShock;
    }

    address internal deployer = address(this);

    /// @dev Simulates the Sepolia script's deploy flow (`run()`) minus the vm.broadcast.
    /// Kept in lockstep with `script/deploy/DeployLuminaV5Sepolia.s.sol` for faithful testing.
    function _runSepoliaDeploy() internal returns (Deployment memory d) {
        d.usdc = new MockUSDC_Deploy();
        d.dex = new MockDex_Deploy();

        // Phase 2: MaintenanceReserve + ClaimBond (no deps).
        d.mr = _deployMaintenance(address(d.usdc), deployer);
        d.cb = _deployClaimBond();

        // Phase 3: predict LUMINA proxy.
        uint64 n = vm.getNonce(deployer);
        // 8 deployments before LUMINA proxy, LUMINA proxy at n+9:
        //   capOracleImpl, capOracleProxy, vaultImpl, vaultProxy, cexImpl, cexProxy, tvImpl, tvProxy, luminaImpl => 9 → luminaProxy at n+9
        address predicted = vm.computeCreateAddress(deployer, n + 9);

        d.capOracle = _deployCapOracle(address(0), predicted, address(d.usdc), 0.036e18);
        d.vault = _deployBondVault(predicted, address(d.cb), address(d.capOracle), address(0));
        d.cex = _deployCEX(predicted, deployer);
        d.tv = _deployTreasuryVesting(predicted);
        d.founderVesting = _labelToAddress("founderVesting");
        d.lbpDeposit = _labelToAddress("lbpDeposit");

        d.lumina = _deployLumina(address(d.vault), address(d.cex), d.founderVesting, d.lbpDeposit, address(d.tv));
        require(address(d.lumina) == predicted, "prediction mismatch");

        // Phase 5: wire claimBond → vault.
        d.cb.setBondVault(address(d.vault));

        // Phase 6: SolvencyOracle + AdaptiveFeeDistributor.
        d.solOracle = _deploySolOracle(address(d.vault), address(d.capOracle), deployer);
        d.adp = _deployAdaptive(address(d.solOracle));

        // Phase 7: TWAPBurner.
        d.burner = _deployTWAPBurner(address(d.usdc), address(d.lumina), address(d.dex));

        // Phase 8: PolicyManagerV2 + CoverRouterV2 + wiring.
        d.pm = _deployPM(address(d.vault));
        d.router = _deployCoverRouter(address(d.usdc), address(d.pm), address(d.burner));
        d.pm.setRouter(address(d.router));
        d.router.setCapacityOracle(address(d.capOracle));
        d.vault.setPolicyManager(address(d.pm));

        // Phase 9: Marketplace + BuybackEngine.
        d.mp = _deployMarketplace(address(d.cb), address(d.usdc), address(d.burner), deployer);
        d.buyback = _deployBuyback(
            address(d.cb),
            address(d.vault),
            address(d.solOracle),
            address(d.capOracle),
            address(d.mp),
            address(d.usdc),
            deployer
        );
        d.keeper = _deployKeeper(address(d.pm));

        // Phase 9c: 8 shields.
        d.shieldOracle = new MockShieldOracle_Deploy();
        d.btc1h = FlashBTCShield1h(
            address(
                new ERC1967Proxy(
                    address(new FlashBTCShield1h()),
                    abi.encodeWithSelector(FlashBTCShield1h.initialize.selector, address(d.pm), address(d.shieldOracle))
                )
            )
        );
        d.btc4h = FlashBTCShield4h(
            address(
                new ERC1967Proxy(
                    address(new FlashBTCShield4h()),
                    abi.encodeWithSelector(FlashBTCShield4h.initialize.selector, address(d.pm), address(d.shieldOracle))
                )
            )
        );
        d.btc24h = FlashBTCShield24h(
            address(
                new ERC1967Proxy(
                    address(new FlashBTCShield24h()),
                    abi.encodeWithSelector(
                        FlashBTCShield24h.initialize.selector, address(d.pm), address(d.shieldOracle)
                    )
                )
            )
        );
        d.btc48h = FlashBTCShield48h(
            address(
                new ERC1967Proxy(
                    address(new FlashBTCShield48h()),
                    abi.encodeWithSelector(
                        FlashBTCShield48h.initialize.selector, address(d.pm), address(d.shieldOracle)
                    )
                )
            )
        );
        d.eth1h = FlashETHShield1h(
            address(
                new ERC1967Proxy(
                    address(new FlashETHShield1h()),
                    abi.encodeWithSelector(FlashETHShield1h.initialize.selector, address(d.pm), address(d.shieldOracle))
                )
            )
        );
        d.eth24h = FlashETHShield24h(
            address(
                new ERC1967Proxy(
                    address(new FlashETHShield24h()),
                    abi.encodeWithSelector(
                        FlashETHShield24h.initialize.selector, address(d.pm), address(d.shieldOracle)
                    )
                )
            )
        );
        d.eth48h = FlashETHShield48h(
            address(
                new ERC1967Proxy(
                    address(new FlashETHShield48h()),
                    abi.encodeWithSelector(
                        FlashETHShield48h.initialize.selector, address(d.pm), address(d.shieldOracle)
                    )
                )
            )
        );
        // RateShock needs pool + usdc; use usdc as pool placeholder here (its interface doesn't matter for registration).
        d.rateShock = RateShockShield(
            address(
                new ERC1967Proxy(
                    address(new RateShockShield()),
                    abi.encodeWithSelector(
                        RateShockShield.initialize.selector,
                        address(d.pm),
                        address(d.shieldOracle),
                        address(d.usdc),
                        address(d.usdc)
                    )
                )
            )
        );

        // Register 8 shields in PolicyManager.
        d.pm.registerProduct(keccak256("FLASHBTC1H-001"), address(d.btc1h));
        d.pm.registerProduct(keccak256("FLASHBTC4H-001"), address(d.btc4h));
        d.pm.registerProduct(keccak256("FLASHBTC24-001"), address(d.btc24h));
        d.pm.registerProduct(keccak256("FLASHBTC48-001"), address(d.btc48h));
        d.pm.registerProduct(keccak256("FLASHETH1H-001"), address(d.eth1h));
        d.pm.registerProduct(keccak256("FLASHETH24-001"), address(d.eth24h));
        d.pm.registerProduct(keccak256("FLASHETH48-001"), address(d.eth48h));
        d.pm.registerProduct(keccak256("RATESHOCK-001"), address(d.rateShock));

        // Configure 8 products in CoverRouter (matching Sepolia script parameters).
        d.router.configureProduct(keccak256("FLASHBTC1H-001"), 8000, 200, 2000, 3600, true);
        d.router.configureProduct(keccak256("FLASHBTC4H-001"), 8000, 150, 2000, 14400, true);
        d.router.configureProduct(keccak256("FLASHBTC24-001"), 8000, 100, 2000, 86400, true);
        d.router.configureProduct(keccak256("FLASHBTC48-001"), 8000, 80, 2000, 172800, true);
        d.router.configureProduct(keccak256("FLASHETH1H-001"), 8000, 200, 2000, 3600, true);
        d.router.configureProduct(keccak256("FLASHETH24-001"), 8000, 100, 2000, 86400, true);
        d.router.configureProduct(keccak256("FLASHETH48-001"), 8000, 80, 2000, 172800, true);
        d.router.configureProduct(keccak256("RATESHOCK-001"), 8000, 30, 3000, 604800, true);

        // Authorize BuybackEngine.
        d.vault.setAuthorizedCaller(address(d.buyback), true);

        // Phase 10: wire TWAPBurner.
        d.burner.setFeeDistributor(address(d.adp));
        d.burner.setReserves(address(d.buyback), deployer, address(d.mr));
        d.burner.setCapacityOracle(address(d.capOracle));
        d.burner.setAuthorizedSender(address(d.router), true);
        d.burner.setAdaptiveMode(true);
        d.lumina.grantRole(d.lumina.BURNER_ROLE(), address(d.burner));
    }

    // Helpers to reduce boilerplate (each mirrors one proxy deploy).
    function _deployMaintenance(address usdc, address admin) internal returns (MaintenanceReserve) {
        MaintenanceReserve impl = new MaintenanceReserve();
        ERC1967Proxy p = new ERC1967Proxy(
            address(impl), abi.encodeWithSelector(MaintenanceReserve.initialize.selector, usdc, admin)
        );
        return MaintenanceReserve(address(p));
    }

    function _deployClaimBond() internal returns (ClaimBond) {
        ClaimBond impl = new ClaimBond();
        ERC1967Proxy p = new ERC1967Proxy(address(impl), abi.encodeWithSelector(ClaimBond.initialize.selector));
        return ClaimBond(address(p));
    }

    function _deployCapOracle(address pool, address lumina, address usdc, uint256 price)
        internal
        returns (CapacityOracle)
    {
        CapacityOracle impl = new CapacityOracle();
        ERC1967Proxy p = new ERC1967Proxy(
            address(impl), abi.encodeWithSelector(CapacityOracle.initialize.selector, pool, lumina, usdc, price)
        );
        return CapacityOracle(address(p));
    }

    function _deployBondVault(address lumina, address cb, address oracle, address pm) internal returns (BondVault) {
        BondVault impl = new BondVault();
        ERC1967Proxy p = new ERC1967Proxy(
            address(impl), abi.encodeWithSelector(BondVault.initialize.selector, lumina, cb, oracle, pm)
        );
        return BondVault(address(p));
    }

    function _deployCEX(address lumina, address admin) internal returns (CEXLiquidityReserve) {
        CEXLiquidityReserve impl = new CEXLiquidityReserve();
        ERC1967Proxy p = new ERC1967Proxy(
            address(impl), abi.encodeWithSelector(CEXLiquidityReserve.initialize.selector, lumina, admin)
        );
        return CEXLiquidityReserve(address(p));
    }

    function _deployTreasuryVesting(address lumina) internal returns (TreasuryVesting) {
        TreasuryVesting impl = new TreasuryVesting();
        ERC1967Proxy p =
            new ERC1967Proxy(address(impl), abi.encodeWithSelector(TreasuryVesting.initialize.selector, lumina));
        return TreasuryVesting(address(p));
    }

    function _deployLumina(address bv, address cex, address fv, address lbp, address tv)
        internal
        returns (LuminaTokenV2)
    {
        LuminaTokenV2 impl = new LuminaTokenV2();
        ERC1967Proxy p = new ERC1967Proxy(
            address(impl), abi.encodeWithSelector(LuminaTokenV2.initialize.selector, bv, cex, fv, lbp, tv)
        );
        return LuminaTokenV2(address(p));
    }

    function _deploySolOracle(address bv, address cap, address admin) internal returns (SolvencyOracle) {
        SolvencyOracle impl = new SolvencyOracle();
        ERC1967Proxy p =
            new ERC1967Proxy(address(impl), abi.encodeWithSelector(SolvencyOracle.initialize.selector, bv, cap, admin));
        return SolvencyOracle(address(p));
    }

    function _deployAdaptive(address sol) internal returns (AdaptiveFeeDistributor) {
        AdaptiveFeeDistributor impl = new AdaptiveFeeDistributor();
        ERC1967Proxy p =
            new ERC1967Proxy(address(impl), abi.encodeWithSelector(AdaptiveFeeDistributor.initialize.selector, sol));
        return AdaptiveFeeDistributor(address(p));
    }

    function _deployTWAPBurner(address u, address l, address r) internal returns (TWAPBurner) {
        TWAPBurner impl = new TWAPBurner();
        ERC1967Proxy p =
            new ERC1967Proxy(address(impl), abi.encodeWithSelector(TWAPBurner.initialize.selector, u, l, r));
        return TWAPBurner(payable(address(p)));
    }

    function _deployPM(address bv) internal returns (PolicyManagerV2) {
        PolicyManagerV2 impl = new PolicyManagerV2();
        ERC1967Proxy p =
            new ERC1967Proxy(address(impl), abi.encodeWithSelector(PolicyManagerV2.initialize.selector, bv));
        return PolicyManagerV2(address(p));
    }

    function _deployCoverRouter(address u, address pm, address b) internal returns (CoverRouterV2) {
        CoverRouterV2 impl = new CoverRouterV2();
        ERC1967Proxy p =
            new ERC1967Proxy(address(impl), abi.encodeWithSelector(CoverRouterV2.initialize.selector, u, pm, b));
        return CoverRouterV2(address(p));
    }

    function _deployMarketplace(address cb, address u, address b, address admin)
        internal
        returns (LuminaBondMarketplace)
    {
        LuminaBondMarketplace impl = new LuminaBondMarketplace();
        ERC1967Proxy p = new ERC1967Proxy(
            address(impl), abi.encodeWithSelector(LuminaBondMarketplace.initialize.selector, cb, u, b, admin)
        );
        return LuminaBondMarketplace(address(p));
    }

    function _deployBuyback(address cb, address bv, address sol, address cap, address mp, address usdc, address admin)
        internal
        returns (BuybackEngine)
    {
        BuybackEngine impl = new BuybackEngine();
        ERC1967Proxy p = new ERC1967Proxy(
            address(impl), abi.encodeWithSelector(BuybackEngine.initialize.selector, cb, bv, sol, cap, mp, usdc, admin)
        );
        return BuybackEngine(address(p));
    }

    function _deployKeeper(address pm) internal returns (ShieldKeeper) {
        ShieldKeeper impl = new ShieldKeeper();
        ERC1967Proxy p = new ERC1967Proxy(address(impl), abi.encodeWithSelector(ShieldKeeper.initialize.selector, pm));
        return ShieldKeeper(address(p));
    }

    function _labelToAddress(string memory label) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(label)))));
    }

    // ═════════════════════ A. Full deploy success ═════════════════════

    function test_Deploy_FullSepolia_AllContractsNonZero() public {
        vm.chainId(8453);
        Deployment memory d = _runSepoliaDeploy();
        assertTrue(address(d.lumina) != address(0));
        assertTrue(address(d.vault) != address(0));
        assertTrue(address(d.cb) != address(0));
        assertTrue(address(d.capOracle) != address(0));
        assertTrue(address(d.solOracle) != address(0));
        assertTrue(address(d.adp) != address(0));
        assertTrue(address(d.burner) != address(0));
        assertTrue(address(d.pm) != address(0));
        assertTrue(address(d.router) != address(0));
        assertTrue(address(d.cex) != address(0));
        assertTrue(address(d.mr) != address(0));
        assertTrue(address(d.tv) != address(0));
        assertTrue(address(d.mp) != address(0));
        assertTrue(address(d.buyback) != address(0));
        assertTrue(address(d.keeper) != address(0));
    }

    // ═════════════════════ B. Token distribution ═════════════════════

    function test_Deploy_TokenDistribution_70_14_8_5_3() public {
        vm.chainId(8453);
        Deployment memory d = _runSepoliaDeploy();

        // 70M to BondVault
        assertEq(d.lumina.balanceOf(address(d.vault)), 70_000_000e18);
        // 14M to CEX
        assertEq(d.lumina.balanceOf(address(d.cex)), 14_000_000e18);
        // 8M to FounderVesting placeholder (on Sepolia - labelToAddress)
        assertEq(d.lumina.balanceOf(d.founderVesting), 8_000_000e18);
        // 5M to lbpDeposit placeholder
        assertEq(d.lumina.balanceOf(d.lbpDeposit), 5_000_000e18);
        // 3M to TreasuryVesting
        assertEq(d.lumina.balanceOf(address(d.tv)), 3_000_000e18);
        // Total = 100M
        assertEq(d.lumina.totalSupply(), 100_000_000e18);
    }

    // ═════════════════════ C. Nonce prediction ═════════════════════

    function test_Deploy_LuminaPredictedAddress_Matches() public {
        vm.chainId(8453);
        Deployment memory d = _runSepoliaDeploy();
        // Implicit assertion - _runSepoliaDeploy already requires matching prediction.
        assertTrue(address(d.lumina) != address(0));
    }

    // ═════════════════════ D. Wiring completeness ═════════════════════

    function test_Deploy_BondVault_PolicyManagerWired() public {
        vm.chainId(8453);
        Deployment memory d = _runSepoliaDeploy();
        assertEq(d.vault.policyManager(), address(d.pm));
    }

    function test_Deploy_BondVault_CanOnlyBeSetOnce() public {
        vm.chainId(8453);
        Deployment memory d = _runSepoliaDeploy();
        vm.expectRevert(bytes("PolicyManager already set"));
        d.vault.setPolicyManager(makeAddr("x"));
    }

    function test_Deploy_ClaimBond_BondVaultWired() public {
        vm.chainId(8453);
        Deployment memory d = _runSepoliaDeploy();
        assertEq(d.cb.bondVault(), address(d.vault));
    }

    function test_Deploy_PolicyManager_RouterWired() public {
        vm.chainId(8453);
        Deployment memory d = _runSepoliaDeploy();
        assertEq(d.pm.router(), address(d.router));
    }

    function test_Deploy_CoverRouter_CapacityOracleWired() public {
        vm.chainId(8453);
        Deployment memory d = _runSepoliaDeploy();
        assertEq(address(d.router.capacityOracle()), address(d.capOracle));
    }

    function test_Deploy_BondVault_BuybackAuthorized() public {
        vm.chainId(8453);
        Deployment memory d = _runSepoliaDeploy();
        assertTrue(d.vault.authorizedCallers(address(d.buyback)));
    }

    function test_Deploy_TWAPBurner_AdaptiveModeOn() public {
        vm.chainId(8453);
        Deployment memory d = _runSepoliaDeploy();
        assertTrue(d.burner.adaptiveModeEnabled());
    }

    function test_Deploy_TWAPBurner_HasBurnerRole() public {
        vm.chainId(8453);
        Deployment memory d = _runSepoliaDeploy();
        assertTrue(d.lumina.hasRole(d.lumina.BURNER_ROLE(), address(d.burner)));
    }

    function test_Deploy_TWAPBurner_ReservesWired() public {
        vm.chainId(8453);
        Deployment memory d = _runSepoliaDeploy();
        assertEq(d.burner.buybackReserve(), address(d.buyback));
        assertEq(d.burner.opsReserve(), deployer);
        assertEq(d.burner.maintenanceReserve(), address(d.mr));
    }

    // ═════════════════════ E. Product registration ═════════════════════

    function test_Deploy_AllEightProducts_RegisteredInPM() public {
        vm.chainId(8453);
        Deployment memory d = _runSepoliaDeploy();
        assertTrue(d.pm.productActive(keccak256("FLASHBTC1H-001")));
        assertTrue(d.pm.productActive(keccak256("FLASHBTC4H-001")));
        assertTrue(d.pm.productActive(keccak256("FLASHBTC24-001")));
        assertTrue(d.pm.productActive(keccak256("FLASHBTC48-001")));
        assertTrue(d.pm.productActive(keccak256("FLASHETH1H-001")));
        assertTrue(d.pm.productActive(keccak256("FLASHETH24-001")));
        assertTrue(d.pm.productActive(keccak256("FLASHETH48-001")));
        assertTrue(d.pm.productActive(keccak256("RATESHOCK-001")));
    }

    function test_Deploy_AllEightProducts_ConfiguredInCoverRouter() public {
        vm.chainId(8453);
        Deployment memory d = _runSepoliaDeploy();
        CoverRouterV2.ProductConfig memory c1 = d.router.getProductConfig(keccak256("FLASHBTC1H-001"));
        assertEq(c1.payoutRatioBps, 8000);
        assertTrue(c1.active);
        assertEq(c1.durationSeconds, 3600);

        CoverRouterV2.ProductConfig memory c3 = d.router.getProductConfig(keccak256("RATESHOCK-001"));
        assertEq(c3.durationSeconds, 604800); // 7 days
    }

    function test_Deploy_ProductIDs_MatchShieldConstants() public {
        vm.chainId(8453);
        Deployment memory d = _runSepoliaDeploy();
        // Each shield has a PRODUCT_ID constant - verify the keccak matches.
        assertEq(d.btc1h.PRODUCT_ID(), keccak256("FLASHBTC1H-001"));
        assertEq(d.btc4h.PRODUCT_ID(), keccak256("FLASHBTC4H-001"));
        assertEq(d.btc24h.PRODUCT_ID(), keccak256("FLASHBTC24-001"));
        assertEq(d.btc48h.PRODUCT_ID(), keccak256("FLASHBTC48-001"));
        assertEq(d.eth1h.PRODUCT_ID(), keccak256("FLASHETH1H-001"));
        assertEq(d.eth24h.PRODUCT_ID(), keccak256("FLASHETH24-001"));
        assertEq(d.eth48h.PRODUCT_ID(), keccak256("FLASHETH48-001"));
        assertEq(d.rateShock.PRODUCT_ID(), keccak256("RATESHOCK-001"));
    }

    // ═════════════════════ F. Admin roles ═════════════════════

    function test_Deploy_Admin_Roles_OnDeployer() public {
        vm.chainId(8453);
        Deployment memory d = _runSepoliaDeploy();
        assertTrue(d.vault.hasRole(d.vault.DEFAULT_ADMIN_ROLE(), deployer));
        assertTrue(d.lumina.hasRole(d.lumina.DEFAULT_ADMIN_ROLE(), deployer));
        assertTrue(d.buyback.hasRole(d.buyback.DEFAULT_ADMIN_ROLE(), deployer));
        assertTrue(d.mp.hasRole(d.mp.DEFAULT_ADMIN_ROLE(), deployer));
        assertTrue(d.cex.hasRole(d.cex.DEFAULT_ADMIN_ROLE(), deployer));
        assertTrue(d.mr.hasRole(d.mr.DEFAULT_ADMIN_ROLE(), deployer));
        assertTrue(d.solOracle.hasRole(d.solOracle.DEFAULT_ADMIN_ROLE(), deployer));
    }

    // ═════════════════════ G. CRITICAL - Marketplace missing authorizedOperator ═════════════════════

    /// @notice CRITICAL FINDING: Neither deploy script calls
    /// `claimBond.setAuthorizedOperator(marketplace, true)`. The Fix #18
    /// whitelist gate means the marketplace cannot move bonds. Post-deploy
    /// the marketplace is NON-FUNCTIONAL unless this post-deploy step is run.
    function test_Deploy_CRITICAL_Marketplace_MissingAuthorizedOperator() public {
        vm.chainId(8453);
        Deployment memory d = _runSepoliaDeploy();
        // After the Sepolia script finishes, marketplace is NOT a ClaimBond authorized operator.
        assertFalse(
            d.cb.authorizedOperators(address(d.mp)),
            "DEPLOY BUG: Sepolia script omits claimBond.setAuthorizedOperator(marketplace,true)"
        );
    }

    function test_Deploy_CRITICAL_MarketplaceList_Fails_WithoutAuthorizedOperator() public {
        vm.chainId(8453);
        Deployment memory d = _runSepoliaDeploy();

        // Manually mint a bond to a seller (simulating a post-trigger state).
        // We'll prank as vault (the authorized bondVault on ClaimBond).
        address seller = makeAddr("seller");
        vm.prank(address(d.vault));
        d.cb.mint(seller, 202904, 500);

        // Seller approves marketplace, tries to list. This must FAIL because
        // marketplace is NOT in authorizedOperators (the deploy bug).
        vm.startPrank(seller);
        d.cb.setApprovalForAll(address(d.mp), true);
        vm.expectRevert(); // ClaimBond rejects non-whitelisted operator
        d.mp.list(202904, 100, 50e6);
        vm.stopPrank();
    }

    function test_Deploy_Workaround_AfterPostDeployCall_MarketplaceWorks() public {
        vm.chainId(8453);
        Deployment memory d = _runSepoliaDeploy();

        // Apply the missing call manually (simulates the fix).
        d.cb.setAuthorizedOperator(address(d.mp), true);
        assertTrue(d.cb.authorizedOperators(address(d.mp)));

        address seller = makeAddr("seller");
        vm.prank(address(d.vault));
        d.cb.mint(seller, 202904, 500);

        vm.startPrank(seller);
        d.cb.setApprovalForAll(address(d.mp), true);
        uint256 listingId = d.mp.list(202904, 100, 50e6);
        vm.stopPrank();

        (,,,, bool active) = d.mp.getListing(listingId);
        assertTrue(active, "after fix, listing succeeds");
    }

    // ═════════════════════ H. First operation post-deploy ═════════════════════

    function test_Deploy_FirstPolicyPurchase_Works() public {
        vm.chainId(8453);
        Deployment memory d = _runSepoliaDeploy();

        address buyer = makeAddr("buyer");
        d.usdc.mint(buyer, 10_000e6);
        vm.prank(buyer);
        d.usdc.approve(address(d.router), type(uint256).max);

        vm.prank(buyer);
        uint256 policyId = d.router.purchasePolicy(keccak256("FLASHBTC1H-001"), 1000e6, "BTC");
        assertGt(policyId, 0);
        assertEq(d.pm.totalPolicies(), 1);
    }

    // ═════════════════════ I. Initial parameters ═════════════════════

    function test_Deploy_InitialParams_TWAPBurner() public {
        vm.chainId(8453);
        Deployment memory d = _runSepoliaDeploy();
        assertEq(d.burner.maxSlippageBps(), 500); // 5%
        assertEq(d.burner.burnCooldown(), 900); // 15 min
        assertEq(d.burner.poolFee(), 10000); // 1%
        assertEq(d.burner.minBurnAmount(), 1e6);
        assertEq(d.burner.maxBurnAmount(), 10_000e6);
    }

    function test_Deploy_InitialParams_CoverRouter_Constants() public {
        vm.chainId(8453);
        Deployment memory d = _runSepoliaDeploy();
        assertEq(d.router.MIN_PRICE_FOR_NEW_POLICIES(), 5e15);
        assertEq(d.router.RESET_PRICE_FOR_NEW_POLICIES(), 8e15);
    }

    function test_Deploy_InitialParams_BondVault_Constants() public {
        vm.chainId(8453);
        Deployment memory d = _runSepoliaDeploy();
        assertEq(d.vault.SAFETY_FACTOR_BPS(), 5000);
        assertEq(d.vault.bondMaturitySeconds(), 730 days);
        assertEq(d.vault.MIN_REDEEM_PRICE(), 0.001e18);
    }

    function test_Deploy_InitialParams_Marketplace_FeeConstants() public {
        vm.chainId(8453);
        Deployment memory d = _runSepoliaDeploy();
        assertEq(d.mp.SELLER_FEE_BPS(), 150);
        assertEq(d.mp.BUYER_FEE_BPS(), 150);
    }

    // ═════════════════════ J. Re-run safety ═════════════════════

    function test_Deploy_RunTwice_SecondRun_ProducesDifferentAddresses() public {
        vm.chainId(8453);
        Deployment memory d1 = _runSepoliaDeploy();
        Deployment memory d2 = _runSepoliaDeploy();
        // Deploy scripts are NOT idempotent - each call deploys a fresh stack.
        assertTrue(address(d1.lumina) != address(d2.lumina));
        assertTrue(address(d1.vault) != address(d2.vault));
    }

    function test_Deploy_BondVault_SetPolicyManager_SecondCallReverts() public {
        vm.chainId(8453);
        Deployment memory d = _runSepoliaDeploy();
        vm.expectRevert(bytes("PolicyManager already set"));
        d.vault.setPolicyManager(makeAddr("x"));
    }

    function test_Deploy_ClaimBond_SetBondVault_SecondCallReverts() public {
        vm.chainId(8453);
        Deployment memory d = _runSepoliaDeploy();
        // Second call should revert (one-shot).
        vm.expectRevert();
        d.cb.setBondVault(makeAddr("x"));
    }

    // ═════════════════════ K. FounderVesting placeholder observation ═════════════════════

    /// @notice OBSERVATION: Sepolia script uses `_labelToAddress` to generate a
    /// deterministic placeholder for FounderVesting instead of deploying the
    /// real contract. This means 8M LUMINA is minted to an address with no
    /// code - unreachable on testnet (tokens are effectively burned).
    ///
    /// The mainnet `DeployLuminaV5Complete.s.sol` DOES deploy FounderVesting
    /// properly. Sepolia behavior is acceptable for testnet but differs from
    /// mainnet - documented here.
    function test_Deploy_Sepolia_FounderVesting_IsPlaceholder_NotDeployed() public {
        vm.chainId(8453);
        Deployment memory d = _runSepoliaDeploy();
        // Code length of the placeholder is 0 (no contract deployed).
        assertEq(d.founderVesting.code.length, 0, "Sepolia uses _labelToAddress - placeholder only");
        assertEq(d.lumina.balanceOf(d.founderVesting), 8_000_000e18, "but still receives 8M LUMINA");
    }
}
