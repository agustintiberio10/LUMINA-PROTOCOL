// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CoverRouterV2} from "../../src/core/CoverRouterV2.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

// ═══════ Mocks ═══════

contract CRMockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract CRMockPolicyManager {
    uint256 public nextId;
    uint256 public totalRecorded;

    function recordPolicy(
        bytes32 /*productId*/,
        address /*buyer*/,
        uint256 /*coverage*/,
        uint256 /*premium*/,
        uint32 /*duration*/,
        bytes32 /*asset*/
    ) external returns (uint256) {
        nextId++;
        totalRecorded++;
        return nextId;
    }

    function triggerPayout(bytes32 /*productId*/, uint256 /*policyId*/, bytes calldata /*proof*/) external {}
}

contract CRMockBurner {
    uint256 public totalReceived;
    address public usdc;
    constructor(address _usdc) { usdc = _usdc; }
    function receivePremium(uint256 amount) external {
        // Pull funds to mimic real burner accounting.
        ERC20(usdc).transferFrom(msg.sender, address(this), amount);
        totalReceived += amount;
    }
}

contract CRHandler is Test {
    CoverRouterV2 public router;
    CRMockUSDC public usdc;
    bytes32 public constant PID = keccak256("CR_MOCK_PROD");
    uint256 public ghostPurchased;

    address public buyer = address(0xB0B);

    constructor(CoverRouterV2 _r, CRMockUSDC _u) {
        router = _r;
        usdc = _u;
        // Pre-fund buyer + grant approval.
        usdc.mint(buyer, 1_000_000e6);
        vm.prank(buyer);
        usdc.approve(address(_r), type(uint256).max);
    }

    function buy(uint256 coverageSeed) external {
        uint256 coverage = bound(coverageSeed, 100e6, 50_000e6); // $100-$50K
        vm.prank(buyer);
        try router.purchasePolicy(PID, coverage, "BTC") returns (uint256) {
            ghostPurchased++;
        } catch {}
    }

    function togglePause() external {
        try router.setPaused(!router.paused()) {} catch {}
    }
}

contract CoverRouterInvariants is Test {
    CoverRouterV2 public router;
    CRMockUSDC public usdc;
    CRMockPolicyManager public pm;
    CRMockBurner public burner;
    CRHandler public handler;

    function setUp() public {
        usdc = new CRMockUSDC();
        pm = new CRMockPolicyManager();
        burner = new CRMockBurner(address(usdc));

        router = ProxyDeployer.deployCoverRouterV2(address(usdc), address(pm), address(burner));

        // Configure a mock product so purchases succeed.
        router.configureProduct(
            keccak256("CR_MOCK_PROD"),
            8000, // payoutRatio 80%
            20,   // triggerProb 0.20%
            15000, // margin 1.50x
            uint32(7 days),
            true
        );

        handler = new CRHandler(router, usdc);
        targetContract(address(handler));
    }

    /// INV-Y-CR-1: handler ghost counter aligned with mock PolicyManager.
    /// CoverRouter records each successful purchase via policyManager.recordPolicy,
    /// so handler.ghostPurchased() == pm.totalRecorded().
    function invariant_handlerMatchesPM() public view {
        assertEq(
            handler.ghostPurchased(),
            pm.totalRecorded(),
            "INV-Y-CR-1: router purchases != PolicyManager recorded"
        );
    }

    /// INV-Y-CR-2: All USDC entering router transits to burner (no residue).
    /// _purchase pulls premium from buyer then forceApproves + receivePremium.
    /// The burner pulls funds; router holds zero USDC outside a tx.
    function invariant_noUsdcResidue() public view {
        assertEq(usdc.balanceOf(address(router)), 0, "INV-Y-CR-2: USDC stuck in router");
    }

    /// INV-Y-CR-3: paused is a boolean (trivially holds; placeholder to exercise getter).
    function invariant_pauseFlagBool() public view {
        bool p = router.paused();
        assertTrue(p == true || p == false, "INV-Y-CR-3: paused not boolean");
    }
}
