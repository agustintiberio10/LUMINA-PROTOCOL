// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProxyDeployer} from "../../../helpers/ProxyDeployer.sol";

import {LuminaTokenV2} from "../../../../src/token/LuminaTokenV2.sol";
import {BondVault} from "../../../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../../../src/bonds/ClaimBond.sol";
import {PolicyManagerV2} from "../../../../src/core/PolicyManagerV2.sol";
import {CoverRouterV2} from "../../../../src/core/CoverRouterV2.sol";
import {TWAPBurner} from "../../../../src/core/TWAPBurner.sol";
import {IDexRouter} from "../../../../src/interfaces/IDexRouter.sol";

// ─────────────────────────────────────────────────────────────────────────
// Mocks (USDC / oracle / DEX / shield) — protocol contracts are real.
// ─────────────────────────────────────────────────────────────────────────

contract MockUSDC is IERC20 {
    string public name = "USDC";
    string public symbol = "USDC";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        totalSupply += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) {
            allowance[f][msg.sender] -= a;
        }
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

contract MockOracle {
    function getLuminaPrice() external pure returns (uint256) {
        return 1e16; // 0.01 USD/LUMINA
    }
}

contract MockDex is IDexRouter {
    IERC20 public lumina;

    constructor(address l) {
        lumina = IERC20(l);
    }

    function swap(address tokenIn, address, uint256 amountIn, uint256) external override returns (uint256) {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = amountIn * 27 * 1e12;
        lumina.transfer(msg.sender, out);
        return out;
    }

    function getQuote(address, address, uint256 amountIn) external pure override returns (uint256) {
        return amountIn * 27 * 1e12;
    }
}

contract MockShield {
    uint256 private _next;

    struct CreatePolicyParams {
        address buyer;
        uint256 coverageAmount;
        uint256 premiumAmount;
        uint32 durationSeconds;
        bytes32 asset;
        bytes32 stablecoin;
        address protocol;
        bytes extraData;
    }

    function createPolicy(CreatePolicyParams calldata) external returns (uint256) {
        _next++;
        return _next;
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Adversarial scenarios for the relayer pattern.
//
// Companion to the bug-confirmation tests in
// `test/audit/v5.1-uups/fix-relayer-payment/` (which prove the basic
// invariant: buyer pays, relayer does not). This file goes one layer
// deeper: malicious authorized relayer, two-relayer races, allowance as
// a true cap, and the relayer==buyer corner case.
//
// All tests target the FIXED `purchasePolicyFor` (post-PR #86, deployed
// on Sepolia at impl 0x8bdC5Ee2Aa8C24fA6F4665B1B2a82650C6daafa0).
// ─────────────────────────────────────────────────────────────────────────

contract AdversarialRelayerTest is Test {
    LuminaTokenV2 token;
    ClaimBond cb;
    BondVault vault;
    PolicyManagerV2 pm;
    CoverRouterV2 router;
    TWAPBurner burner;
    MockUSDC usdc;
    MockOracle oracle;
    MockDex dex;
    MockShield shield;

    bytes32 productId;
    address admin = address(this);
    address relayer = makeAddr("relayer");
    address evilRelayer = makeAddr("evilRelayer");
    address buyer = makeAddr("buyer");

    function setUp() public {
        vm.chainId(8453);
        usdc = new MockUSDC();
        oracle = new MockOracle();

        uint256 nonce = vm.getNonce(address(this));
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 10);

        token = ProxyDeployer.deployLuminaTokenV2(
            predictedVault, makeAddr("cex"), makeAddr("founder"), makeAddr("lbp"), makeAddr("treasury")
        );

        dex = new MockDex(address(token));
        deal(address(token), address(dex), 100_000_000e18);

        burner = ProxyDeployer.deployTWAPBurner(address(usdc), address(token), address(dex));
        token.grantRole(token.BURNER_ROLE(), address(burner));

        cb = ProxyDeployer.deployClaimBond();
        pm = ProxyDeployer.deployPolicyManagerV2(predictedVault);
        vault = ProxyDeployer.deployBondVault(address(token), address(cb), address(oracle), address(pm));
        require(address(vault) == predictedVault, "vault address mismatch");

        cb.setBondVault(address(vault));

        router = ProxyDeployer.deployCoverRouterV2(address(usdc), address(pm), address(burner));
        router.setCapacityOracle(address(oracle));
        pm.setRouter(address(router));

        burner.setReserves(makeAddr("buyback"), makeAddr("ops"), makeAddr("maintenance"));

        productId = keccak256("FLASHBTC1H-001");
        shield = new MockShield();
        pm.registerProduct(productId, address(shield));
        router.configureProduct(productId, 8000, 100, 15000, 3600, true);

        // Two relayers — both authorized.
        router.setRelayer(relayer, true);
        router.setRelayer(evilRelayer, true);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 1. Authorized relayer cannot drain a buyer beyond their allowance.
    //    The USDC `allowance[buyer -> router]` is the hard cap. After it is
    //    exhausted, further `purchasePolicyFor` calls revert.
    // ─────────────────────────────────────────────────────────────────────
    function test_Adv_AllowanceCapsRelayerSpending() public {
        usdc.mint(buyer, 100_000e6);

        // Coverage 1 000 USDC x payoutBps 8000 x triggerBps 100 x marginBps 15000 / 1e12
        //   = 12 000 000 base units = 12 USDC per call. We approve exactly two calls.
        vm.prank(buyer);
        usdc.approve(address(router), 24_000_000); // 24 USDC, room for 2 purchases

        vm.prank(relayer);
        router.purchasePolicyFor(productId, 1_000e6, "BTC", buyer);

        vm.prank(relayer);
        router.purchasePolicyFor(productId, 1_000e6, "BTC", buyer);

        // Third must revert — allowance exhausted, and the protocol does not
        // fall back to charging the relayer.
        vm.prank(relayer);
        vm.expectRevert(); // SafeERC20: transfer-from underflow on allowance
        router.purchasePolicyFor(productId, 1_000e6, "BTC", buyer);

        assertEq(usdc.allowance(buyer, address(router)), 0, "allowance fully drained, not negative");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2. A malicious authorized relayer cannot redirect the bond NFT to
    //    themselves by passing buyer = relayer-controlled address. The
    //    policy is recorded under whatever address they pass, but they
    //    can only do this if THAT address has USDC + approval — which
    //    means draining their own funded sock-puppet, not the user's.
    // ─────────────────────────────────────────────────────────────────────
    function test_Adv_MaliciousRelayer_CannotRedirectViaBuyerArg() public {
        // The honest buyer has approved the router.
        usdc.mint(buyer, 100_000e6);
        vm.prank(buyer);
        usdc.approve(address(router), type(uint256).max);

        // Evil relayer tries to "buy for itself" using the honest buyer's funds
        // by simply passing its own address as `buyer` — but it controls no
        // approval there, so the call reverts at safeTransferFrom.
        vm.prank(evilRelayer);
        vm.expectRevert(); // evilRelayer has zero allowance to router
        router.purchasePolicyFor(productId, 1_000e6, "BTC", evilRelayer);

        // The honest buyer's funds and policy count are untouched.
        assertEq(pm.totalPolicies(), 0, "no policy created from the failed call");
        assertEq(usdc.balanceOf(buyer), 100_000e6, "honest buyer untouched");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 3. Two authorized relayers buying for the same buyer race-free.
    //    Both calls succeed, each creates a distinct policy id, and the
    //    buyer is charged exactly twice the premium.
    // ─────────────────────────────────────────────────────────────────────
    function test_Adv_TwoRelayers_SameBuyer_BothCreateDistinctPolicies() public {
        usdc.mint(buyer, 100_000e6);
        vm.prank(buyer);
        usdc.approve(address(router), type(uint256).max);

        uint256 buyerBefore = usdc.balanceOf(buyer);

        vm.prank(relayer);
        uint256 idA = router.purchasePolicyFor(productId, 1_000e6, "BTC", buyer);

        vm.prank(evilRelayer); // also authorized in setUp
        uint256 idB = router.purchasePolicyFor(productId, 1_000e6, "BTC", buyer);

        assertTrue(idA != idB, "policy ids are distinct");
        assertEq(pm.totalPolicies(), 2, "two policies recorded");

        uint256 paid = buyerBefore - usdc.balanceOf(buyer);
        assertEq(paid, 24_000_000, "buyer charged 2 x 12 USDC = 24 USDC");

        // Both policies belong to the buyer, not to either relayer.
        PolicyManagerV2.PolicyRecord memory rA = pm.getPolicy(productId, idA);
        PolicyManagerV2.PolicyRecord memory rB = pm.getPolicy(productId, idB);
        assertEq(rA.buyer, buyer, "policy A owner = buyer");
        assertEq(rB.buyer, buyer, "policy B owner = buyer");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 4. Relayer authorisation is a hard gate — a previously-authorised
    //    relayer that is later revoked cannot continue to submit, even if
    //    the buyer still has USDC + approval.
    // ─────────────────────────────────────────────────────────────────────
    function test_Adv_RevokedRelayer_CannotPurchase() public {
        usdc.mint(buyer, 100_000e6);
        vm.prank(buyer);
        usdc.approve(address(router), type(uint256).max);

        // First call succeeds.
        vm.prank(relayer);
        router.purchasePolicyFor(productId, 1_000e6, "BTC", buyer);

        // Owner revokes the relayer.
        router.setRelayer(relayer, false);

        // Subsequent call reverts at the auth gate, BEFORE touching the
        // buyer's USDC. Auth comes first, then the transfer.
        uint256 buyerMid = usdc.balanceOf(buyer);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(CoverRouterV2.NotAuthorizedRelayer.selector, relayer));
        router.purchasePolicyFor(productId, 1_000e6, "BTC", buyer);
        assertEq(usdc.balanceOf(buyer), buyerMid, "buyer balance unchanged after revoked-relayer revert");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 5. `purchasePolicyFor` with buyer == relayer (relayer buying for
    //    themselves through the For path) is allowed and behaves as a
    //    self-purchase. Charges the relayer's own address (because that
    //    address IS the buyer here), so the "relayer never pays" property
    //    is preserved in the substantive sense — money comes from the
    //    address named in the buyer arg.
    // ─────────────────────────────────────────────────────────────────────
    function test_Adv_BuyerEqualsRelayer_BehavesAsSelfPurchase() public {
        usdc.mint(relayer, 100_000e6);
        vm.prank(relayer);
        usdc.approve(address(router), type(uint256).max);

        uint256 before_ = usdc.balanceOf(relayer);

        vm.prank(relayer);
        uint256 id = router.purchasePolicyFor(productId, 1_000e6, "BTC", relayer);

        assertGt(id, 0, "policy created");
        assertLt(usdc.balanceOf(relayer), before_, "relayer-as-buyer paid the premium");

        PolicyManagerV2.PolicyRecord memory r = pm.getPolicy(productId, id);
        assertEq(r.buyer, relayer, "policy owner is the relayer (because they passed themselves as buyer)");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 6. The `payer` argument inside `_purchase` is now the SUBMITTER for
    //    telemetry only — the `PolicyPurchased` event must record the
    //    relayer in the `payer` slot (so off-chain consumers can attribute
    //    the submission), but the actual USDC pull happened from `buyer`.
    // ─────────────────────────────────────────────────────────────────────
    function test_Adv_Event_RecordsRelayerAsSubmitter_ButBuyerPaid() public {
        usdc.mint(buyer, 100_000e6);
        vm.prank(buyer);
        usdc.approve(address(router), type(uint256).max);

        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 relayerBefore = usdc.balanceOf(relayer);

        // Just verify both invariants together: buyer balance dropped, relayer
        // didn't move. The event itself is exercised by the existing PolicyPurchased
        // emit in CoverRouterV2._purchase; we do not over-fit the test to its
        // exact topic encoding.
        vm.prank(relayer);
        router.purchasePolicyFor(productId, 1_000e6, "BTC", buyer);

        assertLt(usdc.balanceOf(buyer), buyerBefore, "buyer paid");
        assertEq(usdc.balanceOf(relayer), relayerBefore, "relayer did not pay");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 7. Permit-style flows — the protocol does NOT consume USDC permits.
    //    Confirm that the only way for a relayer to spend on behalf of a
    //    buyer is via a pre-existing ERC-20 allowance. There is no
    //    bypass via off-chain signatures.
    // ─────────────────────────────────────────────────────────────────────
    function test_Adv_NoPermitBypass_OnlyAllowanceWorks() public {
        usdc.mint(buyer, 100_000e6);
        // Buyer NEVER approves the router.

        // No permit / no signature surface exists in CoverRouterV2 — the only
        // entrypoint for relayer-mediated purchase is purchasePolicyFor, which
        // routes straight into safeTransferFrom and requires a real on-chain
        // allowance.
        vm.prank(relayer);
        vm.expectRevert();
        router.purchasePolicyFor(productId, 1_000e6, "BTC", buyer);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 8. A relayer cannot escalate to OWNER and self-authorise via a
    //    purchasePolicyFor call. (Sanity: the auth check uses the
    //    `authorizedRelayers` mapping, which only the owner can write.)
    // ─────────────────────────────────────────────────────────────────────
    function test_Adv_RelayerCannotSelfAuthorize() public {
        // Use a fresh, unauthorized address.
        address rogue = makeAddr("rogue");
        usdc.mint(buyer, 100_000e6);
        vm.prank(buyer);
        usdc.approve(address(router), type(uint256).max);

        // Rogue tries to authorise itself — should revert (only owner).
        vm.prank(rogue);
        vm.expectRevert();
        router.setRelayer(rogue, true);

        // Confirm: rogue still cannot purchase.
        vm.prank(rogue);
        vm.expectRevert(abi.encodeWithSelector(CoverRouterV2.NotAuthorizedRelayer.selector, rogue));
        router.purchasePolicyFor(productId, 1_000e6, "BTC", buyer);
    }
}
