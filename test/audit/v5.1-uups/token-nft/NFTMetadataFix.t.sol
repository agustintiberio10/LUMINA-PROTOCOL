// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ProxyDeployer} from "../../../helpers/ProxyDeployer.sol";

import {ClaimBond} from "../../../../src/bonds/ClaimBond.sol";
import {BondVault} from "../../../../src/bonds/BondVault.sol";
import {LuminaTokenV2} from "../../../../src/token/LuminaTokenV2.sol";
import {CapacityOracle} from "../../../../src/oracles/CapacityOracle.sol";
import {SolvencyOracle} from "../../../../src/oracles/SolvencyOracle.sol";
import {CEXLiquidityReserve} from "../../../../src/treasury/CEXLiquidityReserve.sol";
import {TreasuryVesting} from "../../../../src/token/TreasuryVesting.sol";
import {LuminaBondMarketplace} from "../../../../src/marketplace/LuminaBondMarketplace.sol";
import {BuybackEngine} from "../../../../src/marketplace/BuybackEngine.sol";

contract MockUSDC_Fix {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
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

/**
 * @title NFTMetadataFix
 * @notice Verifies the FIX for audit V5.1 #18:
 *           - URI returns `https://api.lumina-org.com/metadata/bond/<epoch>.json`
 *           - setBaseURI admin function updates the base + emits events
 *           - name() == "LUMINA Bonds", symbol() == "LBOND"
 *           - Direct user-to-user transfers BLOCKED (revert)
 *           - Marketplace + BuybackEngine whitelist works
 *           - Mint and burn paths still work (must be unrestricted)
 *           - Storage layout preserved (verified out-of-band via
 *             `forge inspect ClaimBond storage-layout`)
 */
contract NFTMetadataFix is Test {
    ClaimBond claimBond;
    BondVault bondVault;
    LuminaTokenV2 lumina;
    CapacityOracle capacityOracle;
    SolvencyOracle solvencyOracle;
    CEXLiquidityReserve cexReserve;
    TreasuryVesting treasuryVesting;
    LuminaBondMarketplace marketplace;
    BuybackEngine buybackEngine;
    MockUSDC_Fix usdc;

    address deployer;
    address multisig = makeAddr("multisig");
    address founder = makeAddr("founder");
    address lbpDeposit = makeAddr("lbpDeposit");
    address holder = makeAddr("holder");
    address buyer = makeAddr("buyer");
    address attacker = makeAddr("attacker");

    string constant DEFAULT_BASE = "https://api.lumina-org.com/metadata/bond/";

    event BaseURIUpdated(string oldBaseURI, string newBaseURI);
    event OperatorAuthorized(address indexed operator, bool authorized);

    function setUp() public {
        vm.chainId(8453);
        deployer = address(this);

        usdc = new MockUSDC_Fix();
        claimBond = ProxyDeployer.deployClaimBond();

        // Predict lumina address: capacityOracle (impl+proxy=2) + bondVault (2)
        // + cexReserve (2) + treasuryVesting (2) + lumina_impl (1) → +9.
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

        solvencyOracle = ProxyDeployer.deploySolvencyOracle(address(bondVault), address(capacityOracle), multisig);

        marketplace = ProxyDeployer.deployLuminaBondMarketplace(
            address(claimBond), address(usdc), makeAddr("twapBurner"), multisig
        );
        buybackEngine = ProxyDeployer.deployBuybackEngine(
            address(claimBond),
            address(bondVault),
            address(solvencyOracle),
            address(capacityOracle),
            address(marketplace),
            address(usdc),
            multisig
        );

        // Whitelist the two protocol-owned operators (deployer = owner here).
        claimBond.setAuthorizedOperator(address(marketplace), true);
        claimBond.setAuthorizedOperator(address(buybackEngine), true);
    }

    // ─── Helpers ───
    function _issueBonds(address to, uint256 epochId, uint256 usdAmount) internal {
        vm.prank(address(bondVault));
        claimBond.mint(to, epochId, usdAmount);
    }

    // ═══════════════════════════════════════════════════════════
    // A. URI HTTPS FORMAT
    // ═══════════════════════════════════════════════════════════

    function test_Fix_URI_DefaultBase_Exact() public view {
        assertEq(claimBond.uri(202912), "https://api.lumina-org.com/metadata/bond/202912.json");
    }

    function test_Fix_URI_StartsWithHTTPS() public view {
        string memory u = claimBond.uri(202912);
        bytes memory b = bytes(u);
        bytes memory prefix = new bytes(8);
        for (uint256 i = 0; i < 8; i++) {
            prefix[i] = b[i];
        }
        assertEq(string(prefix), "https://");
    }

    function test_Fix_URI_EndsWithJSON() public view {
        string memory u = claimBond.uri(202912);
        bytes memory b = bytes(u);
        bytes memory tail = new bytes(5);
        for (uint256 i = 0; i < 5; i++) {
            tail[i] = b[b.length - 5 + i];
        }
        assertEq(string(tail), ".json");
    }

    function test_Fix_URI_DifferentEpoch_DifferentURI() public view {
        assertTrue(keccak256(bytes(claimBond.uri(202912))) != keccak256(bytes(claimBond.uri(203001))));
    }

    // ═══════════════════════════════════════════════════════════
    // B. setBaseURI ADMIN
    // ═══════════════════════════════════════════════════════════

    function test_Fix_SetBaseURI_AdminWorks() public {
        claimBond.setBaseURI("https://new.lumina.com/v2/bond/");
        assertEq(claimBond.uri(202912), "https://new.lumina.com/v2/bond/202912.json");
    }

    function test_Fix_SetBaseURI_NonOwner_Reverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        claimBond.setBaseURI("https://evil.com/");
    }

    function test_Fix_SetBaseURI_EmitsBaseURIUpdated() public {
        vm.expectEmit(false, false, false, true);
        emit BaseURIUpdated(DEFAULT_BASE, "https://x.com/");
        claimBond.setBaseURI("https://x.com/");
    }

    function test_Fix_SetBaseURI_CanBeCalledMultipleTimes() public {
        claimBond.setBaseURI("https://v1.x/");
        claimBond.setBaseURI("https://v2.x/");
        assertEq(claimBond.uri(202912), "https://v2.x/202912.json");
    }

    // ═══════════════════════════════════════════════════════════
    // C. name() / symbol()
    // ═══════════════════════════════════════════════════════════

    function test_Fix_Name_Exact() public view {
        assertEq(claimBond.name(), "LUMINA Bonds");
    }

    function test_Fix_Symbol_Exact() public view {
        assertEq(claimBond.symbol(), "LBOND");
    }

    // ═══════════════════════════════════════════════════════════
    // D. RESTRICTED TRANSFERS — mint / burn unaffected
    // ═══════════════════════════════════════════════════════════

    function test_Fix_Mint_Allowed_FromBondVault() public {
        _issueBonds(holder, 202912, 100);
        assertEq(claimBond.balanceOf(holder, 202912), 100);
    }

    function test_Fix_Burn_Allowed_FromBondVault() public {
        _issueBonds(holder, 202912, 100);
        vm.prank(address(bondVault));
        claimBond.burn(holder, 202912, 40);
        assertEq(claimBond.balanceOf(holder, 202912), 60);
    }

    function test_Fix_BurnByHolder_Allowed_ForRedemption() public {
        // burnByHolder ends in _burn → to == 0 → unrestricted.
        _issueBonds(holder, 202912, 100);
        vm.prank(holder);
        claimBond.burnByHolder(holder, 202912, 30);
        assertEq(claimBond.balanceOf(holder, 202912), 70);
    }

    // ═══════════════════════════════════════════════════════════
    // E. RESTRICTED TRANSFERS — direct user-to-user BLOCKED
    // ═══════════════════════════════════════════════════════════

    function test_Fix_DirectTransfer_Blocked_SafeTransferFrom() public {
        _issueBonds(holder, 202912, 100);
        vm.prank(holder);
        vm.expectRevert(bytes("ClaimBond: transfers only via authorized operators"));
        claimBond.safeTransferFrom(holder, buyer, 202912, 50, "");
    }

    function test_Fix_DirectBatchTransfer_Blocked() public {
        _issueBonds(holder, 202912, 100);
        _issueBonds(holder, 203001, 50);

        uint256[] memory ids = new uint256[](2);
        ids[0] = 202912;
        ids[1] = 203001;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 20;
        amounts[1] = 10;

        vm.prank(holder);
        vm.expectRevert(bytes("ClaimBond: transfers only via authorized operators"));
        claimBond.safeBatchTransferFrom(holder, buyer, ids, amounts, "");
    }

    function test_Fix_TransferViaUnauthorizedOperator_Blocked() public {
        _issueBonds(holder, 202912, 100);

        address rogueOp = makeAddr("rogueOp");
        vm.prank(holder);
        claimBond.setApprovalForAll(rogueOp, true);

        vm.prank(rogueOp);
        vm.expectRevert(bytes("ClaimBond: transfers only via authorized operators"));
        claimBond.safeTransferFrom(holder, buyer, 202912, 50, "");
    }

    // ═══════════════════════════════════════════════════════════
    // F. RESTRICTED TRANSFERS — Marketplace allowed
    // ═══════════════════════════════════════════════════════════

    function test_Fix_TransferViaMarketplace_Allowed_OnList() public {
        _issueBonds(holder, 202912, 100);
        vm.prank(holder);
        claimBond.setApprovalForAll(address(marketplace), true);
        vm.prank(holder);
        uint256 listingId = marketplace.list(202912, 50, 20e6);
        // Marketplace now custody-holds the 50 listed.
        assertEq(claimBond.balanceOf(holder, 202912), 50);
        assertEq(claimBond.balanceOf(address(marketplace), 202912), 50);
        listingId; // silence
    }

    function test_Fix_TransferViaMarketplace_Allowed_OnCancel() public {
        _issueBonds(holder, 202912, 100);
        vm.startPrank(holder);
        claimBond.setApprovalForAll(address(marketplace), true);
        uint256 listingId = marketplace.list(202912, 50, 20e6);
        marketplace.cancel(listingId);
        vm.stopPrank();
        // Bonds returned to seller.
        assertEq(claimBond.balanceOf(holder, 202912), 100);
        assertEq(claimBond.balanceOf(address(marketplace), 202912), 0);
    }

    function test_Fix_TransferViaMarketplace_Allowed_OnExecuteBuy() public {
        _issueBonds(holder, 202912, 100);
        vm.prank(holder);
        claimBond.setApprovalForAll(address(marketplace), true);
        vm.prank(holder);
        uint256 listingId = marketplace.list(202912, 50, 20e6);

        // Fund buyer + approve marketplace for fee+price.
        usdc.mint(buyer, 25e6);
        vm.prank(buyer);
        usdc.approve(address(marketplace), 25e6);

        vm.prank(buyer);
        marketplace.executeBuy(listingId);

        assertEq(claimBond.balanceOf(buyer, 202912), 50);
        assertEq(claimBond.balanceOf(address(marketplace), 202912), 0);
    }

    // ═══════════════════════════════════════════════════════════
    // G. setAuthorizedOperator ADMIN
    // ═══════════════════════════════════════════════════════════

    function test_Fix_SetAuthorizedOperator_FlipsState() public {
        address op = makeAddr("newOp");
        assertFalse(claimBond.authorizedOperators(op));
        claimBond.setAuthorizedOperator(op, true);
        assertTrue(claimBond.authorizedOperators(op));
        claimBond.setAuthorizedOperator(op, false);
        assertFalse(claimBond.authorizedOperators(op));
    }

    function test_Fix_SetAuthorizedOperator_NonOwner_Reverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        claimBond.setAuthorizedOperator(address(0xdead), true);
    }

    function test_Fix_SetAuthorizedOperator_ZeroAddress_Reverts() public {
        vm.expectRevert(bytes("ClaimBond: zero address"));
        claimBond.setAuthorizedOperator(address(0), true);
    }

    function test_Fix_SetAuthorizedOperator_EmitsEvent() public {
        address op = makeAddr("opForEvent");
        vm.expectEmit(true, false, false, true);
        emit OperatorAuthorized(op, true);
        claimBond.setAuthorizedOperator(op, true);
    }

    function test_Fix_RevokedMarketplace_TransfersBlocked() public {
        _issueBonds(holder, 202912, 100);
        // Revoke marketplace's authorization.
        claimBond.setAuthorizedOperator(address(marketplace), false);

        vm.prank(holder);
        claimBond.setApprovalForAll(address(marketplace), true);

        vm.prank(holder);
        vm.expectRevert(bytes("ClaimBond: transfers only via authorized operators"));
        marketplace.list(202912, 50, 20e6);
    }

    // ═══════════════════════════════════════════════════════════
    // H. ERC-1155 INTERFACE STILL COMPLIANT
    // ═══════════════════════════════════════════════════════════

    function test_Fix_SupportsInterface_ERC1155_StillTrue() public view {
        assertTrue(claimBond.supportsInterface(0xd9b67a26)); // ERC1155
        assertTrue(claimBond.supportsInterface(0x0e89341c)); // ERC1155MetadataURI
        assertTrue(claimBond.supportsInterface(0x01ffc9a7)); // ERC165
    }
}
