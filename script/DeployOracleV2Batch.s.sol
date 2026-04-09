// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
 * ─────────────────────────────────────────────────────────────────────────────
 *  DeployOracleV2Batch
 * ─────────────────────────────────────────────────────────────────────────────
 *
 *  PURPOSE
 *  This script ONLY deploys the new LuminaOracleV2 + the V2 shields and
 *  registers Chainlink price feeds on the new oracle. It does NOT touch the
 *  live CoverRouter; i.e. it does NOT swap productId → shield mappings and
 *  does NOT touch the circuit-breaker parameters. Those cutover operations
 *  happen through a separate Gnosis Safe batch:
 *
 *      script/safe-tx-oracle-v2-migration.json
 *
 *  OPERATOR CHECKLIST
 *  1. Run this script against Base mainnet:
 *       forge script script/DeployOracleV2Batch.s.sol:DeployOracleV2Batch \
 *         --rpc-url $BASE_RPC --broadcast --verify
 *  2. Copy the six addresses printed under "=== ORACLE V2 BATCH ===" below.
 *  3. Open script/safe-tx-oracle-v2-migration.json and replace every
 *     <...V2_ADDRESS> placeholder with the corresponding broadcast address.
 *  4. Regenerate the calldata for each entry inside the Safe Transaction
 *     Builder UI (the JSON ships with `data: "0x00"` placeholders on purpose).
 *  5. Schedule + execute the batch via the TimelockController
 *     (0xd0De5D53dCA2D96cdE7FAf540BA3f3a44fdB747a), which is the owner of
 *     CoverRouter and — after this script — of LuminaOracleV2.
 *
 *  NOTES
 *  - LuminaOracleV2 is NOT upgradeable. To replace it later, deploy V3 and
 *    redeploy every Shield that references it (Shield.oracle is `immutable`).
 */

import {Script, console} from "forge-std/Script.sol";

import {LuminaOracleV2} from "../src/oracles/LuminaOracleV2.sol";
import {BTCCatastropheShieldV2} from "../src/products/BTCCatastropheShieldV2.sol";
import {ETHApocalypseShieldV2} from "../src/products/ETHApocalypseShieldV2.sol";
import {DepegShieldV2} from "../src/products/DepegShieldV2.sol";
import {ILIndexCoverV2} from "../src/products/ILIndexCoverV2.sol";
import {ExploitShieldV2} from "../src/products/ExploitShieldV2.sol";

contract DeployOracleV2Batch is Script {
    // ─── Network ────────────────────────────────────────────────────────
    uint256 internal constant CHAIN_ID = 8453; // Base mainnet

    // ─── Protocol addresses (copied from DeployFreshBatch.s.sol) ────────
    address internal constant COVER_ROUTER = 0xd5f8678A0F2149B6342F9014CCe6d743234Ca025;
    address internal constant TIMELOCK     = 0xd0De5D53dCA2D96cdE7FAf540BA3f3a44fdB747a;
    address internal constant SAFE         = 0xa17e8b7f985022BC3c607e9c4858A1C264b33cFD;
    address internal constant ORACLE_KEY   = 0x933b15dd4F42bd2EE2794C1D188882aBCCDa977E;
    address internal constant SEQUENCER_UPTIME_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    address internal constant PHALA_VERIFIER = 0x468b9D2E9043c80467B610bC290b698ae23adb9B;
    address internal constant AAVE_POOL      = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;

    // ─── Chainlink price feeds (Base mainnet) ───────────────────────────
    address internal constant BTC_FEED  = 0xCCADC697c55bbB68dc5bCdf8d3CBe83CdD4E071E; // BTC/USD (corrected)
    address internal constant ETH_FEED  = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70; // ETH/USD
    address internal constant USDC_FEED = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B; // USDC/USD
    address internal constant USDT_FEED = 0xf19d560eB8d2ADf07BD6D13ed03e1D11215721F9; // USDT/USD
    address internal constant DAI_FEED  = 0x591e79239a7d679378eC8c847e5038150364C78F; // DAI/USD

    // ─── Heartbeats ─────────────────────────────────────────────────────
    uint256 internal constant HB_CRYPTO = 1200;  // 20 min  (BTC, ETH)
    uint256 internal constant HB_STABLE = 86400; // 24 h    (USDC, USDT, DAI)

    function run() external {
        require(block.chainid == CHAIN_ID, "wrong chain");

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerKey);

        // 1. Deploy LuminaOracleV2 — initial owner is the deployer so we
        //    can register feeds in this same broadcast. Ownership is
        //    transferred to the TimelockController at the end.
        LuminaOracleV2 oracle = new LuminaOracleV2(
            deployer,
            ORACLE_KEY,
            SEQUENCER_UPTIME_FEED
        );
        console.log("LuminaOracleV2:", address(oracle));

        // 2. Register Chainlink feeds on the new oracle.
        oracle.registerFeed(bytes32("BTC"),  BTC_FEED,  HB_CRYPTO);
        oracle.registerFeed(bytes32("ETH"),  ETH_FEED,  HB_CRYPTO);
        oracle.registerFeed(bytes32("USDC"), USDC_FEED, HB_STABLE);
        oracle.registerFeed(bytes32("USDT"), USDT_FEED, HB_STABLE);
        oracle.registerFeed(bytes32("DAI"),  DAI_FEED,  HB_STABLE);

        // 3. Deploy V2 shields. router = live CoverRouter proxy, oracle = V2.
        BTCCatastropheShieldV2 bcs = new BTCCatastropheShieldV2(COVER_ROUTER, address(oracle));
        console.log("BTCCatastropheShieldV2:", address(bcs));

        ETHApocalypseShieldV2 eas = new ETHApocalypseShieldV2(COVER_ROUTER, address(oracle));
        console.log("ETHApocalypseShieldV2:", address(eas));

        DepegShieldV2 depeg = new DepegShieldV2(COVER_ROUTER, address(oracle));
        console.log("DepegShieldV2:", address(depeg));

        ILIndexCoverV2 il = new ILIndexCoverV2(COVER_ROUTER, address(oracle));
        console.log("ILIndexCoverV2:", address(il));

        ExploitShieldV2 exploit = new ExploitShieldV2(
            COVER_ROUTER,
            address(oracle),
            PHALA_VERIFIER,
            AAVE_POOL
        );
        console.log("ExploitShieldV2:", address(exploit));

        // 4. Hand the oracle over to the Timelock. From now on any feed
        //    registration / signer change goes through the Safe→Timelock
        //    two-step governance path.
        oracle.transferOwnership(TIMELOCK);

        vm.stopBroadcast();

        console.log("");
        console.log("=== ORACLE V2 BATCH ===");
        console.log("LuminaOracleV2:         ", address(oracle));
        console.log("BTCCatastropheShieldV2: ", address(bcs));
        console.log("ETHApocalypseShieldV2:  ", address(eas));
        console.log("DepegShieldV2:          ", address(depeg));
        console.log("ILIndexCoverV2:         ", address(il));
        console.log("ExploitShieldV2:        ", address(exploit));
        console.log("");
        console.log("NEXT: paste these into script/safe-tx-oracle-v2-migration.json");
        console.log("      then schedule+execute via TimelockController at");
        console.log("     ", TIMELOCK);
    }
}
