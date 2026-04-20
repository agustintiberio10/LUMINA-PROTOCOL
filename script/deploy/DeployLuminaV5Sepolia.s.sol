// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

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
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
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
        MaintenanceReserve maintenanceReserve = new MaintenanceReserve(address(usdc), deployer);
        console.log("MaintenanceReserve:", address(maintenanceReserve));

        ClaimBond claimBond = new ClaimBond();
        console.log("ClaimBond:", address(claimBond));

        // ──────────────────────────────────────────────────
        // PHASE 3: Predict LuminaTokenV2 address to break
        //          the circular dependency
        // ──────────────────────────────────────────────────
        // Contracts to deploy before lumina:
        //   capacityOracle, bondVault, cexReserve, treasuryVesting
        uint64 currentNonce = vm.getNonce(deployer);
        address predictedLumina = vm.computeCreateAddress(deployer, currentNonce + 4);
        console.log("Predicted LUMINA address:", predictedLumina);

        CapacityOracle capacityOracle = new CapacityOracle(
            address(0), // pool (none on Sepolia initially)
            predictedLumina, // luminaToken
            address(usdc), // usdcToken
            EMERGENCY_PRICE
        );
        console.log("CapacityOracle:", address(capacityOracle));

        BondVault bondVault = new BondVault(
            predictedLumina,
            address(claimBond),
            address(capacityOracle),
            address(0) // policyManager set later
        );
        console.log("BondVault:", address(bondVault));

        CEXLiquidityReserve cexReserve = new CEXLiquidityReserve(predictedLumina, deployer);
        console.log("CEXLiquidityReserve:", address(cexReserve));

        TreasuryVesting treasuryVesting = new TreasuryVesting(predictedLumina);
        console.log("TreasuryVesting:", address(treasuryVesting));

        // ──────────────────────────────────────────────────
        // PHASE 4: Deploy LuminaTokenV2
        // ──────────────────────────────────────────────────
        address founderVesting = _labelToAddress("founderVesting");
        address lbpDeposit = _labelToAddress("lbpDeposit");

        LuminaTokenV2 lumina = new LuminaTokenV2(
            address(bondVault), address(cexReserve), founderVesting, lbpDeposit, address(treasuryVesting)
        );
        require(address(lumina) == predictedLumina, "LUMINA address prediction failed!");
        console.log("LuminaTokenV2:", address(lumina));

        // ──────────────────────────────────────────────────
        // PHASE 5: Wire ClaimBond -> BondVault
        // ──────────────────────────────────────────────────
        claimBond.setBondVault(address(bondVault));
        console.log("ClaimBond.setBondVault done");

        // ──────────────────────────────────────────────────
        // PHASE 6: SolvencyOracle + AdaptiveFeeDistributor
        // ──────────────────────────────────────────────────
        SolvencyOracle solvencyOracle = new SolvencyOracle(address(bondVault), address(capacityOracle), deployer);
        console.log("SolvencyOracle:", address(solvencyOracle));

        AdaptiveFeeDistributor feeDistributor = new AdaptiveFeeDistributor(address(solvencyOracle));
        console.log("AdaptiveFeeDistributor:", address(feeDistributor));

        // ──────────────────────────────────────────────────
        // PHASE 7: TWAPBurner
        // ──────────────────────────────────────────────────
        TWAPBurner twapBurner = new TWAPBurner(address(usdc), address(lumina), address(dexRouter));
        console.log("TWAPBurner:", address(twapBurner));

        // ──────────────────────────────────────────────────
        // PHASE 8: PolicyManagerV2 + CoverRouterV2
        // ──────────────────────────────────────────────────
        PolicyManagerV2 policyManager = new PolicyManagerV2(address(bondVault));
        console.log("PolicyManagerV2:", address(policyManager));

        CoverRouterV2 coverRouter = new CoverRouterV2(address(usdc), address(policyManager), address(twapBurner));
        console.log("CoverRouterV2:", address(coverRouter));

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
        LuminaBondMarketplace marketplace =
            new LuminaBondMarketplace(address(claimBond), address(usdc), address(twapBurner), deployer);
        console.log("LuminaBondMarketplace:", address(marketplace));

        BuybackEngine buybackEngine = new BuybackEngine(
            address(claimBond),
            address(bondVault),
            address(solvencyOracle),
            address(capacityOracle),
            address(marketplace),
            address(usdc),
            deployer
        );
        console.log("BuybackEngine:", address(buybackEngine));

        // ──────────────────────────────────────────────────
        // PHASE 9b: ShieldKeeper (Chainlink Automation)
        // ──────────────────────────────────────────────────
        ShieldKeeper shieldKeeper = new ShieldKeeper(address(policyManager));
        console.log("ShieldKeeper:", address(shieldKeeper));

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
