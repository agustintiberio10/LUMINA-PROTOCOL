// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LuminaTokenV2} from "../../src/token/LuminaTokenV2.sol";
import {BondVault} from "../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../src/bonds/ClaimBond.sol";
import {PolicyManagerV2} from "../../src/core/PolicyManagerV2.sol";
import {CoverRouterV2} from "../../src/core/CoverRouterV2.sol";
import {TWAPBurner} from "../../src/core/TWAPBurner.sol";
import {BuybackEngine} from "../../src/marketplace/BuybackEngine.sol";
import {LuminaBondMarketplace} from "../../src/marketplace/LuminaBondMarketplace.sol";
import {ShieldKeeper} from "../../src/automation/ShieldKeeper.sol";
import {FlashBTCShield1h} from "../../src/products/FlashBTCShield1h.sol";
import {FlashBTCShield24h} from "../../src/products/FlashBTCShield24h.sol";
import {FlashBTCShield48h} from "../../src/products/FlashBTCShield48h.sol";
import {FlashETHShield1h} from "../../src/products/FlashETHShield1h.sol";
import {FlashETHShield24h} from "../../src/products/FlashETHShield24h.sol";
import {FlashETHShield48h} from "../../src/products/FlashETHShield48h.sol";
import {RateShockShield} from "../../src/products/RateShockShield.sol";
import {CapacityOracle} from "../../src/oracles/CapacityOracle.sol";
import {SolvencyOracle} from "../../src/oracles/SolvencyOracle.sol";
import {AdaptiveFeeDistributor} from "../../src/core/AdaptiveFeeDistributor.sol";
import {CEXLiquidityReserve} from "../../src/treasury/CEXLiquidityReserve.sol";
import {MaintenanceReserve} from "../../src/treasury/MaintenanceReserve.sol";
import {TreasuryVesting} from "../../src/token/TreasuryVesting.sol";

/// @notice Helper library for deploying UUPS proxied contracts in tests.
/// @dev Provides the same interface as the old constructors but deploys behind ERC1967Proxy.
library ProxyDeployer {
    function deployLuminaTokenV2(
        address bondVault,
        address cexLiquidityReserve,
        address founderVesting,
        address lbpDeposit,
        address treasuryVesting
    ) internal returns (LuminaTokenV2) {
        LuminaTokenV2 impl = new LuminaTokenV2();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                LuminaTokenV2.initialize.selector,
                bondVault,
                cexLiquidityReserve,
                founderVesting,
                lbpDeposit,
                treasuryVesting
            )
        );
        return LuminaTokenV2(address(proxy));
    }

    function deployBondVault(address _lumina, address _claimBond, address _priceOracle, address _policyManager)
        internal
        returns (BondVault)
    {
        BondVault impl = new BondVault();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(BondVault.initialize.selector, _lumina, _claimBond, _priceOracle, _policyManager)
        );
        return BondVault(address(proxy));
    }

    function deployClaimBond() internal returns (ClaimBond) {
        ClaimBond impl = new ClaimBond();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeWithSelector(ClaimBond.initialize.selector));
        return ClaimBond(address(proxy));
    }

    function deployPolicyManagerV2(address _bondVault) internal returns (PolicyManagerV2) {
        PolicyManagerV2 impl = new PolicyManagerV2();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeWithSelector(PolicyManagerV2.initialize.selector, _bondVault));
        return PolicyManagerV2(address(proxy));
    }

    function deployCoverRouterV2(address _usdc, address _policyManager, address _twapBurner)
        internal
        returns (CoverRouterV2)
    {
        CoverRouterV2 impl = new CoverRouterV2();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeWithSelector(CoverRouterV2.initialize.selector, _usdc, _policyManager, _twapBurner)
        );
        return CoverRouterV2(address(proxy));
    }

    function deployTWAPBurner(address _usdc, address _lumina, address _initialDexRouter) internal returns (TWAPBurner) {
        TWAPBurner impl = new TWAPBurner();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeWithSelector(TWAPBurner.initialize.selector, _usdc, _lumina, _initialDexRouter)
        );
        return TWAPBurner(payable(address(proxy)));
    }

    function deployBuybackEngine(
        address _claimBond,
        address _bondVault,
        address _solvencyOracle,
        address _capacityOracle,
        address _marketplace,
        address _usdc,
        address _multisigOwner
    ) internal returns (BuybackEngine) {
        BuybackEngine impl = new BuybackEngine();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                BuybackEngine.initialize.selector,
                _claimBond,
                _bondVault,
                _solvencyOracle,
                _capacityOracle,
                _marketplace,
                _usdc,
                _multisigOwner
            )
        );
        return BuybackEngine(address(proxy));
    }

    function deployLuminaBondMarketplace(address _claimBond, address _usdc, address _twapBurner, address _admin)
        internal
        returns (LuminaBondMarketplace)
    {
        LuminaBondMarketplace impl = new LuminaBondMarketplace();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(LuminaBondMarketplace.initialize.selector, _claimBond, _usdc, _twapBurner, _admin)
        );
        return LuminaBondMarketplace(address(proxy));
    }

    function deployShieldKeeper(address _policyManager) internal returns (ShieldKeeper) {
        ShieldKeeper impl = new ShieldKeeper();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeWithSelector(ShieldKeeper.initialize.selector, _policyManager));
        return ShieldKeeper(address(proxy));
    }

    // ═══════ SHIELDS ═══════

    function deployFlashBTCShield1h(address router_, address oracle_) internal returns (FlashBTCShield1h) {
        FlashBTCShield1h impl = new FlashBTCShield1h();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeWithSelector(FlashBTCShield1h.initialize.selector, router_, oracle_)
        );
        return FlashBTCShield1h(address(proxy));
    }

    function deployFlashBTCShield24h(address router_, address oracle_) internal returns (FlashBTCShield24h) {
        FlashBTCShield24h impl = new FlashBTCShield24h();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeWithSelector(FlashBTCShield24h.initialize.selector, router_, oracle_)
        );
        return FlashBTCShield24h(address(proxy));
    }

    function deployFlashBTCShield48h(address router_, address oracle_) internal returns (FlashBTCShield48h) {
        FlashBTCShield48h impl = new FlashBTCShield48h();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeWithSelector(FlashBTCShield48h.initialize.selector, router_, oracle_)
        );
        return FlashBTCShield48h(address(proxy));
    }

    function deployFlashETHShield1h(address router_, address oracle_) internal returns (FlashETHShield1h) {
        FlashETHShield1h impl = new FlashETHShield1h();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeWithSelector(FlashETHShield1h.initialize.selector, router_, oracle_)
        );
        return FlashETHShield1h(address(proxy));
    }

    function deployFlashETHShield24h(address router_, address oracle_) internal returns (FlashETHShield24h) {
        FlashETHShield24h impl = new FlashETHShield24h();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeWithSelector(FlashETHShield24h.initialize.selector, router_, oracle_)
        );
        return FlashETHShield24h(address(proxy));
    }

    function deployFlashETHShield48h(address router_, address oracle_) internal returns (FlashETHShield48h) {
        FlashETHShield48h impl = new FlashETHShield48h();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeWithSelector(FlashETHShield48h.initialize.selector, router_, oracle_)
        );
        return FlashETHShield48h(address(proxy));
    }

    function deployRateShockShield(address router_, address oracle_, address _aavePool, address _usdc)
        internal
        returns (RateShockShield)
    {
        RateShockShield impl = new RateShockShield();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(RateShockShield.initialize.selector, router_, oracle_, _aavePool, _usdc)
        );
        return RateShockShield(address(proxy));
    }

    // ═══════ PHASE D: ORACLES & RESERVES ═══════

    function deployCapacityOracle(address _pool, address _luminaToken, address _usdcToken, uint256 _emergencyPrice)
        internal
        returns (CapacityOracle)
    {
        CapacityOracle impl = new CapacityOracle();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(CapacityOracle.initialize.selector, _pool, _luminaToken, _usdcToken, _emergencyPrice)
        );
        return CapacityOracle(address(proxy));
    }

    function deploySolvencyOracle(address _bondVault, address _capacityOracle, address _admin)
        internal
        returns (SolvencyOracle)
    {
        SolvencyOracle impl = new SolvencyOracle();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(SolvencyOracle.initialize.selector, _bondVault, _capacityOracle, _admin)
        );
        return SolvencyOracle(address(proxy));
    }

    function deployAdaptiveFeeDistributor(address _solvencyOracle) internal returns (AdaptiveFeeDistributor) {
        AdaptiveFeeDistributor impl = new AdaptiveFeeDistributor();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeWithSelector(AdaptiveFeeDistributor.initialize.selector, _solvencyOracle)
        );
        return AdaptiveFeeDistributor(address(proxy));
    }

    function deployCEXLiquidityReserve(address _lumina, address _multisigOwner) internal returns (CEXLiquidityReserve) {
        CEXLiquidityReserve impl = new CEXLiquidityReserve();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeWithSelector(CEXLiquidityReserve.initialize.selector, _lumina, _multisigOwner)
        );
        return CEXLiquidityReserve(address(proxy));
    }

    function deployMaintenanceReserve(address _usdc, address _admin) internal returns (MaintenanceReserve) {
        MaintenanceReserve impl = new MaintenanceReserve();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeWithSelector(MaintenanceReserve.initialize.selector, _usdc, _admin)
        );
        return MaintenanceReserve(address(proxy));
    }

    function deployTreasuryVesting(address _luminaToken) internal returns (TreasuryVesting) {
        TreasuryVesting impl = new TreasuryVesting();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeWithSelector(TreasuryVesting.initialize.selector, _luminaToken));
        return TreasuryVesting(address(proxy));
    }
}
