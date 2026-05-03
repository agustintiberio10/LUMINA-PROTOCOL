// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BuybackEngine} from "../../src/marketplace/BuybackEngine.sol";
import {MockSolvencyOracle} from "../mocks/MockSolvencyOracle.sol";
import {MockCapacityOracleV5} from "../mocks/MockCapacityOracleV5.sol";
import {MockClaimBondV5} from "../mocks/MockClaimBondV5.sol";
import {MockBondVaultV5} from "../mocks/MockBondVaultV5.sol";
import {MockMarketplace} from "../mocks/MockMarketplace.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract MockUSDCM10 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

/// @title BuybackCommitRevealTest
/// @notice Audit V5.1 fix M-10 — commit-reveal scheme on BuybackEngine to
///         close the MEV / front-running vector that the legacy 1-step
///         `executeOffer(listingId)` exposed.
contract BuybackCommitRevealTest is Test {
    using ProxyDeployer for *;

    // Mirrored events for vm.expectEmit
    event BuybackCommitted(bytes32 indexed commitment, uint256 blockNumber, address indexed operator);
    event BuybackRevealed(uint256 indexed listingId, uint256 actualPrice, address indexed operator);
    event BuybackCancelled(bytes32 indexed commitment, address indexed admin, string reason);

    BuybackEngine engine;
    MockClaimBondV5 claimBond;
    MockBondVaultV5 bondVault;
    MockSolvencyOracle solvencyOracle;
    MockCapacityOracleV5 capacityOracle;
    MockMarketplace marketplace;
    MockUSDCM10 usdc;

    address multisig = makeAddr("multisig");
    address operator = makeAddr("operator");
    address attacker = makeAddr("attacker");

    uint256 constant LISTING_ID = 42;
    uint256 constant LISTING_PRICE = 50e6; // $50 — well below 95% face-value cap ($95)
    uint256 constant LISTING_AMOUNT = 100;
    uint256 constant FACE_VALUE = 1e18; // 1 USD per bond, mock-fixed
    bytes32 constant SALT = bytes32(uint256(0xCAFE));

    function setUp() public {
        claimBond = new MockClaimBondV5();
        usdc = new MockUSDCM10();
        bondVault = new MockBondVaultV5(address(0x1));
        solvencyOracle = new MockSolvencyOracle();
        capacityOracle = new MockCapacityOracleV5();
        capacityOracle.setPrice(0.036e18);
        marketplace = new MockMarketplace();

        engine = ProxyDeployer.deployBuybackEngine(
            address(claimBond),
            address(bondVault),
            address(solvencyOracle),
            address(capacityOracle),
            address(marketplace),
            address(usdc),
            multisig
        );

        // Seed engine USDC budget; configure daily buyback.
        usdc.mint(address(engine), 100_000e6);
        vm.prank(multisig);
        engine.setDailyBuyback(100_000e6, 95, 24); // 95% of face value, 24h

        // Default listing (mock claimBond returns FACE_VALUE = 1e18 for any epoch).
        marketplace.setListing(LISTING_ID, makeAddr("seller"), 1, LISTING_AMOUNT, LISTING_PRICE, true);

        // Pre-mint bonds to the engine so `_executeDoubleBurn` -> `burnByHolder`
        // succeeds. The mock marketplace doesn't actually transfer bonds on
        // `executeBuy`, so the engine needs them seeded directly.
        claimBond.mint(address(engine), 1, LISTING_AMOUNT * 100);

        // Seed the mock BondVault with enough committed obligations to
        // satisfy `decreaseObligations(faceValueUSD)`. faceValueUSD per
        // reveal = FACE_VALUE * LISTING_AMOUNT = 1e18 * 100 = 1e20.
        // Generous headroom for any test that might reveal multiple times.
        bondVault.setTotalCommittedUSD(FACE_VALUE * LISTING_AMOUNT * 1000);
        bondVault.setLuminaBalance(70_000_000 ether);

        // Grant operator role separately so we can prank as a non-multisig
        // operator and exercise the role-gating path explicitly. Read the
        // role constant FIRST (otherwise the vm.prank is consumed by the
        // BUYBACK_OPERATOR_ROLE() call and the subsequent grantRole runs
        // as address(this) — which lacks DEFAULT_ADMIN_ROLE).
        bytes32 operatorRole = engine.BUYBACK_OPERATOR_ROLE();
        vm.prank(multisig);
        engine.grantRole(operatorRole, operator);
    }

    // ═══════ Helpers ═══════

    function _commitmentOf(uint256 listingId, uint256 maxPrice, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(listingId, maxPrice, salt));
    }

    function _commit(bytes32 commitment, address caller) internal {
        vm.prank(caller);
        engine.commitBuyback(commitment);
    }

    function _rollMinDelay() internal {
        vm.roll(block.number + engine.MIN_REVEAL_DELAY_BLOCKS());
    }

    // ═══════ CRITICAL — happy path ═══════

    function test_CommitThenRevealAfterMinDelay() public {
        bytes32 commitment = _commitmentOf(LISTING_ID, LISTING_PRICE, SALT);
        _commit(commitment, operator);
        _rollMinDelay();

        // Match the listingId + operator topics; ignore the actualPrice
        // value (the mock marketplace doesn't clear it on executeBuy).
        vm.expectEmit(true, false, true, false);
        emit BuybackRevealed(LISTING_ID, 0, operator);
        vm.prank(operator);
        engine.revealAndExecute(LISTING_ID, LISTING_PRICE, SALT);

        // Commitment burned post-reveal.
        assertEq(engine.commitmentBlock(commitment), 0);
    }

    // ═══════ CRITICAL — anti front-run ═══════

    function test_RevealBeforeMinDelayReverts() public {
        bytes32 commitment = _commitmentOf(LISTING_ID, LISTING_PRICE, SALT);
        _commit(commitment, operator);
        // Don't roll forward — same block as commit.
        uint256 readyAt = block.number + engine.MIN_REVEAL_DELAY_BLOCKS();
        vm.expectRevert(
            abi.encodeWithSelector(BuybackEngine.RevealTooEarly.selector, block.number, readyAt)
        );
        vm.prank(operator);
        engine.revealAndExecute(LISTING_ID, LISTING_PRICE, SALT);
    }

    function test_RevealAtExactlyMinDelayWorks() public {
        bytes32 commitment = _commitmentOf(LISTING_ID, LISTING_PRICE, SALT);
        _commit(commitment, operator);
        // Advance EXACTLY MIN_REVEAL_DELAY_BLOCKS — boundary case must succeed.
        vm.roll(engine.commitmentBlock(commitment) + engine.MIN_REVEAL_DELAY_BLOCKS());
        vm.prank(operator);
        engine.revealAndExecute(LISTING_ID, LISTING_PRICE, SALT);
    }

    // ═══════ CRITICAL — commitment expiry ═══════

    function test_RevealAfterMaxWindowReverts() public {
        bytes32 commitment = _commitmentOf(LISTING_ID, LISTING_PRICE, SALT);
        _commit(commitment, operator);
        uint256 committedAt = engine.commitmentBlock(commitment);
        // Advance PAST the window.
        vm.roll(committedAt + engine.MAX_REVEAL_WINDOW_BLOCKS() + 1);

        uint256 expiresAt = committedAt + engine.MAX_REVEAL_WINDOW_BLOCKS();
        vm.expectRevert(
            abi.encodeWithSelector(BuybackEngine.RevealTooLate.selector, block.number, expiresAt)
        );
        vm.prank(operator);
        engine.revealAndExecute(LISTING_ID, LISTING_PRICE, SALT);
    }

    function test_RevealAtExactlyMaxWindowWorks() public {
        bytes32 commitment = _commitmentOf(LISTING_ID, LISTING_PRICE, SALT);
        _commit(commitment, operator);
        // Boundary: exactly at MAX_REVEAL_WINDOW_BLOCKS — must succeed (<=).
        vm.roll(engine.commitmentBlock(commitment) + engine.MAX_REVEAL_WINDOW_BLOCKS());
        vm.prank(operator);
        engine.revealAndExecute(LISTING_ID, LISTING_PRICE, SALT);
    }

    // ═══════ CRITICAL — commitment integrity ═══════

    function test_CommitmentMismatchReverts() public {
        bytes32 commitment = _commitmentOf(LISTING_ID, LISTING_PRICE, SALT);
        _commit(commitment, operator);
        _rollMinDelay();

        // Wrong listingId.
        vm.expectRevert(); // CommitmentNotFound (the wrong commitment)
        vm.prank(operator);
        engine.revealAndExecute(LISTING_ID + 1, LISTING_PRICE, SALT);

        // Wrong maxPrice.
        vm.expectRevert();
        vm.prank(operator);
        engine.revealAndExecute(LISTING_ID, LISTING_PRICE + 1, SALT);

        // Wrong salt.
        vm.expectRevert();
        vm.prank(operator);
        engine.revealAndExecute(LISTING_ID, LISTING_PRICE, bytes32(uint256(0xDEAD)));
    }

    function test_DoubleRevealReverts() public {
        bytes32 commitment = _commitmentOf(LISTING_ID, LISTING_PRICE, SALT);
        _commit(commitment, operator);
        _rollMinDelay();

        vm.prank(operator);
        engine.revealAndExecute(LISTING_ID, LISTING_PRICE, SALT);

        // Second reveal with the same data must revert (commitment burned).
        vm.expectRevert(
            abi.encodeWithSelector(BuybackEngine.CommitmentNotFound.selector, commitment)
        );
        vm.prank(operator);
        engine.revealAndExecute(LISTING_ID, LISTING_PRICE, SALT);
    }

    function test_CommitTwiceReverts() public {
        bytes32 commitment = _commitmentOf(LISTING_ID, LISTING_PRICE, SALT);
        _commit(commitment, operator);

        vm.expectRevert(
            abi.encodeWithSelector(BuybackEngine.CommitmentExists.selector, commitment)
        );
        _commit(commitment, operator);
    }

    // ═══════ Role gating ═══════

    function test_OnlyOperatorCanCommit() public {
        bytes32 commitment = _commitmentOf(LISTING_ID, LISTING_PRICE, SALT);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                attacker,
                engine.BUYBACK_OPERATOR_ROLE()
            )
        );
        vm.prank(attacker);
        engine.commitBuyback(commitment);
    }

    function test_OnlyOperatorCanReveal() public {
        bytes32 commitment = _commitmentOf(LISTING_ID, LISTING_PRICE, SALT);
        _commit(commitment, operator);
        _rollMinDelay();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                attacker,
                engine.BUYBACK_OPERATOR_ROLE()
            )
        );
        vm.prank(attacker);
        engine.revealAndExecute(LISTING_ID, LISTING_PRICE, SALT);
    }

    function test_AdminCanCancelCommitment() public {
        bytes32 commitment = _commitmentOf(LISTING_ID, LISTING_PRICE, SALT);
        _commit(commitment, operator);

        vm.expectEmit(true, true, false, true);
        emit BuybackCancelled(commitment, multisig, "stuck");
        vm.prank(multisig);
        engine.cancelCommitment(commitment, "stuck");

        assertEq(engine.commitmentBlock(commitment), 0);
    }

    function test_OnlyAdminCanCancelCommitment() public {
        bytes32 commitment = _commitmentOf(LISTING_ID, LISTING_PRICE, SALT);
        _commit(commitment, operator);

        vm.expectRevert();
        vm.prank(operator); // operator has BUYBACK role but NOT DEFAULT_ADMIN
        engine.cancelCommitment(commitment, "unauthorized");
    }

    function test_CancelOfNonexistentReverts() public {
        bytes32 commitment = _commitmentOf(99999, 1, bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(BuybackEngine.CommitmentNotFound.selector, commitment)
        );
        vm.prank(multisig);
        engine.cancelCommitment(commitment, "ghost");
    }

    function test_RevealAfterAdminCancelReverts() public {
        bytes32 commitment = _commitmentOf(LISTING_ID, LISTING_PRICE, SALT);
        _commit(commitment, operator);

        vm.prank(multisig);
        engine.cancelCommitment(commitment, "operationally cancelled");

        _rollMinDelay();
        vm.expectRevert(
            abi.encodeWithSelector(BuybackEngine.CommitmentNotFound.selector, commitment)
        );
        vm.prank(operator);
        engine.revealAndExecute(LISTING_ID, LISTING_PRICE, SALT);
    }

    // ═══════ EDGE CASES ═══════

    function test_ListingCancelledBetweenCommitAndReveal() public {
        bytes32 commitment = _commitmentOf(LISTING_ID, LISTING_PRICE, SALT);
        _commit(commitment, operator);

        // Listing gets cancelled mid-flight.
        marketplace.setListing(LISTING_ID, makeAddr("seller"), 1, LISTING_AMOUNT, LISTING_PRICE, false);

        _rollMinDelay();
        vm.expectRevert("Listing not active");
        vm.prank(operator);
        engine.revealAndExecute(LISTING_ID, LISTING_PRICE, SALT);
    }

    function test_ListingBoughtByOtherBetweenCommitAndReveal() public {
        bytes32 commitment = _commitmentOf(LISTING_ID, LISTING_PRICE, SALT);
        _commit(commitment, operator);

        // Another buyer wins the listing (mock marks inactive).
        marketplace.executeBuy(LISTING_ID);

        _rollMinDelay();
        vm.expectRevert("Listing not active");
        vm.prank(operator);
        engine.revealAndExecute(LISTING_ID, LISTING_PRICE, SALT);
    }

    function test_MaxPriceExceededAtReveal() public {
        // Operator commits with a maxPrice strictly below the listing price.
        uint256 tooLowMax = LISTING_PRICE - 1;
        bytes32 commitment = _commitmentOf(LISTING_ID, tooLowMax, SALT);
        _commit(commitment, operator);
        _rollMinDelay();

        vm.expectRevert("Listing price exceeds max");
        vm.prank(operator);
        engine.revealAndExecute(LISTING_ID, tooLowMax, SALT);
    }

    // ═══════ Constants pinning ═══════

    function test_ConstantsHaveSpecValues() public view {
        assertEq(engine.MIN_REVEAL_DELAY_BLOCKS(), 100);
        assertEq(engine.MAX_REVEAL_WINDOW_BLOCKS(), 600);
    }

    function test_CommitmentBlockReadable() public {
        bytes32 commitment = _commitmentOf(LISTING_ID, LISTING_PRICE, SALT);
        uint256 expected = block.number;
        _commit(commitment, operator);
        assertEq(engine.commitmentBlock(commitment), expected);
    }
}
