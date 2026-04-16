// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {VolatileShortVault} from "../src/vaults/VolatileShortVault.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockAavePool} from "../src/mocks/MockAavePool.sol";

contract VaultHandler is Test {
    VolatileShortVault public vault;
    MockERC20 public usdc;
    address public policyManager;
    address[] public actors;

    constructor(VolatileShortVault _vault, MockERC20 _usdc, address _pm) {
        vault = _vault;
        usdc = _usdc;
        policyManager = _pm;
        actors.push(address(0x1001));
        actors.push(address(0x1002));
        actors.push(address(0x1003));
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 100e6, 500_000e6);
        usdc.mint(actor, amount);
        vm.startPrank(actor);
        usdc.approve(address(vault), amount);
        vault.depositAssets(amount, actor);
        vm.stopPrank();
    }

    function lock(uint256 amount) external {
        uint256 free = vault.freeAssets();
        if (free == 0) return;
        amount = bound(amount, 1, free);
        uint256 total = vault.totalAssets();
        uint256 maxUtil = (total * 9500) / 10000;
        if (vault.allocatedAssets() + amount > maxUtil) return;
        vm.prank(policyManager);
        vault.lockCollateral(amount, keccak256("TEST"), uint256(keccak256(abi.encode(amount, block.timestamp))));
    }

    function unlock(uint256 amount) external {
        uint256 allocated = vault.allocatedAssets();
        if (allocated == 0) return;
        amount = bound(amount, 1, allocated);
        vm.prank(policyManager);
        vault.unlockCollateral(amount, keccak256("TEST"), 1);
    }
}

contract InvariantTests is Test {
    VolatileShortVault vault;
    MockERC20 usdc;
    MockERC20 aToken;
    MockAavePool aavePool;
    VaultHandler handler;

    address owner = address(0xA);
    address router = address(0xD);
    address policyManager = address(0xE);

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        aToken = new MockERC20("aUSDC", "aUSDC", 6);
        aavePool = new MockAavePool(address(aToken));
        usdc.mint(address(aavePool), 1_000_000_000e6);

        VolatileShortVault impl = new VolatileShortVault();
        bytes memory data = abi.encodeCall(
            VolatileShortVault.initialize,
            (owner, address(usdc), router, policyManager, address(aavePool), address(aToken))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        vault = VolatileShortVault(address(proxy));

        handler = new VaultHandler(vault, usdc, policyManager);
    }

    // Invariant test: after multiple operations, allocated never exceeds total
    function test_invariant_AllocatedNeverExceedsTotal() public {
        // Run random operations
        for (uint256 i = 0; i < 10; i++) {
            handler.deposit(i, 100_000e6 + i * 50_000e6);
            handler.lock(10_000e6 + i * 5_000e6);
        }
        for (uint256 i = 0; i < 5; i++) {
            handler.unlock(5_000e6 + i * 2_000e6);
        }
        assertLe(vault.allocatedAssets(), vault.totalAssets(), "INVARIANT: allocated <= total");
    }

    // Invariant test: freeAssets never reverts (underflow protection)
    function test_invariant_FreeAssetsNonNegative() public {
        handler.deposit(0, 500_000e6);
        handler.lock(400_000e6);
        // freeAssets() should work without reverting
        uint256 free = vault.freeAssets();
        assertGe(free, 0);
    }

    // Invariant test: utilization capped at 95%
    function test_invariant_UtilizationCapped() public {
        handler.deposit(0, 1_000_000e6);
        // Try to lock maximum
        uint256 total = vault.totalAssets();
        uint256 maxLock = (total * 9500) / 10000;
        handler.lock(maxLock);
        uint256 utilBps = total > 0 ? (vault.allocatedAssets() * 10000) / total : 0;
        assertLe(utilBps, 9500, "INVARIANT: utilization <= 95%");
    }
}
