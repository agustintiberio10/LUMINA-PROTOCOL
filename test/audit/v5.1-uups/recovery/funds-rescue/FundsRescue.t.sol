// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProxyDeployer} from "../../../../helpers/ProxyDeployer.sol";

import {TWAPBurner} from "../../../../../src/core/TWAPBurner.sol";
import {MaintenanceReserve} from "../../../../../src/treasury/MaintenanceReserve.sol";
import {BondVault} from "../../../../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../../../../src/bonds/ClaimBond.sol";
import {CoverRouterV2} from "../../../../../src/core/CoverRouterV2.sol";
import {CEXLiquidityReserve} from "../../../../../src/treasury/CEXLiquidityReserve.sol";
import {TreasuryVesting} from "../../../../../src/token/TreasuryVesting.sol";
import {IDexRouter} from "../../../../../src/interfaces/IDexRouter.sol";

// ─────────────────────────────────────────────────────────────────────────
// LOCAL MOCKS
// ─────────────────────────────────────────────────────────────────────────

/// @dev Minimal ERC20 mock — supports mint/transfer/approve with no extra logic.
contract MockERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        totalSupply += a;
    }

    function approve(address spender, uint256 a) external returns (bool) {
        allowance[msg.sender][spender] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

/// @dev Required for TWAPBurner.initialize (needs a router address).
contract InertDexRouter is IDexRouter {
    function swap(address, address, uint256, uint256) external pure override returns (uint256) {
        return 0;
    }

    function getQuote(address, address, uint256) external pure override returns (uint256) {
        return 0;
    }
}

contract MockUSDCForRescue is MockERC20 {
    constructor() MockERC20("USDC", "USDC") {}
}

contract MockLUMINAForRescue is MockERC20 {
    constructor() MockERC20("LUMINA", "LUM") {}
}

/// @dev Helper that can be destructed to force-send ETH without a receive().
contract EthForceSender {
    function destroy(address payable to) external payable {
        selfdestruct(to);
    }
}

// ─────────────────────────────────────────────────────────────────────────
// MAIN TESTS
// ─────────────────────────────────────────────────────────────────────────

contract FundsRescue is Test {
    // TokenRecovered event signature re-declared for vm.expectEmit.
    event TokenRecovered(address indexed token, uint256 amount);

    address internal admin = address(this); // owner / DEFAULT_ADMIN_ROLE
    address internal attacker = makeAddr("attacker");
    address internal user = makeAddr("user");

    // ─────────────────────────────────────────────────────────────
    // 1. TWAPBurner rescue — positive path
    // ─────────────────────────────────────────────────────────────

    function test_Rescue_UUPS_TWAPBurner_RandomToken_RecoverableByOwner() public {
        MockUSDCForRescue usdc = new MockUSDCForRescue();
        MockLUMINAForRescue lumina = new MockLUMINAForRescue();
        InertDexRouter dex = new InertDexRouter();
        TWAPBurner tb = ProxyDeployer.deployTWAPBurner(address(usdc), address(lumina), address(dex));

        MockERC20 rnd = new MockERC20("Random", "RND");
        rnd.mint(address(tb), 1_000e18);

        // Snapshot owner balance pre.
        uint256 ownerBefore = rnd.balanceOf(address(this));

        tb.recoverToken(address(rnd), 1_000e18);

        // Owner received it.
        assertEq(rnd.balanceOf(address(this)), ownerBefore + 1_000e18);
        assertEq(rnd.balanceOf(address(tb)), 0);
    }

    // ─────────────────────────────────────────────────────────────
    // 2. TWAPBurner blocks USDC + LUMINA
    // ─────────────────────────────────────────────────────────────

    function test_Rescue_UUPS_TWAPBurner_USDC_NotRecoverable() public {
        MockUSDCForRescue usdc = new MockUSDCForRescue();
        MockLUMINAForRescue lumina = new MockLUMINAForRescue();
        TWAPBurner tb = ProxyDeployer.deployTWAPBurner(address(usdc), address(lumina), address(new InertDexRouter()));

        // Give the burner some USDC (legit case — premium arrived).
        usdc.mint(address(tb), 10_000e18);

        vm.expectRevert("Cannot recover USDC");
        tb.recoverToken(address(usdc), 1);
    }

    function test_Rescue_UUPS_TWAPBurner_LUMINA_NotRecoverable() public {
        MockUSDCForRescue usdc = new MockUSDCForRescue();
        MockLUMINAForRescue lumina = new MockLUMINAForRescue();
        TWAPBurner tb = ProxyDeployer.deployTWAPBurner(address(usdc), address(lumina), address(new InertDexRouter()));

        lumina.mint(address(tb), 100e18);

        vm.expectRevert("Cannot recover LUMINA");
        tb.recoverToken(address(lumina), 1);
    }

    // ─────────────────────────────────────────────────────────────
    // 3. TWAPBurner access control
    // ─────────────────────────────────────────────────────────────

    function test_Rescue_UUPS_TWAPBurner_NonOwner_Reverts() public {
        MockUSDCForRescue usdc = new MockUSDCForRescue();
        MockLUMINAForRescue lumina = new MockLUMINAForRescue();
        TWAPBurner tb = ProxyDeployer.deployTWAPBurner(address(usdc), address(lumina), address(new InertDexRouter()));

        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(tb), 100e18);

        vm.prank(attacker);
        vm.expectRevert(); // OZ OwnableUnauthorizedAccount
        tb.recoverToken(address(rnd), 100e18);
    }

    // ─────────────────────────────────────────────────────────────
    // 4. TWAPBurner amount bounds
    // ─────────────────────────────────────────────────────────────

    function test_Rescue_UUPS_TWAPBurner_AmountExceedsBalance_Reverts() public {
        MockUSDCForRescue usdc = new MockUSDCForRescue();
        MockLUMINAForRescue lumina = new MockLUMINAForRescue();
        TWAPBurner tb = ProxyDeployer.deployTWAPBurner(address(usdc), address(lumina), address(new InertDexRouter()));

        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(tb), 500e18);

        // MockERC20 has unchecked subtraction, real OZ SafeERC20 would revert; expect
        // arithmetic-underflow revert in our mock.
        vm.expectRevert();
        tb.recoverToken(address(rnd), 10_000e18);
    }

    // ─────────────────────────────────────────────────────────────
    // 5. TWAPBurner event gap (observability)
    // ─────────────────────────────────────────────────────────────

    function test_Rescue_UUPS_TWAPBurner_EmitsNoEvent_GapDocumented() public {
        MockUSDCForRescue usdc = new MockUSDCForRescue();
        MockLUMINAForRescue lumina = new MockLUMINAForRescue();
        TWAPBurner tb = ProxyDeployer.deployTWAPBurner(address(usdc), address(lumina), address(new InertDexRouter()));

        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(tb), 50e18);

        // Record all logs; expect exactly ZERO logs for a successful rescue (gap).
        vm.recordLogs();
        tb.recoverToken(address(rnd), 50e18);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // The only log produced is the MockERC20 Transfer event; no TokenRecovered.
        // We assert no log from `tb` itself.
        bool burnerEmitted = false;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter == address(tb)) {
                burnerEmitted = true;
                break;
            }
        }
        assertFalse(burnerEmitted, "TWAPBurner.recoverToken emits no event (LOW finding)");
    }

    // ─────────────────────────────────────────────────────────────
    // 6. MaintenanceReserve rescue — positive path
    // ─────────────────────────────────────────────────────────────

    function test_Rescue_UUPS_MaintenanceReserve_RandomToken_RecoverableByAdmin() public {
        MockUSDCForRescue usdc = new MockUSDCForRescue();
        MaintenanceReserve mr = ProxyDeployer.deployMaintenanceReserve(address(usdc), admin);

        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(mr), 250e18);

        uint256 adminBefore = rnd.balanceOf(admin);
        mr.recoverToken(address(rnd), 250e18);

        assertEq(rnd.balanceOf(admin), adminBefore + 250e18);
        assertEq(rnd.balanceOf(address(mr)), 0);
    }

    // ─────────────────────────────────────────────────────────────
    // 7. MaintenanceReserve blocks USDC
    // ─────────────────────────────────────────────────────────────

    function test_Rescue_UUPS_MaintenanceReserve_USDC_NotRecoverable() public {
        MockUSDCForRescue usdc = new MockUSDCForRescue();
        MaintenanceReserve mr = ProxyDeployer.deployMaintenanceReserve(address(usdc), admin);

        usdc.mint(address(mr), 1_000e18);

        vm.expectRevert("Cannot recover USDC");
        mr.recoverToken(address(usdc), 1);
    }

    // ─────────────────────────────────────────────────────────────
    // 8. MaintenanceReserve access control
    // ─────────────────────────────────────────────────────────────

    function test_Rescue_UUPS_MaintenanceReserve_NonAdmin_Reverts() public {
        MockUSDCForRescue usdc = new MockUSDCForRescue();
        MaintenanceReserve mr = ProxyDeployer.deployMaintenanceReserve(address(usdc), admin);

        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(mr), 100e18);

        vm.prank(attacker);
        vm.expectRevert(); // AccessControlUnauthorizedAccount
        mr.recoverToken(address(rnd), 100e18);
    }

    // ─────────────────────────────────────────────────────────────
    // 9. MaintenanceReserve emits TokenRecovered
    // ─────────────────────────────────────────────────────────────

    function test_Rescue_UUPS_MaintenanceReserve_EmitsTokenRecovered() public {
        MockUSDCForRescue usdc = new MockUSDCForRescue();
        MaintenanceReserve mr = ProxyDeployer.deployMaintenanceReserve(address(usdc), admin);

        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(mr), 77e18);

        vm.expectEmit(true, false, false, true, address(mr));
        emit TokenRecovered(address(rnd), 77e18);
        mr.recoverToken(address(rnd), 77e18);
    }

    // ─────────────────────────────────────────────────────────────
    // 10. MaintenanceReserve allows LUMINA rescue (LUMINA NOT blacklisted)
    // ─────────────────────────────────────────────────────────────

    function test_Rescue_UUPS_MaintenanceReserve_LUMINA_Recoverable() public {
        MockUSDCForRescue usdc = new MockUSDCForRescue();
        MockLUMINAForRescue lumina = new MockLUMINAForRescue();
        MaintenanceReserve mr = ProxyDeployer.deployMaintenanceReserve(address(usdc), admin);

        lumina.mint(address(mr), 10e18);
        mr.recoverToken(address(lumina), 10e18);

        assertEq(lumina.balanceOf(admin), 10e18);
    }

    // ─────────────────────────────────────────────────────────────
    // 11. Destination semantics — MaintenanceReserve sends to msg.sender
    // ─────────────────────────────────────────────────────────────

    function test_Rescue_UUPS_MaintenanceReserve_DestinationIsMsgSender() public {
        MockUSDCForRescue usdc = new MockUSDCForRescue();
        // Grant admin role to a specific account different from address(this).
        address multisig = makeAddr("multisig");
        MaintenanceReserve mr = ProxyDeployer.deployMaintenanceReserve(address(usdc), multisig);

        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(mr), 5e18);

        vm.prank(multisig);
        mr.recoverToken(address(rnd), 5e18);

        assertEq(rnd.balanceOf(multisig), 5e18, "destination = msg.sender");
        assertEq(rnd.balanceOf(address(this)), 0, "address(this) did not receive");
    }

    // ─────────────────────────────────────────────────────────────
    // 12-16. Contracts WITHOUT recoverToken — token stuck (LOW findings)
    // ─────────────────────────────────────────────────────────────

    function test_Rescue_UUPS_BondVault_NoRecoverFn_TokenStuck() public {
        // Deploy BondVault with stubbed dependencies.
        MockLUMINAForRescue lumina = new MockLUMINAForRescue();
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        BondVault vault = ProxyDeployer.deployBondVault(address(lumina), address(cb), address(new FakeOracle()), admin);

        // Send a random token accidentally.
        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(vault), 42e18);

        // No recoverToken selector on BondVault → call fails.
        (bool ok,) =
            address(vault).call(abi.encodeWithSignature("recoverToken(address,uint256)", address(rnd), uint256(42e18)));
        assertFalse(ok, "BondVault must not expose recoverToken");

        // Token is stuck; balance unchanged.
        assertEq(rnd.balanceOf(address(vault)), 42e18, "stuck");
    }

    function test_Rescue_UUPS_ClaimBond_NoRecoverFn_TokenStuck() public {
        ClaimBond cb = ProxyDeployer.deployClaimBond();

        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(cb), 17e18);

        (bool ok,) =
            address(cb).call(abi.encodeWithSignature("recoverToken(address,uint256)", address(rnd), uint256(17e18)));
        assertFalse(ok);
        assertEq(rnd.balanceOf(address(cb)), 17e18);
    }

    function test_Rescue_UUPS_CoverRouter_NoRecoverFn_TokenStuck() public {
        CoverRouterV2 r = ProxyDeployer.deployCoverRouterV2(makeAddr("u"), makeAddr("p"), makeAddr("b"));

        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(r), 9e18);

        (bool ok,) =
            address(r).call(abi.encodeWithSignature("recoverToken(address,uint256)", address(rnd), uint256(9e18)));
        assertFalse(ok);
        assertEq(rnd.balanceOf(address(r)), 9e18);
    }

    function test_Rescue_UUPS_CEXLiquidityReserve_NoRecoverFn_TokenStuck() public {
        MockLUMINAForRescue lumina = new MockLUMINAForRescue();
        CEXLiquidityReserve cex = ProxyDeployer.deployCEXLiquidityReserve(address(lumina), admin);

        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(cex), 3e18);

        (bool ok,) =
            address(cex).call(abi.encodeWithSignature("recoverToken(address,uint256)", address(rnd), uint256(3e18)));
        assertFalse(ok);
        assertEq(rnd.balanceOf(address(cex)), 3e18);
    }

    function test_Rescue_UUPS_TreasuryVesting_NoRecoverFn_TokenStuck() public {
        MockLUMINAForRescue lumina = new MockLUMINAForRescue();
        TreasuryVesting tv = ProxyDeployer.deployTreasuryVesting(address(lumina));

        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(tv), 4e18);

        (bool ok,) =
            address(tv).call(abi.encodeWithSignature("recoverToken(address,uint256)", address(rnd), uint256(4e18)));
        assertFalse(ok);
        assertEq(rnd.balanceOf(address(tv)), 4e18);
    }

    // ─────────────────────────────────────────────────────────────
    // 17. No receive()/fallback() — plain ETH send reverts
    // ─────────────────────────────────────────────────────────────

    function test_Rescue_UUPS_NoReceive_PlainETHSendReverts() public {
        MockUSDCForRescue usdc = new MockUSDCForRescue();
        MaintenanceReserve mr = ProxyDeployer.deployMaintenanceReserve(address(usdc), admin);

        // .call with value must fail because the contract has no receive/fallback.
        (bool ok,) = address(mr).call{value: 1 ether}("");
        assertFalse(ok, "no receive: plain ETH send must revert");
        assertEq(address(mr).balance, 0);
    }

    // ─────────────────────────────────────────────────────────────
    // 18. ETH force-send via selfdestruct — permanently stuck
    // ─────────────────────────────────────────────────────────────

    function test_Rescue_UUPS_ETH_ForceSend_PermanentlyStuck() public {
        MockUSDCForRescue usdc = new MockUSDCForRescue();
        MaintenanceReserve mr = ProxyDeployer.deployMaintenanceReserve(address(usdc), admin);

        // Prepare 1 ETH on a sender contract and force-send it via selfdestruct.
        vm.deal(address(this), 2 ether);
        EthForceSender sender = new EthForceSender();
        sender.destroy{value: 1 ether}(payable(address(mr)));

        assertEq(address(mr).balance, 1 ether, "ETH force-landed");

        // No recoverETH function exists — confirm via selector absence.
        (bool ok,) = address(mr).call(abi.encodeWithSignature("recoverETH(address,uint256)", admin, uint256(1 ether)));
        assertFalse(ok, "recoverETH must not exist");
        assertEq(address(mr).balance, 1 ether, "ETH still stuck");
    }

    // ─────────────────────────────────────────────────────────────
    // 19. Malicious-admin drain protection — TWAPBurner USDC
    // ─────────────────────────────────────────────────────────────

    function test_Rescue_UUPS_TWAPBurner_MaliciousOwner_CannotDrainUSDC() public {
        MockUSDCForRescue usdc = new MockUSDCForRescue();
        MockLUMINAForRescue lumina = new MockLUMINAForRescue();
        TWAPBurner tb = ProxyDeployer.deployTWAPBurner(address(usdc), address(lumina), address(new InertDexRouter()));

        usdc.mint(address(tb), 1_000_000e18);
        uint256 tbBefore = usdc.balanceOf(address(tb));

        // Owner is this contract. Try every plausible drain path.
        vm.expectRevert("Cannot recover USDC");
        tb.recoverToken(address(usdc), 1e18);

        assertEq(usdc.balanceOf(address(tb)), tbBefore, "no USDC drained");
    }

    // ─────────────────────────────────────────────────────────────
    // 20. Malicious-admin drain protection — TWAPBurner LUMINA
    // ─────────────────────────────────────────────────────────────

    function test_Rescue_UUPS_TWAPBurner_MaliciousOwner_CannotDrainLUMINA() public {
        MockUSDCForRescue usdc = new MockUSDCForRescue();
        MockLUMINAForRescue lumina = new MockLUMINAForRescue();
        TWAPBurner tb = ProxyDeployer.deployTWAPBurner(address(usdc), address(lumina), address(new InertDexRouter()));

        lumina.mint(address(tb), 9_000_000e18);
        uint256 tbBefore = lumina.balanceOf(address(tb));

        vm.expectRevert("Cannot recover LUMINA");
        tb.recoverToken(address(lumina), 1e18);

        assertEq(lumina.balanceOf(address(tb)), tbBefore, "no LUMINA drained");
    }

    // ─────────────────────────────────────────────────────────────
    // 21. Multiple recoveries sequentially
    // ─────────────────────────────────────────────────────────────

    function test_Rescue_UUPS_MaintenanceReserve_MultipleRecoveries_Sequential() public {
        MockUSDCForRescue usdc = new MockUSDCForRescue();
        MaintenanceReserve mr = ProxyDeployer.deployMaintenanceReserve(address(usdc), admin);

        MockERC20 a = new MockERC20("A", "A");
        MockERC20 b = new MockERC20("B", "B");
        MockERC20 c = new MockERC20("C", "C");

        a.mint(address(mr), 1e18);
        b.mint(address(mr), 2e18);
        c.mint(address(mr), 3e18);

        mr.recoverToken(address(a), 1e18);
        mr.recoverToken(address(b), 2e18);
        mr.recoverToken(address(c), 3e18);

        assertEq(a.balanceOf(admin), 1e18);
        assertEq(b.balanceOf(admin), 2e18);
        assertEq(c.balanceOf(admin), 3e18);
    }

    // ─────────────────────────────────────────────────────────────
    // 22. Non-core ERC-1155 sent via safeTransferFrom to Vault — stuck
    // ─────────────────────────────────────────────────────────────

    function test_Rescue_UUPS_BondVault_NoERC1155Rescue_Stuck() public {
        MockLUMINAForRescue lumina = new MockLUMINAForRescue();
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        BondVault vault = ProxyDeployer.deployBondVault(address(lumina), address(cb), address(new FakeOracle()), admin);

        // recoverToken uses IERC20 signature — cannot rescue ERC-1155 even if it had the function.
        // Just confirm the IERC20 selector is absent (symmetry check).
        (bool ok,) = address(vault)
            .call(
                abi.encodeWithSignature("recoverERC1155(address,uint256,uint256)", address(cb), uint256(1), uint256(1))
            );
        assertFalse(ok, "no recoverERC1155 surface on BondVault");
    }

    // ─────────────────────────────────────────────────────────────
    // 23. Inventory completeness — assert exactly 2 contracts expose recoverToken
    // ─────────────────────────────────────────────────────────────

    function test_Rescue_UUPS_InventoryMatrix_Matches() public {
        // Proxies to check — all must NOT expose recoverToken except TWAPBurner/MaintenanceReserve.
        MockUSDCForRescue usdc = new MockUSDCForRescue();
        MockLUMINAForRescue lumina = new MockLUMINAForRescue();

        address tb =
            address(ProxyDeployer.deployTWAPBurner(address(usdc), address(lumina), address(new InertDexRouter())));
        address mr = address(ProxyDeployer.deployMaintenanceReserve(address(usdc), admin));
        address cb = address(ProxyDeployer.deployClaimBond());
        address cex = address(ProxyDeployer.deployCEXLiquidityReserve(address(lumina), admin));
        address tv = address(ProxyDeployer.deployTreasuryVesting(address(lumina)));

        // Selector: recoverToken(address,uint256)
        bytes4 sel = bytes4(keccak256("recoverToken(address,uint256)"));

        // Confirm via low-level calldata probe — TB/MR reject (due to USDC/LUMINA blacklist),
        // CB/CEX/TV fail because the function does not exist.
        MockERC20 rnd = new MockERC20("R", "R");

        // TB — function exists; call with random token succeeds (non-blacklisted).
        rnd.mint(tb, 1e18);
        (bool okTb,) = tb.call(abi.encodeWithSelector(sel, address(rnd), uint256(1e18)));
        assertTrue(okTb, "TWAPBurner.recoverToken should exist");

        // MR — function exists; call with random token succeeds.
        rnd.mint(mr, 1e18);
        (bool okMr,) = mr.call(abi.encodeWithSelector(sel, address(rnd), uint256(1e18)));
        assertTrue(okMr, "MaintenanceReserve.recoverToken should exist");

        // CB — no such selector.
        (bool okCb,) = cb.call(abi.encodeWithSelector(sel, address(rnd), uint256(1)));
        assertFalse(okCb, "ClaimBond must not expose recoverToken");

        // CEX — no such selector.
        (bool okCex,) = cex.call(abi.encodeWithSelector(sel, address(rnd), uint256(1)));
        assertFalse(okCex, "CEXLiquidityReserve must not expose recoverToken");

        // TV — no such selector.
        (bool okTv,) = tv.call(abi.encodeWithSelector(sel, address(rnd), uint256(1)));
        assertFalse(okTv, "TreasuryVesting must not expose recoverToken");
    }

    // ─────────────────────────────────────────────────────────────
    // 24. Zero-address destination — MaintenanceReserve sends to msg.sender
    //     so zero dest is impossible by design; confirm no admin-chosen dst path exists.
    // ─────────────────────────────────────────────────────────────

    function test_Rescue_UUPS_Destination_HardcodedNotAdminChosen() public {
        MockUSDCForRescue usdc = new MockUSDCForRescue();
        MaintenanceReserve mr = ProxyDeployer.deployMaintenanceReserve(address(usdc), admin);

        // There is no 3-arg recoverToken(address,uint256,address) overload.
        bytes4 threeArg = bytes4(keccak256("recoverToken(address,uint256,address)"));
        (bool ok,) = address(mr).call(abi.encodeWithSelector(threeArg, address(0), uint256(0), address(0)));
        assertFalse(ok, "3-arg overload with admin-chosen dst must not exist");
    }

    // ─────────────────────────────────────────────────────────────
    // 25. Recovery preserves non-recovered balances
    // ─────────────────────────────────────────────────────────────

    function test_Rescue_UUPS_PartialRecovery_PreservesOtherBalances() public {
        MockUSDCForRescue usdc = new MockUSDCForRescue();
        MaintenanceReserve mr = ProxyDeployer.deployMaintenanceReserve(address(usdc), admin);

        MockERC20 a = new MockERC20("A", "A");
        MockERC20 b = new MockERC20("B", "B");
        a.mint(address(mr), 100e18);
        b.mint(address(mr), 200e18);

        // Recover only `a`.
        mr.recoverToken(address(a), 30e18);

        assertEq(a.balanceOf(admin), 30e18);
        assertEq(a.balanceOf(address(mr)), 70e18, "A remainder preserved");
        assertEq(b.balanceOf(address(mr)), 200e18, "B untouched");
    }
}

// ─────────────────────────────────────────────────────────────────────────
// STUB ORACLE — BondVault initialize needs priceOracle != 0
// ─────────────────────────────────────────────────────────────────────────

contract FakeOracle {
    function getLuminaPrice() external pure returns (uint256) {
        return 0.036e18;
    }
}
