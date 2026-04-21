// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LuminaTokenV2} from "../../src/token/LuminaTokenV2.sol";
import {BondVault} from "../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../src/bonds/ClaimBond.sol";
import {PolicyManagerV2} from "../../src/core/PolicyManagerV2.sol";
import {CoverRouterV2} from "../../src/core/CoverRouterV2.sol";

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
}
