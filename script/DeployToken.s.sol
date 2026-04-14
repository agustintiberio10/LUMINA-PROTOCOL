// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/token/LuminaToken.sol";
import "../src/token/AltSeasonVesting.sol";
import "../src/token/LuminaPriceOracle.sol";
import "../src/token/LuminaMerkleClaim.sol";

contract DeployToken is Script {
    // Base mainnet addresses
    address constant ORACLE_V2 = 0x87B576f688bE0E1d7d23A299f55b475658215105;
    address constant AAVE_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant TIMELOCK = 0xd0De5D53dCA2D96cdE7FAf540BA3f3a44fdB747a;

    // Founder wallet — receives all 35M free tokens + is initial recipient for 5/7 vesting allocations
    address constant FOUNDER = 0x989cDddEa637b86B38B39d55D197A0021ECEe111;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // ═══ Resolve chicken-and-egg: predict vesting address before deploying token ═══
        // Deploy order: Token (nonce N), Vesting (nonce N+1), PriceOracle (N+2), SeedClaim (N+3), StrategicClaim (N+4)
        uint64 deployerNonce = vm.getNonce(deployer);
        address predictedVesting = _computeCreate(deployer, deployerNonce + 1);

        // ═══ Vesting recipients: 7 allocations summing to 65M ═══
        // Index 0+1 will be updated to MerkleClaim contracts after deploy
        address[] memory recipients = new address[](7);
        recipients[0] = FOUNDER; // Seed (10M) — will be updated to seedClaim
        recipients[1] = FOUNDER; // Strategic (10M) — will be updated to strategicClaim
        recipients[2] = FOUNDER; // Community (10M)
        recipients[3] = FOUNDER; // Founder 1 (7.5M)
        recipients[4] = FOUNDER; // Founder 2 (7.5M) — temporal, change later via Safe
        recipients[5] = FOUNDER; // Growth & Partnerships (15M)
        recipients[6] = FOUNDER; // Devs (5M)

        uint256[] memory amounts = new uint256[](7);
        amounts[0] = 10_000_000 * 1e18; // Seed
        amounts[1] = 10_000_000 * 1e18; // Strategic
        amounts[2] = 10_000_000 * 1e18; // Community
        amounts[3] = 7_500_000 * 1e18; // Founder 1
        amounts[4] = 7_500_000 * 1e18; // Founder 2
        amounts[5] = 15_000_000 * 1e18; // Growth
        amounts[6] = 5_000_000 * 1e18; // Devs

        vm.startBroadcast(deployerPrivateKey);

        // ═══ Step 1: Deploy LuminaToken ═══
        // Mints: 10M treasury + 15M protocol buyback + 10M liquidity → FOUNDER (35M free)
        //        65M → predictedVesting address
        LuminaToken token = new LuminaToken(FOUNDER, FOUNDER, FOUNDER, predictedVesting);

        // ═══ Step 2: Deploy AltSeasonVesting ═══
        // Must land at predictedVesting — receives 65M from token constructor
        AltSeasonVesting vesting = new AltSeasonVesting(ORACLE_V2, AAVE_POOL, address(token), USDC, recipients, amounts);
        require(address(vesting) == predictedVesting, "Vesting address mismatch");

        // ═══ Step 3: Deploy LuminaPriceOracle ═══
        LuminaPriceOracle priceOracle = new LuminaPriceOracle(40000); // $0.04 initial

        // ═══ Step 4: Deploy MerkleClaim contracts for Seed and Strategic ═══
        LuminaMerkleClaim seedClaim = new LuminaMerkleClaim(address(token));
        LuminaMerkleClaim strategicClaim = new LuminaMerkleClaim(address(token));

        // Point vesting index 0 (Seed) and 1 (Strategic) to MerkleClaim contracts
        vesting.updateRecipient(0, address(seedClaim));
        vesting.updateRecipient(1, address(strategicClaim));

        // ═══ Step 5: Transfer ownership to TimelockController ═══
        token.grantRole(token.DEFAULT_ADMIN_ROLE(), TIMELOCK);
        token.renounceRole(token.DEFAULT_ADMIN_ROLE(), deployer);
        vesting.transferOwnership(TIMELOCK);
        priceOracle.transferOwnership(TIMELOCK);
        seedClaim.transferOwnership(TIMELOCK);
        strategicClaim.transferOwnership(TIMELOCK);

        vm.stopBroadcast();

        // ═══ Verification ═══
        require(token.balanceOf(FOUNDER) == 35_000_000 * 1e18, "Founder should have 35M");
        require(token.balanceOf(address(vesting)) == 65_000_000 * 1e18, "Vesting should have 65M");
        require(token.totalSupply() == 100_000_000 * 1e18, "Total supply must be 100M");
        require(token.hasRole(token.DEFAULT_ADMIN_ROLE(), TIMELOCK), "Timelock not admin");
        require(!token.hasRole(token.DEFAULT_ADMIN_ROLE(), deployer), "Deployer still admin");
        require(vesting.owner() == TIMELOCK, "Vesting owner not timelock");

        // ═══ Log ═══
        console.log("=== LUMINA TOKEN DEPLOYMENT ===");
        console.log("Token:          ", address(token));
        console.log("Vesting:        ", address(vesting));
        console.log("PriceOracle:    ", address(priceOracle));
        console.log("SeedClaim:      ", address(seedClaim));
        console.log("StrategicClaim: ", address(strategicClaim));
        console.log("Founder:        ", FOUNDER);
        console.log("Founder balance:", token.balanceOf(FOUNDER) / 1e18, "LUMINA (35M free)");
        console.log("Vesting balance:", token.balanceOf(address(vesting)) / 1e18, "LUMINA (65M locked)");
        console.log("Owner:          ", TIMELOCK);
    }

    function _computeCreate(address _deployer, uint64 nonce) internal pure returns (address) {
        bytes memory data;
        if (nonce == 0x00) {
            data = abi.encodePacked(bytes1(0xd6), bytes1(0x94), _deployer, bytes1(0x80));
        } else if (nonce <= 0x7f) {
            data = abi.encodePacked(bytes1(0xd6), bytes1(0x94), _deployer, uint8(nonce));
        } else if (nonce <= 0xff) {
            data = abi.encodePacked(bytes1(0xd7), bytes1(0x94), _deployer, bytes1(0x81), uint8(nonce));
        } else if (nonce <= 0xffff) {
            data = abi.encodePacked(bytes1(0xd8), bytes1(0x94), _deployer, bytes1(0x82), uint16(nonce));
        } else if (nonce <= 0xffffff) {
            data = abi.encodePacked(bytes1(0xd9), bytes1(0x94), _deployer, bytes1(0x83), uint24(nonce));
        } else {
            data = abi.encodePacked(bytes1(0xda), bytes1(0x94), _deployer, bytes1(0x84), uint32(nonce));
        }
        return address(uint160(uint256(keccak256(data))));
    }
}
