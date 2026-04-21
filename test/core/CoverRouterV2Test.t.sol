// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../src/core/CoverRouterV2.sol";

contract MockPolicyManager {
    uint256 public nextPolicyId = 1;

    function recordPolicy(bytes32, address, uint256, uint256, uint32, bytes32) external returns (uint256) {
        return nextPolicyId++;
    }

    function triggerPayout(bytes32, uint256, bytes calldata) external {}
}

contract MockTWAPBurner {
    uint256 public totalReceived;
    IERC20 public usdc;

    constructor(address _usdc) {
        usdc = IERC20(_usdc);
    }

    function receivePremium(uint256 amount) external {
        usdc.transferFrom(msg.sender, address(this), amount);
        totalReceived += amount;
    }
}

contract MockUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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

contract CoverRouterV2Test is Test {
    CoverRouterV2 router;
    MockPolicyManager pm;
    MockTWAPBurner burner;
    MockUSDC usdc;
    address user = makeAddr("user");

    function setUp() public {
        usdc = new MockUSDC();
        pm = new MockPolicyManager();
        burner = new MockTWAPBurner(address(usdc));

        CoverRouterV2 impl = new CoverRouterV2();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(CoverRouterV2.initialize.selector, address(usdc), address(pm), address(burner))
        );
        router = CoverRouterV2(address(proxy));

        // Configure Flash BTC 1h product
        bytes32 pid = keccak256("FLASHBTC1H-001");
        router.configureProduct(pid, 8000, 20, 15000, 3600, true);

        // Give user USDC
        usdc.mint(user, 1_000_000e6);
    }

    function test_quotePremium() public view {
        bytes32 pid = keccak256("FLASHBTC1H-001");
        (uint256 premium, uint256 payout) = router.quotePremium(pid, 1000e6);
        assertEq(premium, 2_400_000);
        assertEq(payout, 800e6);
    }

    function test_purchasePolicy() public {
        bytes32 pid = keccak256("FLASHBTC1H-001");
        vm.startPrank(user);
        usdc.approve(address(router), 10e6);
        uint256 policyId = router.purchasePolicy(pid, 1000e6, "BTC");
        vm.stopPrank();

        assertEq(policyId, 1);
        assertEq(burner.totalReceived(), 2_400_000); // $2.40
    }

    function test_purchasePolicy_minCoverage() public {
        bytes32 pid = keccak256("FLASHBTC1H-001");
        vm.startPrank(user);
        usdc.approve(address(router), 10e6);
        vm.expectRevert();
        router.purchasePolicy(pid, 50e6, "BTC"); // $50 < $100 min
        vm.stopPrank();
    }

    function test_relayer_purchase() public {
        bytes32 pid = keccak256("FLASHBTC1H-001");
        address relayer = makeAddr("relayer");
        router.setRelayer(relayer, true);

        usdc.mint(relayer, 100e6);
        vm.startPrank(relayer);
        usdc.approve(address(router), 10e6);
        uint256 policyId = router.purchasePolicyFor(pid, 1000e6, "BTC", user);
        vm.stopPrank();

        assertEq(policyId, 1);
    }

    function test_unauthorized_relayer_reverts() public {
        bytes32 pid = keccak256("FLASHBTC1H-001");
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        router.purchasePolicyFor(pid, 1000e6, "BTC", user);
    }

    function test_paused_reverts() public {
        router.setPaused(true);
        bytes32 pid = keccak256("FLASHBTC1H-001");
        vm.startPrank(user);
        usdc.approve(address(router), 10e6);
        vm.expectRevert();
        router.purchasePolicy(pid, 1000e6, "BTC");
        vm.stopPrank();
    }

    function test_productNotConfigured() public {
        vm.startPrank(user);
        usdc.approve(address(router), 10e6);
        vm.expectRevert();
        router.purchasePolicy(keccak256("FAKE"), 1000e6, "BTC");
        vm.stopPrank();
    }

    function test_configureAllProducts() public {
        router.configureProduct(keccak256("FLASHBTC4H-001"), 8000, 35, 15000, 14400, true);
        router.configureProduct(keccak256("FLASHBTC24-001"), 8000, 150, 15000, 86400, true);
        router.configureProduct(keccak256("FLASHBTC48-001"), 8000, 80, 15000, 172800, true);
        router.configureProduct(keccak256("FLASHETH1H-001"), 8000, 25, 15000, 3600, true);
        router.configureProduct(keccak256("FLASHETH24-001"), 8000, 200, 15000, 86400, true);
        router.configureProduct(keccak256("FLASHETH48-001"), 8000, 90, 15000, 172800, true);
        router.configureProduct(keccak256("MICRODEPEG-001"), 8000, 350, 15000, 604800, true);
        router.configureProduct(keccak256("RATESHOCK-001"), 8000, 400, 15000, 604800, true);

        assertEq(router.getProductCount(), 9);
    }

    function test_cannot_initialize_twice() public {
        vm.expectRevert();
        router.initialize(address(usdc), address(pm), address(burner));
    }
}
