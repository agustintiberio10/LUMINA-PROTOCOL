// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {FounderVestingV2} from "../../src/token/FounderVestingV2.sol";

/// @notice Sprint Z.2 — Deploy FounderVestingV2 wired to LuminaOracleV2 SET A.
///         No feed registration here: Chainlink Sepolia oracle addresses are not
///         pinned in the spec, so registerFeed is left to the founder (see
///         TODO_FOUNDER.md). Tests use vm.mockCall for the oracle path.
contract DeployFounderVestingV2 is Script {
    // ═══════ Base Sepolia canonical addresses ═══════
    address constant LUMINA_ORACLE_V2_SET_A = 0x8cAbC4645a3981FF59d39328f9F65FdFD19Bd194;
    address constant AAVE_POOL = 0xcc0606b64275c08539770864081D209A8C9b178a; // mock stub, same as v1
    address constant LUMINA_TOKEN_PROXY = 0x7D3E392Bdb3258cF92C257C90391957d7b0Aff02;
    address constant USDC_BASE_SEPOLIA = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address constant FOUNDER_RECIPIENT = 0xe585e76A0b8CbbC2d10b1110a9ac3F4c11dBfDa8;

    function run() external returns (FounderVestingV2 fv) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address sender = vm.addr(pk);

        vm.startBroadcast(pk);
        fv = new FounderVestingV2(
            LUMINA_ORACLE_V2_SET_A, AAVE_POOL, LUMINA_TOKEN_PROXY, USDC_BASE_SEPOLIA, FOUNDER_RECIPIENT
        );
        vm.stopBroadcast();

        console.log("=== FounderVestingV2 deployed ===");
        console.log("Address:                   ", address(fv));
        console.log("Deployer:                  ", sender);
        console.log("oracle():                  ", address(fv.oracle()));
        console.log("aavePool():                ", fv.aavePool());
        console.log("luminaToken():             ", address(fv.luminaToken()));
        console.log("usdc():                    ", fv.usdc());
        console.log("recipient():               ", fv.recipient());
        console.log("owner():                   ", fv.owner());
        console.log("SUSTAINED_DURATION (sec):  ", fv.SUSTAINED_DURATION());
        console.log("FALLBACK_DURATION (sec):   ", fv.FALLBACK_DURATION());
        console.log("deployedAt:                ", fv.deployedAt());

        require(address(fv.oracle()) == LUMINA_ORACLE_V2_SET_A, "oracle wiring mismatch");
        require(fv.recipient() == FOUNDER_RECIPIENT, "recipient wiring mismatch");
        require(fv.owner() == FOUNDER_RECIPIENT, "owner wiring mismatch");
        require(fv.SUSTAINED_DURATION() == 1 days, "sustained mismatch");
        require(fv.FALLBACK_DURATION() == 1095 days, "fallback mismatch");
    }
}
