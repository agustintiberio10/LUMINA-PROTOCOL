// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../src/core/CoverRouterV2.sol";

// Lightweight mocks reused from CoverRouterV2Test pattern.
contract MockPM {
    uint256 public nextPolicyId = 1;

    function recordPolicy(bytes32, address, uint256, uint256, uint32, bytes32) external returns (uint256) {
        return nextPolicyId++;
    }
    function triggerPayout(bytes32, uint256, bytes calldata) external {}
}

contract MockBurner {
    IERC20 public usdc;

    constructor(address _u) {
        usdc = IERC20(_u);
    }

    function receivePremium(uint256 amount) external {
        usdc.transferFrom(msg.sender, address(this), amount);
    }
}

contract MockERC20 {
    string public name;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n) {
        name = n;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

/// @notice Sprint CR-USDC-Reconfig — covers the new `setUsdc(address)` admin
/// path added to `CoverRouterV2`. Verifies access control, zero-address
/// guard, event emission, and that a subsequent `purchasePolicy` actually
/// pulls premium from the NEW token (not the old one).
contract CoverRouterV2ReconfigUsdcTest is Test {
    CoverRouterV2 router;
    MockPM pm;
    MockBurner burner;
    MockERC20 oldUsdc;
    MockERC20 newUsdc;
    address user = makeAddr("user");
    address attacker = makeAddr("attacker");

    event UsdcUpdated(address indexed oldUsdc, address indexed newUsdc);

    function setUp() public {
        vm.chainId(8453);
        oldUsdc = new MockERC20("OldUSDC");
        newUsdc = new MockERC20("NewUSDC");
        pm = new MockPM();
        burner = new MockBurner(address(oldUsdc));

        CoverRouterV2 impl = new CoverRouterV2();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(CoverRouterV2.initialize.selector, address(oldUsdc), address(pm), address(burner))
        );
        router = CoverRouterV2(address(proxy));

        bytes32 pid = keccak256("FLASHBTC1H-001");
        router.configureProduct(pid, 8000, 100, 20000, 3600, true);
    }

    // ─── Access control ───

    function test_setUsdc_revertsForNonOwner() public {
        vm.expectRevert();
        vm.prank(attacker);
        router.setUsdc(address(newUsdc));
    }

    function test_setUsdc_revertsOnZeroAddress() public {
        vm.expectRevert(bytes("Zero USDC"));
        router.setUsdc(address(0));
    }

    // ─── Happy path ───

    function test_setUsdc_updatesStorageAndEmits() public {
        address oldAddr = address(router.usdc());
        assertEq(oldAddr, address(oldUsdc), "pre-state");

        vm.expectEmit(true, true, false, false);
        emit UsdcUpdated(oldAddr, address(newUsdc));
        router.setUsdc(address(newUsdc));

        assertEq(address(router.usdc()), address(newUsdc), "storage updated");
    }

    // ─── End-to-end: purchase pulls from NEW token after reconfig ───

    function test_purchaseAfterReconfig_pullsFromNewUsdc() public {
        // Reconfig the premium token AND swap the burner to one that knows
        // about the new token. (In prod the BondVault burner reads usdc
        // off the router dynamically — the MockBurner takes it at ctor.)
        router.setUsdc(address(newUsdc));
        MockBurner newBurner = new MockBurner(address(newUsdc));
        router.setTwapBurner(address(newBurner));

        newUsdc.mint(user, 1_000_000e6);
        vm.prank(user);
        newUsdc.approve(address(router), type(uint256).max);

        bytes32 pid = keccak256("FLASHBTC1H-001");
        vm.prank(user);
        uint256 policyId = router.purchasePolicy(pid, 1_000e6, bytes32("BTC"));

        assertGt(policyId, 0, "policy minted");
        assertEq(oldUsdc.balanceOf(user), 0, "old usdc untouched");
        assertLt(newUsdc.balanceOf(user), 1_000_000e6, "new usdc pulled");
    }

    function test_purchaseBeforeReconfig_pullsFromOldUsdc() public {
        oldUsdc.mint(user, 1_000_000e6);
        vm.prank(user);
        oldUsdc.approve(address(router), type(uint256).max);

        bytes32 pid = keccak256("FLASHBTC1H-001");
        vm.prank(user);
        router.purchasePolicy(pid, 1_000e6, bytes32("BTC"));

        assertLt(oldUsdc.balanceOf(user), 1_000_000e6, "old usdc pulled (sanity)");
    }
}
