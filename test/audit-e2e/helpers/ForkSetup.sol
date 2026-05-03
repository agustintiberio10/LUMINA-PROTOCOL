// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

/// @title ForkSetup
/// @notice Pinned addresses + role helpers for the V5.1 Sepolia deploy
///         (chainId 84532). All audit-e2e fork tests inherit from this.
abstract contract ForkSetup is Test {
    // ?????????????????????????????????????????????????????????????????????
    //  PINNED V5.1 DEPLOY (Base Sepolia, 2026-05-03)
    // ?????????????????????????????????????????????????????????????????????

    address constant LUMINA_TOKEN = 0x8A0FDc2126eb9b0c88D17711D62713A1c06CF7Ab;
    address constant CLAIM_BOND = 0x3d2F5DB2505367D00ef81c51AD3cA66159271730;
    address constant BOND_VAULT = 0x101F92fC506C1e60A2A0dD01eA29597EBf222d2B;
    address constant POLICY_MANAGER = 0xd9732A8d6Cf5266Dd896B825E78E387B7Dd2c379;
    address constant COVER_ROUTER = 0xebC3A783477FbD2720C024e16A8d63B8Db983D84;
    address constant MARKETPLACE = 0xfaC56692c626718aC8953A3d5fAE67fac2f1Be6E;
    address constant BUYBACK_ENGINE = 0x42Ec14D60c9f2baE0E2aE8dcC870D23B2F1052Be;
    address constant TWAP_BURNER = 0x13B2180B4CaAb480000Cf96BA3d6957CD316144e;
    address constant ADAPTIVE_FEE_DISTRIBUTOR = 0x93252064E03Ef3592C436e61414003C3398A83D5;
    address constant CAPACITY_ORACLE = 0x9e1784F1D29b21e293Eb2C9aA2151202BE522e42;
    address constant SOLVENCY_ORACLE = 0x934CB8A95Cce0e46BD29bE06333513c447ABbD4a;
    address constant CHAINLINK_GRACE_ORACLE = 0x3E3D74cbEE4F21983618738440C056c73a2709d5;
    address constant CEX_LIQUIDITY_RESERVE = 0xb2d685021b11cE12E56663Cc0428905935162863;
    address constant TREASURY_VESTING = 0x9297B9ce2691A06d0067d9A7B0D03F063f382f74;
    address constant MAINTENANCE_RESERVE = 0x775ED2f2C6af666b692fB8319DD7C988d48a8144;
    address constant SHIELD_KEEPER = 0xa5F7E1dee257E2517c885ef06bbF80A3Fe223260;
    address constant FOUNDER_VESTING = 0x00Ce9A18A97B0058F917ebB3C105386c875cEd58;
    address constant USDC = 0xD944d8e5D8329994D83950872Ec210891d3Ab6AE;

    address constant SHIELD_FLASH_BTC_1H = 0xF5753268bcb2D920Cf904F674b8A1e8297267Ac0;
    address constant SHIELD_FLASH_BTC_4H = 0x245D6b71F058E1029db2dA23801b7768DF0C55AA;
    address constant SHIELD_FLASH_BTC_24H = 0xCBDA797924BAdbE28c3e719a8ef2Ef534a062468;
    address constant SHIELD_FLASH_BTC_48H = 0x40E95285f70b875F0000e7a2C4de3CfEf075102b;
    address constant SHIELD_FLASH_ETH_1H = 0x0E1156f34201D254f8bD7e69843c37daF62d04ac;
    address constant SHIELD_FLASH_ETH_24H = 0xD9B0E4A7D369473e05BD86A94eB60C297a996c6a;
    address constant SHIELD_FLASH_ETH_48H = 0xff6Ae8135Ae334223F0f748A889B3DBa8556CA2F;
    address constant SHIELD_MICRO_DEPEG = 0x44a4488A16b4d92dc50f990F904D8eca7e6fb219;
    address constant SHIELD_RATE_SHOCK = 0x63C93d21738c1FebE9c6E599CF44D3630B2C6A8F;

    address constant DEPLOYER = 0xe585e76A0b8CbbC2d10b1110a9ac3F4c11dBfDa8;

    address[9] internal allShields = [
        SHIELD_FLASH_BTC_1H, SHIELD_FLASH_BTC_4H, SHIELD_FLASH_BTC_24H, SHIELD_FLASH_BTC_48H,
        SHIELD_FLASH_ETH_1H, SHIELD_FLASH_ETH_24H, SHIELD_FLASH_ETH_48H,
        SHIELD_MICRO_DEPEG, SHIELD_RATE_SHOCK
    ];

    // Test actors
    address payable internal alice = payable(makeAddr("alice"));
    address payable internal bob = payable(makeAddr("bob"));
    address payable internal carol = payable(makeAddr("carol"));
    address payable internal attacker = payable(makeAddr("attacker"));

    /// @notice Deal native ETH + mint USDC to a test actor.
    function setupActor(address actor, uint256 ethAmount, uint256 usdcAmount) internal {
        vm.deal(actor, ethAmount);
        if (usdcAmount > 0) {
            // MockUSDC on Sepolia accepts free mints. Use deal() to avoid the
            // mint() call so we don't depend on the mock's interface.
            deal(USDC, actor, usdcAmount);
        }
    }

    /// @notice Pranks as DEPLOYER (default admin/owner of the V5.1 deploy).
    modifier asDeployer() {
        vm.startPrank(DEPLOYER);
        _;
        vm.stopPrank();
    }
}
