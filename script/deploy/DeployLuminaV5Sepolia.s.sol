// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// ─── Core contracts ───
import {LuminaTokenV2} from "../../src/token/LuminaTokenV2.sol";
import {TreasuryVesting} from "../../src/token/TreasuryVesting.sol";
import {ClaimBond} from "../../src/bonds/ClaimBond.sol";
import {BondVault} from "../../src/bonds/BondVault.sol";
import {CapacityOracle} from "../../src/oracles/CapacityOracle.sol";
import {SolvencyOracle} from "../../src/oracles/SolvencyOracle.sol";
import {AdaptiveFeeDistributor} from "../../src/core/AdaptiveFeeDistributor.sol";
import {TWAPBurner} from "../../src/core/TWAPBurner.sol";
import {PolicyManagerV2} from "../../src/core/PolicyManagerV2.sol";
import {CoverRouterV2} from "../../src/core/CoverRouterV2.sol";
import {CEXLiquidityReserve} from "../../src/treasury/CEXLiquidityReserve.sol";
import {MaintenanceReserve} from "../../src/treasury/MaintenanceReserve.sol";
import {LuminaBondMarketplace} from "../../src/marketplace/LuminaBondMarketplace.sol";
import {BuybackEngine} from "../../src/marketplace/BuybackEngine.sol";
import {ShieldKeeper} from "../../src/automation/ShieldKeeper.sol";
import {IDexRouter} from "../../src/interfaces/IDexRouter.sol";

// ─── Shields ───
// [Sprint T-30a Phase B] V5.2 shield set (FlashBTC/FlashETH 1h/24h/48h + RateShock)
// removed. Phase C re-introduces the new shield set with the drop-from-purchase
// mechanic. RateShock NOT replaced (founder decision: removed permanently).

// ═══════════════════════════════════════════════════════════════
//  INLINE MOCKS FOR SEPOLIA
// ═══════════════════════════════════════════════════════════════

/// @notice Mock ERC-20 with 6 decimals (USDC stand-in for testnet).
contract MockERC20_USDC {
    string public name = "Mock USDC";
    string public symbol = "mUSDC";
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
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Mock Chainlink-like oracle returning a hardcoded price.
contract MockChainlinkOracle {
    int256 public price;
    uint8 public decimals_ = 8;

    constructor(int256 _price) {
        price = _price;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, price, block.timestamp, block.timestamp, 1);
    }

    function setPrice(int256 _price) external {
        price = _price;
    }
}

/// @notice Mock IOracle for shields (returns hardcoded prices by asset).
contract MockShieldOracle {
    mapping(bytes32 => int256) public prices;

    constructor() {
        prices[keccak256(abi.encodePacked("BTC"))] = 65000e8; // $65K BTC
        prices[keccak256(abi.encodePacked("ETH"))] = 3200e8; // $3.2K ETH
        prices["BTC"] = 65000e8;
        prices["ETH"] = 3200e8;
        prices["USDT"] = 1e8; // $1.00 USDT
    }

    function getLatestPrice(bytes32 asset) external view returns (int256) {
        int256 p = prices[asset];
        return p > 0 ? p : int256(1e8); // fallback $1
    }

    function verifySignature(bytes32, bytes calldata) external pure returns (bool) {
        return true; // testnet: always valid
    }

    function oracleKey() external pure returns (address) {
        return address(0xdead);
    }
}

/// @notice Mock Aave V3 Pool (returns a fixed borrow rate). Used by FounderVesting
///         on testnet; RateShockShield consumer removed in Sprint T-30a Phase B.
contract MockAavePool {
    function getReserveData(address)
        external
        pure
        returns (
            uint256,
            uint128,
            uint128,
            uint128,
            uint128,
            uint128,
            uint40,
            uint16,
            address,
            address,
            address,
            address,
            uint128,
            uint128,
            uint128
        )
    {
        // currentVariableBorrowRate = 5% APY in RAY (27 decimals) = 5e25
        return (0, 0, 0, 0, 5e25, 0, 0, 0, address(0), address(0), address(0), address(0), 0, 0, 0);
    }
}

/// @notice Mock DEX router implementing IDexRouter for testnet.
contract MockDexRouterSepolia is IDexRouter {
    /// @dev Simply returns a hardcoded value; no real swap.
    function swap(address, address, uint256, uint256) external pure override returns (uint256) {
        return 1000e18;
    }

    /// @dev Returns a hardcoded quote for getQuote.
    function getQuote(address, address, uint256) external pure override returns (uint256) {
        return 1000e18;
    }
}

// ═══════════════════════════════════════════════════════════════
//  DEPLOY SCRIPT
// ═══════════════════════════════════════════════════════════════

contract DeployLuminaV5Sepolia is Script {
    // ─── Configuration ───
    uint256 constant EMERGENCY_PRICE = 0.036e18; // $0.036
    uint256 constant TEST_USDC_AMOUNT = 1_000_000e6; // 1M USDC for testing

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== LUMINA V5.0 Sepolia Deployment ===");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // ──────────────────────────────────────────────────
        // PHASE 1: Deploy mocks
        // ──────────────────────────────────────────────────
        MockERC20_USDC usdc = new MockERC20_USDC();
        console.log("MockUSDC:", address(usdc));

        MockChainlinkOracle mockBtcOracle = new MockChainlinkOracle(65_000e8);
        console.log("MockBTCOracle:", address(mockBtcOracle));

        MockChainlinkOracle mockEthOracle = new MockChainlinkOracle(3_500e8);
        console.log("MockETHOracle:", address(mockEthOracle));

        MockDexRouterSepolia dexRouter = new MockDexRouterSepolia();
        console.log("MockDexRouter:", address(dexRouter));

        // Mint test USDC to deployer
        usdc.mint(deployer, TEST_USDC_AMOUNT);
        console.log("Minted test USDC to deployer:", TEST_USDC_AMOUNT);

        // ──────────────────────────────────────────────────
        // PHASE 2: Deploy contracts without circular deps
        // ──────────────────────────────────────────────────
        // [V5.1] MaintenanceReserve via UUPS proxy
        MaintenanceReserve maintenanceReserveImpl = new MaintenanceReserve();
        ERC1967Proxy maintenanceProxy = new ERC1967Proxy(
            address(maintenanceReserveImpl),
            abi.encodeWithSelector(MaintenanceReserve.initialize.selector, address(usdc), deployer)
        );
        MaintenanceReserve maintenanceReserve = MaintenanceReserve(address(maintenanceProxy));
        console.log("MaintenanceReserve (proxy):", address(maintenanceReserve));

        // [V5.1] ClaimBond via UUPS proxy
        ClaimBond claimBondImpl = new ClaimBond();
        ERC1967Proxy claimBondProxy =
            new ERC1967Proxy(address(claimBondImpl), abi.encodeWithSelector(ClaimBond.initialize.selector));
        ClaimBond claimBond = ClaimBond(address(claimBondProxy));
        console.log("ClaimBond (proxy):", address(claimBond));

        // ──────────────────────────────────────────────────
        // PHASE 3: Predict LuminaTokenV2 PROXY address to break
        //          the circular dependency
        // ──────────────────────────────────────────────────
        // [V5.1] Nonce count before LuminaTokenV2 proxy:
        //   +2 capacityOracle(proxy), +2 bondVault(proxy),
        //   +2 cexReserve(proxy), +2 treasuryVesting(proxy), +2 lumina(proxy) = proxy at +9
        uint64 currentNonce = vm.getNonce(deployer);
        address predictedLumina = vm.computeCreateAddress(deployer, currentNonce + 9);
        console.log("Predicted LUMINA proxy address:", predictedLumina);

        // [V5.1] CapacityOracle via UUPS proxy
        CapacityOracle capacityOracleImpl = new CapacityOracle();
        ERC1967Proxy capacityOracleProxy = new ERC1967Proxy(
            address(capacityOracleImpl),
            abi.encodeWithSelector(
                CapacityOracle.initialize.selector,
                address(0), // pool (none on Sepolia initially)
                predictedLumina, // luminaToken (proxy address)
                address(usdc), // usdcToken
                EMERGENCY_PRICE
            )
        );
        CapacityOracle capacityOracle = CapacityOracle(address(capacityOracleProxy));
        console.log("CapacityOracle (proxy):", address(capacityOracle));

        // [V5.1] BondVault via UUPS proxy
        BondVault bondVaultImpl = new BondVault();
        ERC1967Proxy bondVaultProxy = new ERC1967Proxy(
            address(bondVaultImpl),
            abi.encodeWithSelector(
                BondVault.initialize.selector,
                predictedLumina,
                address(claimBond),
                address(capacityOracle),
                address(0) // policyManager set later
            )
        );
        BondVault bondVault = BondVault(address(bondVaultProxy));
        console.log("BondVault (proxy):", address(bondVault));

        // [V5.1] CEXLiquidityReserve via UUPS proxy
        CEXLiquidityReserve cexReserveImpl = new CEXLiquidityReserve();
        ERC1967Proxy cexReserveProxy = new ERC1967Proxy(
            address(cexReserveImpl),
            abi.encodeWithSelector(CEXLiquidityReserve.initialize.selector, predictedLumina, deployer)
        );
        CEXLiquidityReserve cexReserve = CEXLiquidityReserve(address(cexReserveProxy));
        console.log("CEXLiquidityReserve (proxy):", address(cexReserve));

        // [V5.1] TreasuryVesting via UUPS proxy
        TreasuryVesting treasuryVestingImpl = new TreasuryVesting();
        ERC1967Proxy treasuryVestingProxy = new ERC1967Proxy(
            address(treasuryVestingImpl), abi.encodeWithSelector(TreasuryVesting.initialize.selector, predictedLumina)
        );
        TreasuryVesting treasuryVesting = TreasuryVesting(address(treasuryVestingProxy));
        console.log("TreasuryVesting (proxy):", address(treasuryVesting));

        // ──────────────────────────────────────────────────
        // PHASE 4: Deploy LuminaTokenV2 via UUPS proxy
        // ──────────────────────────────────────────────────
        address founderVesting = _labelToAddress("founderVesting");
        address lbpDeposit = _labelToAddress("lbpDeposit");

        LuminaTokenV2 luminaImpl = new LuminaTokenV2();
        ERC1967Proxy luminaProxy = new ERC1967Proxy(
            address(luminaImpl),
            abi.encodeWithSelector(
                LuminaTokenV2.initialize.selector,
                address(bondVault),
                address(cexReserve),
                founderVesting,
                lbpDeposit,
                address(treasuryVesting)
            )
        );
        LuminaTokenV2 lumina = LuminaTokenV2(address(luminaProxy));
        require(address(lumina) == predictedLumina, "LUMINA proxy address prediction failed!");
        console.log("LuminaTokenV2 (proxy):", address(lumina));

        // ──────────────────────────────────────────────────
        // PHASE 5: Wire ClaimBond -> BondVault
        // ──────────────────────────────────────────────────
        claimBond.setBondVault(address(bondVault));
        console.log("ClaimBond.setBondVault done");

        // ──────────────────────────────────────────────────
        // PHASE 6: SolvencyOracle + AdaptiveFeeDistributor
        // ──────────────────────────────────────────────────
        // [V5.1] SolvencyOracle via UUPS proxy
        SolvencyOracle solvencyOracleImpl = new SolvencyOracle();
        ERC1967Proxy solvencyOracleProxy = new ERC1967Proxy(
            address(solvencyOracleImpl),
            abi.encodeWithSelector(
                SolvencyOracle.initialize.selector, address(bondVault), address(capacityOracle), deployer
            )
        );
        SolvencyOracle solvencyOracle = SolvencyOracle(address(solvencyOracleProxy));
        console.log("SolvencyOracle (proxy):", address(solvencyOracle));

        // [V5.1] AdaptiveFeeDistributor via UUPS proxy
        AdaptiveFeeDistributor feeDistributorImpl = new AdaptiveFeeDistributor();
        ERC1967Proxy feeDistributorProxy = new ERC1967Proxy(
            address(feeDistributorImpl),
            abi.encodeWithSelector(AdaptiveFeeDistributor.initialize.selector, address(solvencyOracle))
        );
        AdaptiveFeeDistributor feeDistributor = AdaptiveFeeDistributor(address(feeDistributorProxy));
        console.log("AdaptiveFeeDistributor (proxy):", address(feeDistributor));

        // ──────────────────────────────────────────────────
        // PHASE 7: TWAPBurner
        // ──────────────────────────────────────────────────
        // [V5.1] TWAPBurner via UUPS proxy
        TWAPBurner twapBurnerImpl = new TWAPBurner();
        ERC1967Proxy twapBurnerProxy = new ERC1967Proxy(
            address(twapBurnerImpl),
            abi.encodeWithSelector(TWAPBurner.initialize.selector, address(usdc), address(lumina), address(dexRouter))
        );
        TWAPBurner twapBurner = TWAPBurner(payable(address(twapBurnerProxy)));
        console.log("TWAPBurner (proxy):", address(twapBurner));

        // ──────────────────────────────────────────────────
        // PHASE 8: PolicyManagerV2 + CoverRouterV2
        // ──────────────────────────────────────────────────
        // [V5.1] PolicyManagerV2 via UUPS proxy
        PolicyManagerV2 pmImpl = new PolicyManagerV2();
        ERC1967Proxy pmProxy = new ERC1967Proxy(
            address(pmImpl), abi.encodeWithSelector(PolicyManagerV2.initialize.selector, address(bondVault))
        );
        PolicyManagerV2 policyManager = PolicyManagerV2(address(pmProxy));
        console.log("PolicyManagerV2 (proxy):", address(policyManager));

        // [V5.1] CoverRouterV2 via UUPS proxy
        CoverRouterV2 crImpl = new CoverRouterV2();
        ERC1967Proxy crProxy = new ERC1967Proxy(
            address(crImpl),
            abi.encodeWithSelector(
                CoverRouterV2.initialize.selector, address(usdc), address(policyManager), address(twapBurner)
            )
        );
        CoverRouterV2 coverRouter = CoverRouterV2(address(crProxy));
        console.log("CoverRouterV2 (proxy):", address(coverRouter));

        // Wire PolicyManager <-> Router
        policyManager.setRouter(address(coverRouter));
        console.log("PolicyManager.setRouter done");

        // Wire CoverRouterV2 -> CapacityOracle (auto-pause at MIN_PRICE_FOR_NEW_POLICIES)
        coverRouter.setCapacityOracle(address(capacityOracle));
        console.log("CoverRouter.setCapacityOracle done");

        // Wire BondVault -> PolicyManager (one-shot)
        bondVault.setPolicyManager(address(policyManager));
        console.log("BondVault.setPolicyManager done");

        // ──────────────────────────────────────────────────
        // PHASE 9: Marketplace + BuybackEngine
        // ──────────────────────────────────────────────────
        // [V5.1] LuminaBondMarketplace via UUPS proxy
        LuminaBondMarketplace marketplaceImpl = new LuminaBondMarketplace();
        ERC1967Proxy marketplaceProxy = new ERC1967Proxy(
            address(marketplaceImpl),
            abi.encodeWithSelector(
                LuminaBondMarketplace.initialize.selector,
                address(claimBond),
                address(usdc),
                address(twapBurner),
                deployer
            )
        );
        LuminaBondMarketplace marketplace = LuminaBondMarketplace(address(marketplaceProxy));
        console.log("LuminaBondMarketplace (proxy):", address(marketplace));

        // [V5.1] BuybackEngine via UUPS proxy
        BuybackEngine buybackImpl = new BuybackEngine();
        ERC1967Proxy buybackProxy = new ERC1967Proxy(
            address(buybackImpl),
            abi.encodeWithSelector(
                BuybackEngine.initialize.selector,
                address(claimBond),
                address(bondVault),
                address(solvencyOracle),
                address(capacityOracle),
                address(marketplace),
                address(usdc),
                deployer
            )
        );
        BuybackEngine buybackEngine = BuybackEngine(address(buybackProxy));
        console.log("BuybackEngine (proxy):", address(buybackEngine));

        // ──────────────────────────────────────────────────
        // PHASE 9b: ShieldKeeper via UUPS proxy (Chainlink Automation)
        // ──────────────────────────────────────────────────
        ShieldKeeper shieldKeeperImpl = new ShieldKeeper();
        ERC1967Proxy shieldKeeperProxy = new ERC1967Proxy(
            address(shieldKeeperImpl), abi.encodeWithSelector(ShieldKeeper.initialize.selector, address(policyManager))
        );
        ShieldKeeper shieldKeeper = ShieldKeeper(address(shieldKeeperProxy));
        console.log("ShieldKeeper (proxy):", address(shieldKeeper));

        // ──────────────────────────────────────────────────
        // PHASE 9c: Deploy Shields
        // [Sprint T-30a Phase B] Shield deploy + registration + configuration
        // removed (old shields deleted). Phase C re-introduces the new shield
        // set with the drop-from-purchase mechanic + Chainlink direct-read.
        // Mock oracles are also no longer needed (the new shields read
        // Chainlink directly). RateShockShield NOT replaced (founder decision).
        // TODO Phase C:
        //   1. Deploy new shield set via UUPS proxies.
        //   2. policyManager.registerProduct(<NEW_PRODUCT_ID>, <newShield>) per shield.
        //   3. coverRouter.configureProduct(<NEW_PRODUCT_ID>, ...) per shield.
        //   4. Log shield addresses below.
        // ──────────────────────────────────────────────────

        // Authorize BuybackEngine in BondVault
        bondVault.setAuthorizedCaller(address(buybackEngine), true);
        console.log("BuybackEngine authorized in BondVault");

        // [Fix audit #31 CRITICAL] Authorize Marketplace + BuybackEngine as ClaimBond operators.
        // Required by Fix #18's transfer whitelist. Without these the Marketplace
        // is non-functional post-deploy (every list/buy reverts).
        claimBond.setAuthorizedOperator(address(marketplace), true);
        claimBond.setAuthorizedOperator(address(buybackEngine), true);
        console.log("Marketplace + BuybackEngine authorized as ClaimBond operators");

        // ──────────────────────────────────────────────────
        // PHASE 10: Wire TWAPBurner
        // ──────────────────────────────────────────────────
        twapBurner.setFeeDistributor(address(feeDistributor));
        twapBurner.setReserves(
            address(buybackEngine),
            deployer, // opsReserve (deployer on testnet)
            address(maintenanceReserve)
        );
        twapBurner.setCapacityOracle(address(capacityOracle));
        twapBurner.setAuthorizedSender(address(coverRouter), true);
        twapBurner.setAdaptiveMode(true);
        console.log("TWAPBurner wiring done");

        // Grant BURNER_ROLE to TWAPBurner
        lumina.grantRole(lumina.BURNER_ROLE(), address(twapBurner));
        console.log("BURNER_ROLE granted to TWAPBurner");

        // ──────────────────────────────────────────────────
        // PHASE 11: Summary
        // ──────────────────────────────────────────────────
        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("Network: Sepolia (testnet)");
        console.log("");
        console.log("--- Mocks ---");
        console.log("  MockUSDC:           ", address(usdc));
        console.log("  MockBTCOracle:      ", address(mockBtcOracle));
        console.log("  MockETHOracle:      ", address(mockEthOracle));
        console.log("  MockDexRouter:      ", address(dexRouter));
        console.log("");
        console.log("--- Core Protocol ---");
        console.log("  LuminaTokenV2:      ", address(lumina));
        console.log("  ClaimBond:          ", address(claimBond));
        console.log("  BondVault:          ", address(bondVault));
        console.log("  CapacityOracle:     ", address(capacityOracle));
        console.log("  SolvencyOracle:     ", address(solvencyOracle));
        console.log("  FeeDistributor:     ", address(feeDistributor));
        console.log("  TWAPBurner:         ", address(twapBurner));
        console.log("  PolicyManagerV2:    ", address(policyManager));
        console.log("  CoverRouterV2:      ", address(coverRouter));
        console.log("  CEXLiquidityReserve:", address(cexReserve));
        console.log("  TreasuryVesting:    ", address(treasuryVesting));
        console.log("  MaintenanceReserve: ", address(maintenanceReserve));
        console.log("  Marketplace:        ", address(marketplace));
        console.log("  BuybackEngine:      ", address(buybackEngine));
        console.log("  ShieldKeeper:       ", address(shieldKeeper));
        console.log("");
        console.log("");
        console.log("--- Shields ---");
        console.log("  (none; pending Phase C -- Sprint T-30a re-implementation)");
        console.log("");
        console.log("--- Placeholders ---");
        console.log("  FounderVesting:     ", founderVesting);
        console.log("  LBP Deposit:        ", lbpDeposit);

        vm.stopBroadcast();
    }

    /// @dev Deterministic address from a label (for placeholder addresses).
    function _labelToAddress(string memory label) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(label)))));
    }
}
