// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ProxyDeployer} from "../../../helpers/ProxyDeployer.sol";

import {ClaimBond} from "../../../../src/bonds/ClaimBond.sol";
import {BondVault} from "../../../../src/bonds/BondVault.sol";
import {LuminaTokenV2} from "../../../../src/token/LuminaTokenV2.sol";
import {CapacityOracle} from "../../../../src/oracles/CapacityOracle.sol";
import {CEXLiquidityReserve} from "../../../../src/treasury/CEXLiquidityReserve.sol";
import {TreasuryVesting} from "../../../../src/token/TreasuryVesting.sol";

contract MockUSDC_NFT {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 6;

    function mint(address, uint256) external pure {}

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
}

/**
 * @title NFTMetadata
 * @notice Audits ClaimBond's ERC-1155 metadata implementation for V5.1.
 *
 * What's verified to work:
 *   - ERC-1155 / Metadata-URI / ERC-165 interface support
 *   - URI is non-empty and unique per epoch
 *   - URI is consistent across calls (deterministic)
 *   - URI is consistent across holders of the same epoch
 *   - URI persists after transfer (correct ERC-1155 semantics)
 *   - balanceOf / balanceOfBatch return correct counts
 *   - totalSupply per epoch tracked via ERC1155Supply
 *   - Mint emits the correct events; URI is deterministic so no URI event
 *
 * What this audit FLAGS as gaps for production (see REPORT §4):
 *   - URI scheme is `lumina://claimbond/<epoch>`, not HTTPS/IPFS — not
 *     resolvable by OpenSea / MetaMask / Magic Eden as-is
 *   - No `setBaseURI` admin path; the URI function is `pure` so the format
 *     can only be changed via UUPS upgrade
 *   - No on-chain JSON metadata (no name/description/image/attributes)
 */
contract NFTMetadata is Test {
    ClaimBond claimBond;
    BondVault bondVault;
    LuminaTokenV2 lumina;
    CapacityOracle capacityOracle;
    CEXLiquidityReserve cexReserve;
    TreasuryVesting treasuryVesting;

    address deployer;
    address multisig = makeAddr("multisig");
    address founder = makeAddr("founder");
    address lbpDeposit = makeAddr("lbpDeposit");
    address holderA = makeAddr("holderA");
    address holderB = makeAddr("holderB");

    // Standard interface selectors (per EIPs).
    bytes4 constant INTERFACE_ERC165 = 0x01ffc9a7;
    bytes4 constant INTERFACE_ERC1155 = 0xd9b67a26;
    bytes4 constant INTERFACE_ERC1155_METADATA_URI = 0x0e89341c;

    // Standard ERC-1155 events we re-declare to use vm.expectEmit.
    event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value);

    function setUp() public {
        deployer = address(this);

        MockUSDC_NFT usdc = new MockUSDC_NFT();

        claimBond = ProxyDeployer.deployClaimBond();

        // Predict lumina address. Same offset as the canonical E2E deploy:
        // capacityOracle (impl+proxy=2) + bondVault (2) + cexReserve (2)
        // + treasuryVesting (2) + lumina_impl (1) → lumina_proxy at +9.
        uint64 n = vm.getNonce(deployer);
        address predictedLumina = vm.computeCreateAddress(deployer, n + 9);

        capacityOracle = ProxyDeployer.deployCapacityOracle(address(0), predictedLumina, address(usdc), 0.036e18);
        bondVault =
            ProxyDeployer.deployBondVault(predictedLumina, address(claimBond), address(capacityOracle), address(0));
        cexReserve = ProxyDeployer.deployCEXLiquidityReserve(predictedLumina, multisig);
        treasuryVesting = ProxyDeployer.deployTreasuryVesting(predictedLumina);

        lumina = ProxyDeployer.deployLuminaTokenV2(
            address(bondVault), address(cexReserve), founder, lbpDeposit, address(treasuryVesting)
        );
        require(address(lumina) == predictedLumina, "lumina addr");

        claimBond.setBondVault(address(bondVault));
    }

    // ─────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────

    function _issueBond(address to, uint256 epochId, uint256 usdAmount) internal {
        vm.prank(address(bondVault));
        claimBond.mint(to, epochId, usdAmount);
    }

    // ═══════════════════════════════════════════════════════════
    // A. URI FORMAT
    // ═══════════════════════════════════════════════════════════

    function test_NFT_UUPS_URI_NonEmpty() public view {
        string memory u = claimBond.uri(202912);
        assertGt(bytes(u).length, 0, "URI must be non-empty");
    }

    function test_NFT_UUPS_URI_ContainsEpochId() public view {
        // [FIX-#18] URI is now `<base><epoch>.json` — epoch sits in the middle,
        // followed by the `.json` extension. Verify the 6-digit epoch appears
        // directly before `.json`.
        string memory u = claimBond.uri(202912);
        bytes memory b = bytes(u);
        bytes memory tail = new bytes(11); // "202912.json" = 11 chars
        for (uint256 i = 0; i < 11; i++) {
            tail[i] = b[b.length - 11 + i];
        }
        assertEq(string(tail), "202912.json", "URI must end with <epoch>.json");
    }

    function test_NFT_UUPS_URI_DifferentEpochs_DifferentURIs() public view {
        string memory a = claimBond.uri(202912);
        string memory b = claimBond.uri(203001);
        assertTrue(keccak256(bytes(a)) != keccak256(bytes(b)), "different epochs must have different URIs");
    }

    function test_NFT_UUPS_URI_Deterministic() public view {
        // Same input → same output across calls.
        string memory a = claimBond.uri(202912);
        string memory b = claimBond.uri(202912);
        assertEq(a, b);
    }

    function test_NFT_UUPS_URI_FarFutureEpoch_StillFormatted() public view {
        // 209912 is at the upper bound of the valid range.
        string memory u = claimBond.uri(209912);
        assertGt(bytes(u).length, 0);
        bytes memory b = bytes(u);
        // [FIX-#18] `<epoch>.json` at the tail.
        bytes memory tail = new bytes(11);
        for (uint256 i = 0; i < 11; i++) {
            tail[i] = b[b.length - 11 + i];
        }
        assertEq(string(tail), "209912.json");
    }

    function test_NFT_UUPS_URI_HTTPS_Prefix() public view {
        // [FIX-#18] Scheme changed from `lumina://claimbond/<epoch>` to
        // `https://api.lumina-org.com/metadata/bond/<epoch>.json`. This
        // asserts the new HTTPS prefix.
        string memory u = claimBond.uri(202912);
        bytes memory b = bytes(u);
        bytes memory prefix = new bytes(8);
        for (uint256 i = 0; i < 8; i++) {
            prefix[i] = b[i];
        }
        assertEq(string(prefix), "https://", "post-fix scheme is https://");
    }

    // ═══════════════════════════════════════════════════════════
    // B. ERC-1155 / Metadata-URI / ERC-165 INTERFACE COMPLIANCE
    // ═══════════════════════════════════════════════════════════

    function test_NFT_UUPS_ERC165_Supported() public view {
        assertTrue(claimBond.supportsInterface(INTERFACE_ERC165));
    }

    function test_NFT_UUPS_ERC1155_Supported() public view {
        assertTrue(claimBond.supportsInterface(INTERFACE_ERC1155));
    }

    function test_NFT_UUPS_ERC1155MetadataURI_Supported() public view {
        assertTrue(claimBond.supportsInterface(INTERFACE_ERC1155_METADATA_URI));
    }

    function test_NFT_UUPS_UnknownInterface_NotSupported() public view {
        assertFalse(claimBond.supportsInterface(0xdeadbeef));
    }

    // ═══════════════════════════════════════════════════════════
    // C. NO setBaseURI EXISTS — pure metadata
    // ═══════════════════════════════════════════════════════════

    function test_NFT_UUPS_NoBaseURISetter_Documented() public pure {
        // Documenting the absence of a `setBaseURI` admin path. The URI
        // function is `pure`, so the format can only change via UUPS
        // upgrade. Flagged in REPORT.md §4.2.
        bytes4 setBaseURISelector = bytes4(keccak256("setBaseURI(string)"));
        // No way to call it because the function doesn't exist; we just
        // document the intent here.
        setBaseURISelector;
        assertTrue(true);
    }

    // ═══════════════════════════════════════════════════════════
    // D. METADATA CONSISTENCY ACROSS HOLDERS / TRANSFERS / MINTS
    // ═══════════════════════════════════════════════════════════

    function test_NFT_UUPS_SameEpoch_SameURI_AfterMintToTwoHolders() public {
        _issueBond(holderA, 202912, 100);
        _issueBond(holderB, 202912, 50);
        // ERC-1155 metadata is per-id, not per-holder.
        string memory uA = claimBond.uri(202912);
        string memory uB = claimBond.uri(202912);
        assertEq(uA, uB);
    }

    function test_NFT_UUPS_Transfer_PreservesURI() public {
        _issueBond(holderA, 202912, 100);
        string memory before = claimBond.uri(202912);

        // [FIX-#18] Direct user-to-user transfers are now blocked. Whitelist
        // the test contract as an authorised operator so this test still
        // exercises the "transfer doesn't mutate URI" property.
        claimBond.setAuthorizedOperator(address(this), true);
        vm.prank(holderA);
        claimBond.setApprovalForAll(address(this), true);
        claimBond.safeTransferFrom(holderA, holderB, 202912, 50, "");

        string memory after_ = claimBond.uri(202912);
        assertEq(before, after_, "transfer must not affect URI");
    }

    function test_NFT_UUPS_MintEmitsTransferSingleEvent() public {
        // ERC-1155 standard: minting emits TransferSingle(operator, 0x0,
        // to, id, value). URI is determined by uri() and the standard
        // doesn't require a per-mint URI event — only when the URI itself
        // changes (which it can't in the current implementation).
        vm.expectEmit(true, true, true, true, address(claimBond));
        emit TransferSingle(address(bondVault), address(0), holderA, 202912, 100);
        _issueBond(holderA, 202912, 100);
    }

    // ═══════════════════════════════════════════════════════════
    // E. BALANCE / SUPPLY QUERIES
    // ═══════════════════════════════════════════════════════════

    function test_NFT_UUPS_BalanceOf_ReturnsCorrectAmount() public {
        _issueBond(holderA, 202912, 100);
        assertEq(claimBond.balanceOf(holderA, 202912), 100);
    }

    function test_NFT_UUPS_BalanceOfBatch_AcrossEpochs() public {
        _issueBond(holderA, 202912, 100);
        _issueBond(holderA, 203001, 50);

        address[] memory accounts = new address[](2);
        uint256[] memory ids = new uint256[](2);
        accounts[0] = holderA;
        accounts[1] = holderA;
        ids[0] = 202912;
        ids[1] = 203001;

        uint256[] memory bals = claimBond.balanceOfBatch(accounts, ids);
        assertEq(bals[0], 100);
        assertEq(bals[1], 50);
    }

    function test_NFT_UUPS_TotalSupply_PerEpoch() public {
        _issueBond(holderA, 202912, 100);
        _issueBond(holderB, 202912, 50);
        assertEq(claimBond.totalSupply(202912), 150);
    }

    function test_NFT_UUPS_TotalSupply_DropsOnBurn() public {
        _issueBond(holderA, 202912, 100);
        vm.prank(address(bondVault));
        claimBond.burn(holderA, 202912, 40);
        assertEq(claimBond.totalSupply(202912), 60);
    }

    // ═══════════════════════════════════════════════════════════
    // F. EPOCH METADATA (face value, maturity, getEpochInfo)
    // ═══════════════════════════════════════════════════════════

    function test_NFT_UUPS_FaceValue_IsOneDollar() public {
        _issueBond(holderA, 202912, 1);
        assertEq(claimBond.getFaceValue(202912), 1e18, "1 token = $1 (18-dec)");
    }

    function test_NFT_UUPS_HolderFaceValue_ScalesWithBalance() public {
        _issueBond(holderA, 202912, 250);
        assertEq(claimBond.getHolderFaceValue(holderA, 202912), 250e18);
    }

    function test_NFT_UUPS_MaturityDate_StoredCorrectly() public {
        _issueBond(holderA, 202612, 1); // Dec 2026
        // Year 2026, month 12: BASE_TS + (0*12 + 11) * 2629746
        uint256 expected = 1_767_225_600 + (11 * 2_629_746);
        assertEq(claimBond.maturityDate(202612), expected);
    }

    function test_NFT_UUPS_GetEpochInfo_AfterMint() public {
        _issueBond(holderA, 202912, 100);
        (bool exists, uint256 maturity, uint256 totalSupply_, bool matured) = claimBond.getEpochInfo(202912);
        assertTrue(exists);
        assertGt(maturity, 0);
        assertEq(totalSupply_, 100);
        // 2029-12 is far future so not matured at deploy time.
        if (block.timestamp < maturity) assertFalse(matured);
    }

    function test_NFT_UUPS_GetEpochInfo_NonExistent_ReturnsFalse() public view {
        (bool exists, uint256 maturity, uint256 totalSupply_, bool matured) = claimBond.getEpochInfo(202612);
        assertFalse(exists);
        assertEq(maturity, 0);
        assertEq(totalSupply_, 0);
        assertFalse(matured);
    }

    // ═══════════════════════════════════════════════════════════
    // G. INVALID-EPOCH MINTING
    // ═══════════════════════════════════════════════════════════

    function test_NFT_UUPS_Mint_BelowEpochRange_Reverts() public {
        vm.prank(address(bondVault));
        vm.expectRevert(bytes("Invalid epoch"));
        claimBond.mint(holderA, 202500, 1);
    }

    function test_NFT_UUPS_Mint_AboveEpochRange_Reverts() public {
        vm.prank(address(bondVault));
        vm.expectRevert(bytes("Invalid epoch"));
        claimBond.mint(holderA, 210101, 1);
    }

    function test_NFT_UUPS_Mint_InvalidMonth_Reverts() public {
        // Month 13 — invalid.
        vm.prank(address(bondVault));
        vm.expectRevert(bytes("Invalid month"));
        claimBond.mint(holderA, 202613, 1);
    }

    function test_NFT_UUPS_NonBondVault_Mint_Reverts() public {
        vm.expectRevert(bytes("Only BondVault"));
        claimBond.mint(holderA, 202912, 1);
    }
}
