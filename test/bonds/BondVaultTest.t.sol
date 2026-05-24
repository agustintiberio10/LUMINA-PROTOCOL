// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../src/token/LuminaTokenV2.sol";
import "../../src/bonds/ClaimBond.sol";
import "../../src/bonds/BondVault.sol";

contract MockPriceOracle {
    uint256 public price = 0.036e18;

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }

    function setPrice(uint256 p) external {
        price = p;
    }
}

contract BondVaultTest is Test {
    LuminaTokenV2 token;
    ClaimBond claimBond;
    BondVault vault;
    MockPriceOracle oracle;

    address lbp = makeAddr("lbp");
    address founder = makeAddr("founder");
    address treasury = makeAddr("treasury");
    address user = makeAddr("user");

    function setUp() public {
        vm.chainId(8453);
        // [SR3] Warp past ClaimBond.BASE_TIMESTAMP (Jan 1 2026 UTC = 1767225600)
        vm.warp(1767225600 + 30 days);

        oracle = new MockPriceOracle();

        // Deploy ClaimBond via proxy
        ClaimBond claimBondImpl = new ClaimBond();
        ERC1967Proxy claimBondProxy =
            new ERC1967Proxy(address(claimBondImpl), abi.encodeWithSelector(ClaimBond.initialize.selector));
        claimBond = ClaimBond(address(claimBondProxy));

        // Deploy LuminaTokenV2 via proxy
        LuminaTokenV2 tokenImpl = new LuminaTokenV2();
        ERC1967Proxy tokenProxy = new ERC1967Proxy(
            address(tokenImpl),
            abi.encodeWithSelector(
                LuminaTokenV2.initialize.selector, makeAddr("tempVault"), makeAddr("cex"), founder, lbp, treasury
            )
        );
        token = LuminaTokenV2(address(tokenProxy));

        // Deploy BondVault via proxy
        BondVault vaultImpl = new BondVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(
            address(vaultImpl),
            abi.encodeWithSelector(
                BondVault.initialize.selector,
                address(token),
                address(claimBond),
                address(oracle),
                address(this) // test acts as PolicyManager
            )
        );
        vault = BondVault(address(vaultProxy));

        claimBond.setBondVault(address(vault));
        deal(address(token), address(vault), 70_000_000 * 1e18);
    }

    function test_initial_state() public view {
        assertEq(vault.totalCommittedUSD(), 0);
        assertEq(token.balanceOf(address(vault)), 70_000_000 * 1e18);
    }

    function test_issueBond() public {
        vault.issueBond(user, 800);
        // [V3/SR2] totalCommittedUSD is now 18-dec USD-wei: 800 * 1e18
        assertEq(vault.totalCommittedUSD(), 800 * 1e18);
        // verify bond was minted to user
        uint256 epoch = _currentEpochPlus24();
        assertEq(claimBond.balanceOf(user, epoch), 800);
    }

    function test_issueBond_only_policyManager() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert("Only PolicyManager");
        vault.issueBond(user, 800);
    }

    function test_capacity_check() public view {
        // [V3/SR2] availableCapacityUSD returns INTEGER dollars (post-fix).
        uint256 cap = vault.availableCapacityUSD();
        // 82M * $0.036 = $2.952M, 50% = $1.476M
        assertGt(cap, 1_200_000);
        assertLt(cap, 1_300_000);
    }

    function test_exceeds_capacity_reverts() public {
        uint256 cap = vault.availableCapacityUSD();
        vm.expectRevert("Exceeds capacity");
        vault.issueBond(user, cap + 1);
    }

    function test_redeemBond_price_up() public {
        vault.issueBond(user, 800);
        uint256 epoch = _currentEpochPlus24();
        vm.warp(claimBond.maturityDate(epoch) + 1);

        // $LUMINA went UP to $0.50 → agent gets FEWER tokens
        oracle.setPrice(0.5e18);
        uint256 expected = (800 * 1e36) / 0.5e18; // 1,600 * 1e18 wei = 1,600 LUMINA

        vm.prank(user);
        vault.redeemBond(epoch, 800);

        assertEq(token.balanceOf(user), expected);
        assertEq(vault.totalCommittedUSD(), 0);
    }

    function test_redeemBond_price_down() public {
        vault.issueBond(user, 800);
        uint256 epoch = _currentEpochPlus24();
        vm.warp(claimBond.maturityDate(epoch) + 1);

        // $LUMINA went DOWN to $0.01 → agent gets MORE tokens
        oracle.setPrice(0.01e18);
        uint256 expected = (800 * 1e36) / 0.01e18; // 80,000 * 1e18 wei

        vm.prank(user);
        vault.redeemBond(epoch, 800);

        assertEq(token.balanceOf(user), expected);
    }

    function test_partial_redeem() public {
        vault.issueBond(user, 800);
        uint256 epoch = _currentEpochPlus24();
        vm.warp(claimBond.maturityDate(epoch) + 1);
        oracle.setPrice(0.5e18);

        vm.prank(user);
        vault.redeemBond(epoch, 300);

        assertEq(claimBond.balanceOf(user, epoch), 500);
        assertEq(vault.totalCommittedUSD(), 500 * 1e18);
    }

    function test_cannot_redeem_before_maturity() public {
        vault.issueBond(user, 800);
        uint256 epoch = _currentEpochPlus24();
        vm.prank(user);
        vm.expectRevert("Not matured");
        vault.redeemBond(epoch, 800);
    }

    function test_redemption_fails_below_min_redeem_price() public {
        vault.issueBond(user, 800);
        uint256 epoch = _currentEpochPlus24();

        vm.warp(claimBond.maturityDate(epoch) + 1);
        oracle.setPrice(0.0005e18); // below MIN_REDEEM_PRICE

        vm.prank(user);
        vm.expectRevert("Price too low");
        vault.redeemBond(epoch, 800);

        oracle.setPrice(0.05e18);
        vm.prank(user);
        vault.redeemBond(epoch, 800);
    }

    function test_previewRedemption() public view {
        uint256 preview = vault.previewRedemption(800);
        uint256 usd = 800;
        uint256 price = 0.036e18;
        uint256 expected = (usd * 1e36) / price;
        assertEq(preview, expected);
    }

    function _currentEpochPlus24() internal view returns (uint256) {
        uint256 matTs = block.timestamp + 730 days;
        uint256 BASE_TS = 1767225600;
        uint256 monthsFromBase = (matTs - BASE_TS) / 2629746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 month = 1 + monthsFromBase % 12;
        return year * 100 + month;
    }

    // ═══════ setPolicyManager tests ═══════

    function test_SetPolicyManager_OneShot() public {
        // Deploy BondVault via proxy with policyManager = address(0)
        BondVault impl = new BondVault();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                BondVault.initialize.selector, address(token), address(claimBond), address(oracle), address(0)
            )
        );
        BondVault v = BondVault(address(proxy));

        address pm = makeAddr("policyManager");
        assertEq(v.policyManager(), address(0));

        v.setPolicyManager(pm);
        assertEq(v.policyManager(), pm);
    }

    function test_RevertIf_SetPolicyManagerTwice() public {
        BondVault impl = new BondVault();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                BondVault.initialize.selector, address(token), address(claimBond), address(oracle), address(0)
            )
        );
        BondVault v = BondVault(address(proxy));

        address pm = makeAddr("policyManager");
        v.setPolicyManager(pm);

        vm.expectRevert("PolicyManager already set");
        v.setPolicyManager(makeAddr("anotherPM"));
    }

    function test_RevertIf_SetPolicyManagerZero() public {
        BondVault impl = new BondVault();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                BondVault.initialize.selector, address(token), address(claimBond), address(oracle), address(0)
            )
        );
        BondVault v = BondVault(address(proxy));

        vm.expectRevert("Zero address");
        v.setPolicyManager(address(0));
    }

    function test_RevertIf_SetPolicyManagerUnauthorized() public {
        BondVault impl = new BondVault();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                BondVault.initialize.selector, address(token), address(claimBond), address(oracle), address(0)
            )
        );
        BondVault v = BondVault(address(proxy));

        address pm = makeAddr("policyManager");
        address attacker = makeAddr("attacker");

        // [F-16] setPolicyManager is now gated on DEFAULT_ADMIN_ROLE (was the
        // deployer EOA); a non-admin reverts with the AccessControl error.
        vm.prank(attacker);
        vm.expectRevert();
        v.setPolicyManager(pm);
    }

    function test_SetPolicyManager_ConstructorWithAddress() public {
        address pm = makeAddr("policyManager");

        BondVault impl = new BondVault();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                BondVault.initialize.selector, address(token), address(claimBond), address(oracle), pm
            )
        );
        BondVault v = BondVault(address(proxy));

        assertEq(v.policyManager(), pm);

        vm.expectRevert("PolicyManager already set");
        v.setPolicyManager(makeAddr("anotherPM"));
    }

    // ═══════ setAuthorizedCaller (AUTHORIZED_CALLER_ADMIN_ROLE) ═══════

    function test_SetAuthorizedCaller_ByAdmin_Success() public {
        address newCaller = makeAddr("newCaller");
        vault.setAuthorizedCaller(newCaller, true);
        assertTrue(vault.authorizedCallers(newCaller));
    }

    function test_SetAuthorizedCaller_RevertIf_NotAdmin() public {
        address newCaller = makeAddr("newCaller");
        address notAdmin = makeAddr("notAdmin");

        vm.prank(notAdmin);
        vm.expectRevert();
        vault.setAuthorizedCaller(newCaller, true);
    }

    function test_SetAuthorizedCaller_CanRevoke() public {
        address caller = makeAddr("caller");

        vault.setAuthorizedCaller(caller, true);
        assertTrue(vault.authorizedCallers(caller));

        vault.setAuthorizedCaller(caller, false);
        assertFalse(vault.authorizedCallers(caller));
    }

    function test_SetAuthorizedCaller_RevertIf_ZeroAddress() public {
        vm.expectRevert("Zero address");
        vault.setAuthorizedCaller(address(0), true);
    }

    function test_cannot_initialize_twice() public {
        vm.expectRevert();
        vault.initialize(address(token), address(claimBond), address(oracle), address(this));
    }
}
