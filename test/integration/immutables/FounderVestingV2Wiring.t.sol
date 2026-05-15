// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {FounderVestingV2} from "../../../src/token/FounderVestingV2.sol";

interface ILuminaOracleV2View {
    function getLatestPrice(bytes32 asset) external view returns (int256);
}

/// @title FounderVestingV2Wiring
/// @notice Sprint Z.2 Phase D — fork tests that validate the live on-chain wiring of
///         a deployed FounderVestingV2 instance. Gated by env var
///         `FOUNDER_VESTING_V2_ADDRESS`. If unset, every test cleanly skips so the
///         file is safe to include in CI before the founder broadcasts the deploy.
///
/// Usage (post-deploy):
///   FOUNDER_VESTING_V2_ADDRESS=0x... forge test --match-contract FounderVestingV2Wiring \
///       --fork-url $SEPOLIA_RPC -vv
contract FounderVestingV2WiringTest is Test {
    address constant LUMINA_ORACLE_V2_SET_A = 0x8cAbC4645a3981FF59d39328f9F65FdFD19Bd194;
    address constant AAVE_POOL_SEPOLIA = 0xcc0606b64275c08539770864081D209A8C9b178a;
    address constant LUMINA_PROXY = 0x7D3E392Bdb3258cF92C257C90391957d7b0Aff02;
    address constant FOUNDER = 0xe585e76A0b8CbbC2d10b1110a9ac3F4c11dBfDa8;

    // Selector for FeedNotRegistered() — the expected revert from LuminaOracleV2
    // when no feed is configured for the queried asset.
    bytes4 constant SEL_FEED_NOT_REGISTERED = 0x7966b144;

    FounderVestingV2 fv;

    function setUp() public {
        string memory envVal = vm.envOr("FOUNDER_VESTING_V2_ADDRESS", string(""));
        if (bytes(envVal).length == 0) {
            return;
        }
        fv = FounderVestingV2(vm.parseAddress(envVal));
    }

    function _skipIfNoAddr() internal {
        if (address(fv) == address(0)) {
            vm.skip(true);
        }
    }

    /// @notice 1) FounderVestingV2.oracle() points at LuminaOracleV2 SET A.
    function test_Wiring_OracleAddress_OnChainMatches_ExpectedLuminaOracleV2() public {
        _skipIfNoAddr();
        assertEq(address(fv.oracle()), LUMINA_ORACLE_V2_SET_A);
    }

    /// @notice 2) Oracle exposes getLatestPrice(bytes32) for ETH.
    ///         Acceptable outcomes (current Sepolia state — feeds not yet registered):
    ///           - call succeeds (founder may have registered feeds), OR
    ///           - call reverts with FeedNotRegistered (wiring OK, feed not configured).
    function test_Wiring_OracleHasGetLatestPriceFunction_ETH_NoRevert() public {
        _skipIfNoAddr();
        try ILuminaOracleV2View(address(fv.oracle())).getLatestPrice(bytes32("ETH")) returns (int256) {
            // Success — feed already registered. Wiring OK.
        } catch (bytes memory reason) {
            // Accept FeedNotRegistered (4-byte selector); fail on any other revert reason.
            require(reason.length >= 4, "unknown short revert");
            bytes4 sel;
            // solhint-disable-next-line no-inline-assembly
            assembly {
                sel := mload(add(reason, 32))
            }
            assertEq(sel, SEL_FEED_NOT_REGISTERED, "unexpected oracle revert reason");
        }
    }

    /// @notice 3) Same as test 2 but for BTC feed.
    function test_Wiring_OracleHasGetLatestPriceFunction_BTC_NoRevert() public {
        _skipIfNoAddr();
        try ILuminaOracleV2View(address(fv.oracle())).getLatestPrice(bytes32("BTC")) returns (int256) {
            // Success — feed already registered. Wiring OK.
        } catch (bytes memory reason) {
            require(reason.length >= 4, "unknown short revert");
            bytes4 sel;
            // solhint-disable-next-line no-inline-assembly
            assembly {
                sel := mload(add(reason, 32))
            }
            assertEq(sel, SEL_FEED_NOT_REGISTERED, "unexpected oracle revert reason");
        }
    }

    /// @notice 4) aavePool() points at the canonical Base Sepolia Aave V3 pool.
    function test_Wiring_AavePoolAddress_MatchesCanonicalBaseSepolia() public {
        _skipIfNoAddr();
        assertEq(fv.aavePool(), AAVE_POOL_SEPOLIA);
    }

    /// @notice 5) luminaToken() points at the active LuminaTokenV2 proxy.
    function test_Wiring_LuminaTokenAddress_MatchesActiveProxy() public {
        _skipIfNoAddr();
        assertEq(address(fv.luminaToken()), LUMINA_PROXY);
    }

    /// @notice 6) recipient() and owner() both resolve to the expected founder EOA.
    function test_Wiring_RecipientAndOwner_MatchExpectedFounderWallet() public {
        _skipIfNoAddr();
        assertEq(fv.recipient(), FOUNDER);
        assertEq(fv.owner(), FOUNDER);
    }
}
