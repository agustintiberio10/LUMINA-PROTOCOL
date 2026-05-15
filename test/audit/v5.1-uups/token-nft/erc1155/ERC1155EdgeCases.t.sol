// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ProxyDeployer} from "../../../../helpers/ProxyDeployer.sol";

import {ClaimBond} from "../../../../../src/bonds/ClaimBond.sol";
import {BondVault} from "../../../../../src/bonds/BondVault.sol";
import {LuminaTokenV2} from "../../../../../src/token/LuminaTokenV2.sol";
import {CapacityOracle} from "../../../../../src/oracles/CapacityOracle.sol";
import {CEXLiquidityReserve} from "../../../../../src/treasury/CEXLiquidityReserve.sol";
import {TreasuryVesting} from "../../../../../src/token/TreasuryVesting.sol";

import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

// ═══════════════════════════════════════════════════════════════════
//  MOCK RECEIVERS
// ═══════════════════════════════════════════════════════════════════

/// @notice Valid ERC-1155 receiver that returns the correct selector and
///         records the last callback data for assertion.
contract ValidReceiver is IERC1155Receiver {
    bytes public lastData;
    uint256 public lastId;
    uint256 public lastAmount;
    address public lastOperator;
    address public lastFrom;

    function onERC1155Received(address operator, address from, uint256 id, uint256 amount, bytes calldata data)
        external
        override
        returns (bytes4)
    {
        lastOperator = operator;
        lastFrom = from;
        lastId = id;
        lastAmount = amount;
        lastData = data;
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external override returns (bytes4) {
        lastOperator = operator;
        lastFrom = from;
        lastData = data;
        if (ids.length > 0) {
            lastId = ids[0];
            lastAmount = amounts[0];
        }
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || interfaceId == 0x01ffc9a7;
    }
}

/// @notice Plain contract that does NOT implement ERC1155Receiver. safeTransferFrom
///         should revert when sending to this.
contract NonReceiver {
    uint256 public x;

    function doSomething() external {
        x = 1;
    }
}

/// @notice Reentrant receiver attempts to call back into ClaimBond during the
///         ERC-1155 callback. Used to verify reentrancy / fix-#18 guards.
contract ReentrantReceiver is IERC1155Receiver {
    ClaimBond public claimBond;
    bool public reentryAttempted;

    constructor(address _claimBond) {
        claimBond = ClaimBond(_claimBond);
    }

    function onERC1155Received(address, address, uint256 id, uint256 amount, bytes calldata)
        external
        override
        returns (bytes4)
    {
        // Try to transfer back — this must revert because we are NOT a
        // whitelisted operator on ClaimBond.
        reentryAttempted = true;
        try claimBond.safeTransferFrom(address(this), address(0xdead), id, amount, "") {}
            catch {
            // absorbed — the outer transfer still succeeds
        }
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || interfaceId == 0x01ffc9a7;
    }
}

contract MockUSDC_Edge {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 6;

    function mint(address, uint256) external pure {}

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
}

/**
 * @title ERC1155EdgeCases
 * @notice Exhaustive edge-case audit of ClaimBond's ERC-1155 surface.
 *
 * Sections:
 *   A. Transfer targets (self, EOA, non-receiver contract, valid receiver, zero)
 *   B. Transfer amount edge cases (0, >balance, exact balance)
 *   C. Batch transfer edge cases (mismatch, empty, zero entries)
 *   D. balanceOf / balanceOfBatch edge cases
 *   E. Approval edge cases (self, revoke, partial)
 *   F. Mint edge cases (zero amount, valid/invalid receiver, invalid epoch)
 *   G. Burn edge cases (> balance, zero)
 *   H. URI edge cases (non-existent, max uint)
 *   I. supportsInterface positive and negative
 *   J. Receiver callback semantics (data passthrough, reentrancy)
 *
 * The fix-#18 restricted-transfer rule interacts with ERC-1155 spec:
 *   - Mint (from == 0) and burn (to == 0) unchanged.
 *   - Any non-zero → non-zero transfer needs an authorised operator. Tests
 *     whitelist `address(this)` as a generic operator so the test harness
 *     can drive transfers without deploying the marketplace.
 */
contract ERC1155EdgeCases is Test {
    ClaimBond claimBond;
    BondVault bondVault;
    LuminaTokenV2 lumina;
    CapacityOracle capacityOracle;
    CEXLiquidityReserve cexReserve;
    TreasuryVesting treasuryVesting;
    MockUSDC_Edge usdc;

    address deployer;
    address multisig = makeAddr("multisig");
    address founder = makeAddr("founder");
    address lbpDeposit = makeAddr("lbpDeposit");
    address holder = makeAddr("holder");
    address otherHolder = makeAddr("otherHolder");
    address buyer = makeAddr("buyer");

    uint256 constant EPOCH = 202912;

    // Canonical ERC-1155 interface selectors.
    bytes4 constant IERC165_ID = 0x01ffc9a7;
    bytes4 constant IERC1155_ID = 0xd9b67a26;
    bytes4 constant IERC1155_METADATA_URI_ID = 0x0e89341c;

    function setUp() public {
        vm.chainId(8453);
        deployer = address(this);

        usdc = new MockUSDC_Edge();
        claimBond = ProxyDeployer.deployClaimBond();

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
        // Whitelist the test contract as a generic authorised operator so
        // non-zero→non-zero transfers work in-place.
        claimBond.setAuthorizedOperator(address(this), true);
    }

    function _mint(address to, uint256 epochId, uint256 amount) internal {
        vm.prank(address(bondVault));
        claimBond.mint(to, epochId, amount);
    }

    // ═══════════════════════════════════════════════════════════
    // A. TRANSFER TARGETS
    // ═══════════════════════════════════════════════════════════

    function test_ERC1155_UUPS_Transfer_ToSelf_ViaOperator_NoBalanceChange() public {
        _mint(holder, EPOCH, 100);
        vm.prank(holder);
        claimBond.setApprovalForAll(address(this), true);
        // Self transfer via an authorised operator is a no-op on balance.
        claimBond.safeTransferFrom(holder, holder, EPOCH, 50, "");
        assertEq(claimBond.balanceOf(holder, EPOCH), 100);
    }

    function test_ERC1155_UUPS_Transfer_HolderToHolder_Direct_Blocked() public {
        _mint(holder, EPOCH, 100);
        vm.prank(holder);
        vm.expectRevert(bytes("ClaimBond: transfers only via authorized operators"));
        claimBond.safeTransferFrom(holder, otherHolder, EPOCH, 50, "");
    }

    function test_ERC1155_UUPS_Transfer_ToZeroAddress_Reverts_OZ() public {
        _mint(holder, EPOCH, 100);
        vm.prank(holder);
        claimBond.setApprovalForAll(address(this), true);
        // OZ ERC1155 reverts with ERC1155InvalidReceiver(address(0)).
        vm.expectRevert();
        claimBond.safeTransferFrom(holder, address(0), EPOCH, 50, "");
    }

    function test_ERC1155_UUPS_Transfer_ToEOA_SucceedsViaOperator() public {
        _mint(holder, EPOCH, 100);
        vm.prank(holder);
        claimBond.setApprovalForAll(address(this), true);
        claimBond.safeTransferFrom(holder, buyer, EPOCH, 30, "");
        assertEq(claimBond.balanceOf(holder, EPOCH), 70);
        assertEq(claimBond.balanceOf(buyer, EPOCH), 30);
    }

    function test_ERC1155_UUPS_Transfer_ToNonReceiverContract_Reverts() public {
        _mint(holder, EPOCH, 100);
        vm.prank(holder);
        claimBond.setApprovalForAll(address(this), true);
        NonReceiver dumb = new NonReceiver();
        vm.expectRevert();
        claimBond.safeTransferFrom(holder, address(dumb), EPOCH, 50, "");
    }

    function test_ERC1155_UUPS_Transfer_ToValidReceiver_Succeeds() public {
        _mint(holder, EPOCH, 100);
        vm.prank(holder);
        claimBond.setApprovalForAll(address(this), true);
        ValidReceiver receiver = new ValidReceiver();
        claimBond.safeTransferFrom(holder, address(receiver), EPOCH, 40, hex"cafe");
        assertEq(claimBond.balanceOf(address(receiver), EPOCH), 40);
    }

    // ═══════════════════════════════════════════════════════════
    // B. TRANSFER AMOUNT EDGE CASES
    // ═══════════════════════════════════════════════════════════

    function test_ERC1155_UUPS_Transfer_ZeroAmount_Allowed() public {
        _mint(holder, EPOCH, 100);
        vm.prank(holder);
        claimBond.setApprovalForAll(address(this), true);
        // Spec: a zero-amount transfer is valid and emits TransferSingle.
        claimBond.safeTransferFrom(holder, buyer, EPOCH, 0, "");
        assertEq(claimBond.balanceOf(holder, EPOCH), 100);
        assertEq(claimBond.balanceOf(buyer, EPOCH), 0);
    }

    function test_ERC1155_UUPS_Transfer_ExactBalance_DrainsHolder() public {
        _mint(holder, EPOCH, 77);
        vm.prank(holder);
        claimBond.setApprovalForAll(address(this), true);
        claimBond.safeTransferFrom(holder, buyer, EPOCH, 77, "");
        assertEq(claimBond.balanceOf(holder, EPOCH), 0);
        assertEq(claimBond.balanceOf(buyer, EPOCH), 77);
    }

    function test_ERC1155_UUPS_Transfer_MoreThanBalance_Reverts() public {
        _mint(holder, EPOCH, 100);
        vm.prank(holder);
        claimBond.setApprovalForAll(address(this), true);
        vm.expectRevert();
        claimBond.safeTransferFrom(holder, buyer, EPOCH, 150, "");
    }

    // ═══════════════════════════════════════════════════════════
    // C. BATCH TRANSFER EDGE CASES
    // ═══════════════════════════════════════════════════════════

    function test_ERC1155_UUPS_Batch_LengthMismatch_Reverts() public {
        _mint(holder, EPOCH, 100);
        vm.prank(holder);
        claimBond.setApprovalForAll(address(this), true);

        uint256[] memory ids = new uint256[](2);
        ids[0] = EPOCH;
        ids[1] = 203001;
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 10;
        amounts[1] = 5;
        amounts[2] = 2;

        vm.expectRevert();
        claimBond.safeBatchTransferFrom(holder, buyer, ids, amounts, "");
    }

    function test_ERC1155_UUPS_Batch_EmptyArrays_NoOp() public {
        _mint(holder, EPOCH, 100);
        vm.prank(holder);
        claimBond.setApprovalForAll(address(this), true);
        uint256[] memory ids = new uint256[](0);
        uint256[] memory amounts = new uint256[](0);
        // No-op: holder still has 100.
        claimBond.safeBatchTransferFrom(holder, buyer, ids, amounts, "");
        assertEq(claimBond.balanceOf(holder, EPOCH), 100);
        assertEq(claimBond.balanceOf(buyer, EPOCH), 0);
    }

    function test_ERC1155_UUPS_Batch_ZeroAmounts_NoBalanceChange() public {
        _mint(holder, EPOCH, 100);
        _mint(holder, 203001, 50);
        vm.prank(holder);
        claimBond.setApprovalForAll(address(this), true);

        uint256[] memory ids = new uint256[](2);
        ids[0] = EPOCH;
        ids[1] = 203001;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = 0;

        claimBond.safeBatchTransferFrom(holder, buyer, ids, amounts, "");
        assertEq(claimBond.balanceOf(holder, EPOCH), 100);
        assertEq(claimBond.balanceOf(holder, 203001), 50);
    }

    function test_ERC1155_UUPS_Batch_DirectHolderInitiated_Blocked() public {
        _mint(holder, EPOCH, 100);
        uint256[] memory ids = new uint256[](1);
        ids[0] = EPOCH;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10;
        vm.prank(holder);
        vm.expectRevert(bytes("ClaimBond: transfers only via authorized operators"));
        claimBond.safeBatchTransferFrom(holder, buyer, ids, amounts, "");
    }

    // ═══════════════════════════════════════════════════════════
    // D. balanceOf / balanceOfBatch EDGE CASES
    // ═══════════════════════════════════════════════════════════

    function test_ERC1155_UUPS_BalanceOf_UntouchedAccount_ReturnsZero() public {
        address noBonds = makeAddr("noBonds");
        assertEq(claimBond.balanceOf(noBonds, EPOCH), 0);
    }

    function test_ERC1155_UUPS_BalanceOfBatch_LengthMismatch_Reverts() public {
        address[] memory accs = new address[](2);
        uint256[] memory ids = new uint256[](3);
        vm.expectRevert();
        claimBond.balanceOfBatch(accs, ids);
    }

    function test_ERC1155_UUPS_BalanceOfBatch_EmptyArrays_ReturnsEmpty() public view {
        address[] memory accs = new address[](0);
        uint256[] memory ids = new uint256[](0);
        uint256[] memory bals = claimBond.balanceOfBatch(accs, ids);
        assertEq(bals.length, 0);
    }

    function test_ERC1155_UUPS_BalanceOfBatch_Works_MixedHoldings() public {
        _mint(holder, EPOCH, 7);
        _mint(otherHolder, 203001, 11);
        address[] memory accs = new address[](3);
        uint256[] memory ids = new uint256[](3);
        accs[0] = holder;
        accs[1] = otherHolder;
        accs[2] = buyer;
        ids[0] = EPOCH;
        ids[1] = 203001;
        ids[2] = EPOCH;
        uint256[] memory bals = claimBond.balanceOfBatch(accs, ids);
        assertEq(bals[0], 7);
        assertEq(bals[1], 11);
        assertEq(bals[2], 0);
    }

    // ═══════════════════════════════════════════════════════════
    // E. APPROVAL EDGE CASES
    // ═══════════════════════════════════════════════════════════

    function test_ERC1155_UUPS_SetApprovalForAll_ToSelf_Accepted_OZv5() public {
        // OZ v5 ERC-1155 only rejects `address(0)` as operator; self-approval
        // is silently accepted (stored in the operator-approval map). It is
        // harmless — the holder's own transfers don't consult the map.
        vm.prank(holder);
        claimBond.setApprovalForAll(holder, true);
        assertTrue(claimBond.isApprovedForAll(holder, holder));
    }

    function test_ERC1155_UUPS_SetApprovalForAll_ToZeroAddress_Reverts() public {
        // OZ v5 rejects address(0) as operator with ERC1155InvalidOperator.
        vm.prank(holder);
        vm.expectRevert();
        claimBond.setApprovalForAll(address(0), true);
    }

    function test_ERC1155_UUPS_RevokedApproval_BlocksSubsequentTransfers() public {
        _mint(holder, EPOCH, 100);
        vm.prank(holder);
        claimBond.setApprovalForAll(address(this), true);
        claimBond.safeTransferFrom(holder, buyer, EPOCH, 10, "");

        vm.prank(holder);
        claimBond.setApprovalForAll(address(this), false);

        vm.expectRevert();
        claimBond.safeTransferFrom(holder, buyer, EPOCH, 5, "");
    }

    function test_ERC1155_UUPS_HolderInitiated_WithoutApproval_StillBlockedByFix18() public {
        // Even though msg.sender == from normally skips approval in OZ, the
        // fix-#18 _update override blocks direct holder transfers regardless.
        _mint(holder, EPOCH, 100);
        vm.prank(holder);
        vm.expectRevert(bytes("ClaimBond: transfers only via authorized operators"));
        claimBond.safeTransferFrom(holder, buyer, EPOCH, 10, "");
    }

    // ═══════════════════════════════════════════════════════════
    // F. MINT EDGE CASES
    // ═══════════════════════════════════════════════════════════

    function test_ERC1155_UUPS_Mint_ZeroAmount_Reverts() public {
        // ClaimBond.mint requires usdAmount > 0.
        vm.prank(address(bondVault));
        vm.expectRevert(bytes("Zero amount"));
        claimBond.mint(holder, EPOCH, 0);
    }

    function test_ERC1155_UUPS_Mint_ToZeroAddress_Reverts() public {
        vm.prank(address(bondVault));
        vm.expectRevert(bytes("Zero address"));
        claimBond.mint(address(0), EPOCH, 100);
    }

    function test_ERC1155_UUPS_Mint_ToValidReceiverContract_Succeeds() public {
        ValidReceiver r = new ValidReceiver();
        vm.prank(address(bondVault));
        claimBond.mint(address(r), EPOCH, 42);
        assertEq(claimBond.balanceOf(address(r), EPOCH), 42);
    }

    function test_ERC1155_UUPS_Mint_ToNonReceiverContract_Reverts() public {
        NonReceiver dumb = new NonReceiver();
        vm.prank(address(bondVault));
        vm.expectRevert();
        claimBond.mint(address(dumb), EPOCH, 10);
    }

    function test_ERC1155_UUPS_Mint_InvalidEpoch_Reverts() public {
        vm.prank(address(bondVault));
        vm.expectRevert(bytes("Invalid epoch"));
        claimBond.mint(holder, 202500, 10);
    }

    // ═══════════════════════════════════════════════════════════
    // G. BURN EDGE CASES
    // ═══════════════════════════════════════════════════════════

    function test_ERC1155_UUPS_BurnMoreThanBalance_Reverts() public {
        _mint(holder, EPOCH, 50);
        vm.prank(address(bondVault));
        vm.expectRevert();
        claimBond.burn(holder, EPOCH, 100);
    }

    function test_ERC1155_UUPS_Burn_ExactBalance_Zeros() public {
        _mint(holder, EPOCH, 30);
        vm.prank(address(bondVault));
        claimBond.burn(holder, EPOCH, 30);
        assertEq(claimBond.balanceOf(holder, EPOCH), 0);
    }

    function test_ERC1155_UUPS_BurnByHolder_InsufficientBalance_Reverts() public {
        _mint(holder, EPOCH, 10);
        vm.prank(holder);
        vm.expectRevert(bytes("Insufficient balance"));
        claimBond.burnByHolder(holder, EPOCH, 20);
    }

    function test_ERC1155_UUPS_BurnByHolder_Authorised_Succeeds() public {
        _mint(holder, EPOCH, 10);
        vm.prank(holder);
        claimBond.setApprovalForAll(address(this), true);
        claimBond.burnByHolder(holder, EPOCH, 7);
        assertEq(claimBond.balanceOf(holder, EPOCH), 3);
    }

    // ═══════════════════════════════════════════════════════════
    // H. URI EDGE CASES
    // ═══════════════════════════════════════════════════════════

    function test_ERC1155_UUPS_URI_NonMintedEpoch_StillFormats() public view {
        // uri() is now view and pure-function of _baseURI + epoch. It does
        // not require the epoch to exist; returns a valid HTTPS string.
        string memory u = claimBond.uri(999999);
        assertGt(bytes(u).length, 0);
    }

    function test_ERC1155_UUPS_URI_MaxUint_DoesNotRevert() public view {
        // Our _epochToString handles uint256 max by taking mod-10 digits; the
        // resulting string is a 6-char ASCII suffix (not a meaningful date).
        string memory u = claimBond.uri(type(uint256).max);
        assertGt(bytes(u).length, 0);
    }

    function test_ERC1155_UUPS_URI_AfterBaseURIChange_Reflects() public {
        string memory oldUri = claimBond.uri(EPOCH);
        claimBond.setBaseURI("https://v2.example/bond/");
        string memory newUri = claimBond.uri(EPOCH);
        assertTrue(keccak256(bytes(oldUri)) != keccak256(bytes(newUri)));
    }

    // ═══════════════════════════════════════════════════════════
    // I. supportsInterface POSITIVE / NEGATIVE
    // ═══════════════════════════════════════════════════════════

    function test_ERC1155_UUPS_SupportsInterface_ERC165() public view {
        assertTrue(claimBond.supportsInterface(IERC165_ID));
    }

    function test_ERC1155_UUPS_SupportsInterface_ERC1155() public view {
        assertTrue(claimBond.supportsInterface(IERC1155_ID));
    }

    function test_ERC1155_UUPS_SupportsInterface_MetadataURI() public view {
        assertTrue(claimBond.supportsInterface(IERC1155_METADATA_URI_ID));
    }

    function test_ERC1155_UUPS_SupportsInterface_Bogus_IsFalse() public view {
        assertFalse(claimBond.supportsInterface(0xdeadbeef));
        assertFalse(claimBond.supportsInterface(0x00000000));
        assertFalse(claimBond.supportsInterface(0xffffffff));
    }

    // ═══════════════════════════════════════════════════════════
    // J. RECEIVER CALLBACK SEMANTICS
    // ═══════════════════════════════════════════════════════════

    function test_ERC1155_UUPS_Callback_Data_PassthroughOnSingle() public {
        _mint(holder, EPOCH, 100);
        vm.prank(holder);
        claimBond.setApprovalForAll(address(this), true);
        ValidReceiver r = new ValidReceiver();
        bytes memory custom = hex"deadbeef01";
        claimBond.safeTransferFrom(holder, address(r), EPOCH, 10, custom);
        assertEq(r.lastData(), custom);
        assertEq(r.lastId(), EPOCH);
        assertEq(r.lastAmount(), 10);
        assertEq(r.lastOperator(), address(this));
        assertEq(r.lastFrom(), holder);
    }

    function test_ERC1155_UUPS_Callback_Data_PassthroughOnBatch() public {
        _mint(holder, EPOCH, 100);
        _mint(holder, 203001, 50);
        vm.prank(holder);
        claimBond.setApprovalForAll(address(this), true);
        ValidReceiver r = new ValidReceiver();
        uint256[] memory ids = new uint256[](2);
        ids[0] = EPOCH;
        ids[1] = 203001;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 10;
        amounts[1] = 5;
        bytes memory custom = hex"cafebabe";
        claimBond.safeBatchTransferFrom(holder, address(r), ids, amounts, custom);
        assertEq(r.lastData(), custom);
    }

    function test_ERC1155_UUPS_Callback_Reentrancy_Blocked_ByFix18() public {
        _mint(holder, EPOCH, 100);
        vm.prank(holder);
        claimBond.setApprovalForAll(address(this), true);
        ReentrantReceiver r = new ReentrantReceiver(address(claimBond));
        // The outer transfer still succeeds because the attempted re-entry
        // inside the callback is caught (ReentrantReceiver is NOT a
        // whitelisted operator on ClaimBond).
        claimBond.safeTransferFrom(holder, address(r), EPOCH, 20, "");
        assertTrue(r.reentryAttempted());
        // Bond ended up at the receiver; no recursive drain.
        assertEq(claimBond.balanceOf(address(r), EPOCH), 20);
        assertEq(claimBond.balanceOf(holder, EPOCH), 80);
    }
}
