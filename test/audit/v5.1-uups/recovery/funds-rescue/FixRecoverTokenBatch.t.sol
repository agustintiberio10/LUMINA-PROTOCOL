// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ProxyDeployer} from "../../../../helpers/ProxyDeployer.sol";

import {TWAPBurner} from "../../../../../src/core/TWAPBurner.sol";
import {BondVault} from "../../../../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../../../../src/bonds/ClaimBond.sol";
import {CEXLiquidityReserve} from "../../../../../src/treasury/CEXLiquidityReserve.sol";
import {TreasuryVesting} from "../../../../../src/token/TreasuryVesting.sol";
import {CoverRouterV2} from "../../../../../src/core/CoverRouterV2.sol";
import {LuminaBondMarketplace} from "../../../../../src/marketplace/LuminaBondMarketplace.sol";
import {BuybackEngine} from "../../../../../src/marketplace/BuybackEngine.sol";
import {AdaptiveFeeDistributor} from "../../../../../src/core/AdaptiveFeeDistributor.sol";
import {SolvencyOracle} from "../../../../../src/oracles/SolvencyOracle.sol";
import {CapacityOracle} from "../../../../../src/oracles/CapacityOracle.sol";
import {IDexRouter} from "../../../../../src/interfaces/IDexRouter.sol";

// ─────────────────────────────────────────────────────────────────────────
// MINIMAL MOCKS
// ─────────────────────────────────────────────────────────────────────────

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

contract MockERC1155 is IERC1155 {
    mapping(address => mapping(uint256 => uint256)) public bal;
    mapping(address => mapping(address => bool)) public opApproved;

    function mint(address to, uint256 id, uint256 amount) external {
        bal[to][id] += amount;
    }

    function balanceOf(address account, uint256 id) external view override returns (uint256) {
        return bal[account][id];
    }

    function balanceOfBatch(address[] calldata accounts, uint256[] calldata ids)
        external
        view
        override
        returns (uint256[] memory out)
    {
        out = new uint256[](accounts.length);
        for (uint256 i; i < accounts.length; i++) {
            out[i] = bal[accounts[i]][ids[i]];
        }
    }

    function setApprovalForAll(address operator, bool approved) external override {
        opApproved[msg.sender][operator] = approved;
    }

    function isApprovedForAll(address account, address operator) external view override returns (bool) {
        return opApproved[account][operator];
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata) external override {
        bal[from][id] -= amount;
        bal[to][id] += amount;
    }

    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata
    ) external override {
        for (uint256 i; i < ids.length; i++) {
            bal[from][ids[i]] -= amounts[i];
            bal[to][ids[i]] += amounts[i];
        }
    }

    function supportsInterface(bytes4) external pure override returns (bool) {
        return true;
    }
}

contract InertDexRouter is IDexRouter {
    function swap(address, address, uint256, uint256) external pure override returns (uint256) {
        return 0;
    }

    function getQuote(address, address, uint256) external pure override returns (uint256) {
        return 0;
    }
}

contract FakeOracle {
    function getLuminaPrice() external pure returns (uint256) {
        return 0.036e18;
    }
}

// ─────────────────────────────────────────────────────────────────────────
// TEST CONTRACT
// ─────────────────────────────────────────────────────────────────────────

contract FixRecoverTokenBatchTest is Test {
    // Event signatures re-declared for vm.expectEmit.
    event TokenRecovered(address indexed token, uint256 amount, address indexed to);

    address internal admin = address(this);
    address internal attacker = makeAddr("attacker");
    address internal rescueDest = makeAddr("rescueDest");

    // ═══════════════════════════════════════════════════════════
    // 1. BondVault (blacklist: LUMINA + ClaimBond)
    // ═══════════════════════════════════════════════════════════

    function _deployBondVault() internal returns (BondVault vault, MockERC20 lumina, ClaimBond cb) {
        lumina = new MockERC20("LUM", "LUM");
        cb = ProxyDeployer.deployClaimBond();
        FakeOracle oracle = new FakeOracle();
        vault = ProxyDeployer.deployBondVault(address(lumina), address(cb), address(oracle), admin);
    }

    function test_Recover_BondVault_RandomToken_Works() public {
        (BondVault vault,,) = _deployBondVault();
        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(vault), 1000e18);

        vault.recoverToken(address(rnd), 1000e18, rescueDest);

        assertEq(rnd.balanceOf(rescueDest), 1000e18);
        assertEq(rnd.balanceOf(address(vault)), 0);
    }

    function test_Recover_BondVault_LUMINA_Blocked() public {
        (BondVault vault, MockERC20 lumina,) = _deployBondVault();
        lumina.mint(address(vault), 100e18);
        vm.expectRevert(abi.encodeWithSelector(BondVault.CoreTokenProtected.selector, address(lumina)));
        vault.recoverToken(address(lumina), 1e18, rescueDest);
    }

    function test_Recover_BondVault_ClaimBond_Blocked_ERC20Path() public {
        (BondVault vault,, ClaimBond cb) = _deployBondVault();
        vm.expectRevert(abi.encodeWithSelector(BondVault.CoreTokenProtected.selector, address(cb)));
        vault.recoverToken(address(cb), 1, rescueDest);
    }

    function test_Recover_BondVault_ERC1155_Random_Works() public {
        (BondVault vault,,) = _deployBondVault();
        MockERC1155 nft = new MockERC1155();
        nft.mint(address(vault), 42, 7);

        vault.recoverERC1155(address(nft), 42, 7, rescueDest);
        assertEq(nft.balanceOf(rescueDest, 42), 7);
    }

    function test_Recover_BondVault_ERC1155_ClaimBond_Blocked() public {
        (BondVault vault,, ClaimBond cb) = _deployBondVault();
        vm.expectRevert(abi.encodeWithSelector(BondVault.CoreTokenProtected.selector, address(cb)));
        vault.recoverERC1155(address(cb), 202904, 1, rescueDest);
    }

    function test_Recover_BondVault_NonAdmin_Reverts() public {
        (BondVault vault,,) = _deployBondVault();
        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(vault), 10e18);
        vm.prank(attacker);
        vm.expectRevert();
        vault.recoverToken(address(rnd), 10e18, attacker);
    }

    function test_Recover_BondVault_ZeroAmount_Reverts() public {
        (BondVault vault,,) = _deployBondVault();
        MockERC20 rnd = new MockERC20("R", "R");
        vm.expectRevert(BondVault.RecoverAmountZero.selector);
        vault.recoverToken(address(rnd), 0, rescueDest);
    }

    function test_Recover_BondVault_ZeroTo_Reverts() public {
        (BondVault vault,,) = _deployBondVault();
        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(vault), 1e18);
        vm.expectRevert(BondVault.ZeroAddressNotAllowed.selector);
        vault.recoverToken(address(rnd), 1e18, address(0));
    }

    function test_Recover_BondVault_EventEmitted() public {
        (BondVault vault,,) = _deployBondVault();
        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(vault), 5e18);

        vm.expectEmit(true, false, true, true, address(vault));
        emit TokenRecovered(address(rnd), 5e18, rescueDest);
        vault.recoverToken(address(rnd), 5e18, rescueDest);
    }

    // ═══════════════════════════════════════════════════════════
    // 2. CEXLiquidityReserve (blacklist: LUMINA)
    // ═══════════════════════════════════════════════════════════

    function _deployCEX() internal returns (CEXLiquidityReserve cex, MockERC20 lumina) {
        lumina = new MockERC20("LUM", "LUM");
        cex = ProxyDeployer.deployCEXLiquidityReserve(address(lumina), admin);
    }

    function test_Recover_CEX_RandomToken_Works() public {
        (CEXLiquidityReserve cex,) = _deployCEX();
        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(cex), 200e18);

        cex.recoverToken(address(rnd), 200e18, rescueDest);
        assertEq(rnd.balanceOf(rescueDest), 200e18);
    }

    function test_Recover_CEX_LUMINA_Blocked() public {
        (CEXLiquidityReserve cex, MockERC20 lumina) = _deployCEX();
        vm.expectRevert(abi.encodeWithSelector(CEXLiquidityReserve.CoreTokenProtected.selector, address(lumina)));
        cex.recoverToken(address(lumina), 1, rescueDest);
    }

    function test_Recover_CEX_NonAdmin_Reverts() public {
        (CEXLiquidityReserve cex,) = _deployCEX();
        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(cex), 1e18);
        vm.prank(attacker);
        vm.expectRevert();
        cex.recoverToken(address(rnd), 1e18, attacker);
    }

    function test_Recover_CEX_ZeroAmount_Reverts() public {
        (CEXLiquidityReserve cex,) = _deployCEX();
        MockERC20 rnd = new MockERC20("R", "R");
        vm.expectRevert(CEXLiquidityReserve.RecoverAmountZero.selector);
        cex.recoverToken(address(rnd), 0, rescueDest);
    }

    function test_Recover_CEX_EventEmitted() public {
        (CEXLiquidityReserve cex,) = _deployCEX();
        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(cex), 3e18);
        vm.expectEmit(true, false, true, true, address(cex));
        emit TokenRecovered(address(rnd), 3e18, rescueDest);
        cex.recoverToken(address(rnd), 3e18, rescueDest);
    }

    // ═══════════════════════════════════════════════════════════
    // 3. TreasuryVesting (blacklist: LUMINA; owner-gated)
    // ═══════════════════════════════════════════════════════════

    function _deployTV() internal returns (TreasuryVesting tv, MockERC20 lumina) {
        lumina = new MockERC20("LUM", "LUM");
        tv = ProxyDeployer.deployTreasuryVesting(address(lumina));
    }

    function test_Recover_TV_RandomToken_Works() public {
        (TreasuryVesting tv,) = _deployTV();
        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(tv), 77e18);

        tv.recoverToken(address(rnd), 77e18, rescueDest);
        assertEq(rnd.balanceOf(rescueDest), 77e18);
    }

    function test_Recover_TV_LUMINA_Blocked() public {
        (TreasuryVesting tv, MockERC20 lumina) = _deployTV();
        vm.expectRevert(abi.encodeWithSelector(TreasuryVesting.CoreTokenProtected.selector, address(lumina)));
        tv.recoverToken(address(lumina), 1, rescueDest);
    }

    function test_Recover_TV_NonOwner_Reverts() public {
        (TreasuryVesting tv,) = _deployTV();
        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(tv), 1e18);
        vm.prank(attacker);
        vm.expectRevert();
        tv.recoverToken(address(rnd), 1e18, attacker);
    }

    function test_Recover_TV_ZeroAmount_Reverts() public {
        (TreasuryVesting tv,) = _deployTV();
        MockERC20 rnd = new MockERC20("R", "R");
        vm.expectRevert(TreasuryVesting.RecoverAmountZero.selector);
        tv.recoverToken(address(rnd), 0, rescueDest);
    }

    function test_Recover_TV_EventEmitted() public {
        (TreasuryVesting tv,) = _deployTV();
        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(tv), 11e18);
        vm.expectEmit(true, false, true, true, address(tv));
        emit TokenRecovered(address(rnd), 11e18, rescueDest);
        tv.recoverToken(address(rnd), 11e18, rescueDest);
    }

    // ═══════════════════════════════════════════════════════════
    // 4. CoverRouterV2 (blacklist: USDC; owner-gated)
    // ═══════════════════════════════════════════════════════════

    function _deployCR() internal returns (CoverRouterV2 router, MockERC20 usdc) {
        usdc = new MockERC20("USDC", "USDC");
        router = ProxyDeployer.deployCoverRouterV2(address(usdc), makeAddr("pm"), makeAddr("burner"));
    }

    function test_Recover_CR_RandomToken_Works() public {
        (CoverRouterV2 router,) = _deployCR();
        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(router), 500e18);

        router.recoverToken(address(rnd), 500e18, rescueDest);
        assertEq(rnd.balanceOf(rescueDest), 500e18);
    }

    function test_Recover_CR_USDC_Blocked() public {
        (CoverRouterV2 router, MockERC20 usdc) = _deployCR();
        vm.expectRevert(abi.encodeWithSelector(CoverRouterV2.CoreTokenProtected.selector, address(usdc)));
        router.recoverToken(address(usdc), 1, rescueDest);
    }

    function test_Recover_CR_NonOwner_Reverts() public {
        (CoverRouterV2 router,) = _deployCR();
        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(router), 1e18);
        vm.prank(attacker);
        vm.expectRevert();
        router.recoverToken(address(rnd), 1e18, attacker);
    }

    function test_Recover_CR_ZeroTo_Reverts() public {
        (CoverRouterV2 router,) = _deployCR();
        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(router), 1e18);
        vm.expectRevert(CoverRouterV2.ZeroAddressNotAllowed.selector);
        router.recoverToken(address(rnd), 1e18, address(0));
    }

    function test_Recover_CR_EventEmitted() public {
        (CoverRouterV2 router,) = _deployCR();
        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(router), 9e18);
        vm.expectEmit(true, false, true, true, address(router));
        emit TokenRecovered(address(rnd), 9e18, rescueDest);
        router.recoverToken(address(rnd), 9e18, rescueDest);
    }

    // ═══════════════════════════════════════════════════════════
    // 5. LuminaBondMarketplace (blacklist: USDC + ClaimBond)
    // ═══════════════════════════════════════════════════════════

    function _deployMP() internal returns (LuminaBondMarketplace mp, MockERC20 usdc, ClaimBond cb) {
        usdc = new MockERC20("USDC", "USDC");
        cb = ProxyDeployer.deployClaimBond();
        mp = ProxyDeployer.deployLuminaBondMarketplace(address(cb), address(usdc), makeAddr("burner"), admin);
    }

    function test_Recover_MP_RandomToken_Works() public {
        (LuminaBondMarketplace mp,,) = _deployMP();
        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(mp), 333e18);

        mp.recoverToken(address(rnd), 333e18, rescueDest);
        assertEq(rnd.balanceOf(rescueDest), 333e18);
    }

    function test_Recover_MP_USDC_Blocked() public {
        (LuminaBondMarketplace mp, MockERC20 usdc,) = _deployMP();
        vm.expectRevert(abi.encodeWithSelector(LuminaBondMarketplace.CoreTokenProtected.selector, address(usdc)));
        mp.recoverToken(address(usdc), 1, rescueDest);
    }

    function test_Recover_MP_ClaimBond_ERC20Path_Blocked() public {
        (LuminaBondMarketplace mp,, ClaimBond cb) = _deployMP();
        vm.expectRevert(abi.encodeWithSelector(LuminaBondMarketplace.CoreTokenProtected.selector, address(cb)));
        mp.recoverToken(address(cb), 1, rescueDest);
    }

    function test_Recover_MP_ERC1155_RandomWorks() public {
        (LuminaBondMarketplace mp,,) = _deployMP();
        MockERC1155 nft = new MockERC1155();
        nft.mint(address(mp), 1, 10);

        mp.recoverERC1155(address(nft), 1, 10, rescueDest);
        assertEq(nft.balanceOf(rescueDest, 1), 10);
    }

    function test_Recover_MP_ERC1155_ClaimBond_Blocked() public {
        (LuminaBondMarketplace mp,, ClaimBond cb) = _deployMP();
        vm.expectRevert(abi.encodeWithSelector(LuminaBondMarketplace.CoreTokenProtected.selector, address(cb)));
        mp.recoverERC1155(address(cb), 202904, 1, rescueDest);
    }

    function test_Recover_MP_NonAdmin_Reverts() public {
        (LuminaBondMarketplace mp,,) = _deployMP();
        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(mp), 1e18);
        vm.prank(attacker);
        vm.expectRevert();
        mp.recoverToken(address(rnd), 1e18, attacker);
    }

    function test_Recover_MP_EventEmitted() public {
        (LuminaBondMarketplace mp,,) = _deployMP();
        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(mp), 4e18);
        vm.expectEmit(true, false, true, true, address(mp));
        emit TokenRecovered(address(rnd), 4e18, rescueDest);
        mp.recoverToken(address(rnd), 4e18, rescueDest);
    }

    // ═══════════════════════════════════════════════════════════
    // 6. BuybackEngine (blacklist: USDC + ClaimBond)
    // ═══════════════════════════════════════════════════════════

    function _deployBuyback() internal returns (BuybackEngine be, MockERC20 usdc, ClaimBond cb) {
        usdc = new MockERC20("USDC", "USDC");
        cb = ProxyDeployer.deployClaimBond();
        MockERC20 lumina = new MockERC20("LUM", "LUM");
        FakeOracle oracle = new FakeOracle();
        BondVault vault = ProxyDeployer.deployBondVault(address(lumina), address(cb), address(oracle), admin);
        // SolvencyOracle.init only stores capacityOracle; no call during init.
        // Pass the FakeOracle proxy (has a real contract body — satisfies require checks downstream).
        SolvencyOracle sol = ProxyDeployer.deploySolvencyOracle(address(vault), address(oracle), admin);

        // BuybackEngine.init stores capacityOracle pointer; does not call it.
        // Pass FakeOracle (contract, returns price) so any later calls don't crash.
        address fakeMarketplace = address(new FakeMarketplace());
        be = ProxyDeployer.deployBuybackEngine(
            address(cb), address(vault), address(sol), address(oracle), fakeMarketplace, address(usdc), admin
        );
    }

    function test_Recover_Buyback_RandomToken_Works() public {
        (BuybackEngine be,,) = _deployBuyback();
        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(be), 13e18);

        be.recoverToken(address(rnd), 13e18, rescueDest);
        assertEq(rnd.balanceOf(rescueDest), 13e18);
    }

    function test_Recover_Buyback_USDC_Blocked() public {
        (BuybackEngine be, MockERC20 usdc,) = _deployBuyback();
        vm.expectRevert(abi.encodeWithSelector(BuybackEngine.CoreTokenProtected.selector, address(usdc)));
        be.recoverToken(address(usdc), 1, rescueDest);
    }

    function test_Recover_Buyback_ClaimBond_Blocked() public {
        (BuybackEngine be,, ClaimBond cb) = _deployBuyback();
        vm.expectRevert(abi.encodeWithSelector(BuybackEngine.CoreTokenProtected.selector, address(cb)));
        be.recoverERC1155(address(cb), 202904, 1, rescueDest);
    }

    function test_Recover_Buyback_ERC1155_Random_Works() public {
        (BuybackEngine be,,) = _deployBuyback();
        MockERC1155 nft = new MockERC1155();
        nft.mint(address(be), 55, 3);
        be.recoverERC1155(address(nft), 55, 3, rescueDest);
        assertEq(nft.balanceOf(rescueDest, 55), 3);
    }

    function test_Recover_Buyback_NonAdmin_Reverts() public {
        (BuybackEngine be,,) = _deployBuyback();
        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(be), 1e18);
        vm.prank(attacker);
        vm.expectRevert();
        be.recoverToken(address(rnd), 1e18, attacker);
    }

    function test_Recover_Buyback_EventEmitted() public {
        (BuybackEngine be,,) = _deployBuyback();
        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(be), 6e18);
        vm.expectEmit(true, false, true, true, address(be));
        emit TokenRecovered(address(rnd), 6e18, rescueDest);
        be.recoverToken(address(rnd), 6e18, rescueDest);
    }

    // ═══════════════════════════════════════════════════════════
    // 7. AdaptiveFeeDistributor (no blacklist by design)
    // ═══════════════════════════════════════════════════════════

    function _deployAdaptive() internal returns (AdaptiveFeeDistributor adp) {
        // AdaptiveFeeDistributor only needs a valid SolvencyOracle address.
        // SolvencyOracle needs a valid BondVault + capacityOracle (FakeOracle suffices).
        MockERC20 lumina = new MockERC20("LUM", "LUM");
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        FakeOracle fo = new FakeOracle();
        BondVault vault = ProxyDeployer.deployBondVault(address(lumina), address(cb), address(fo), admin);
        SolvencyOracle sol = ProxyDeployer.deploySolvencyOracle(address(vault), address(fo), admin);
        adp = ProxyDeployer.deployAdaptiveFeeDistributor(address(sol));
    }

    function test_Recover_Adaptive_AnyToken_Works() public {
        AdaptiveFeeDistributor adp = _deployAdaptive();
        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(adp), 22e18);

        adp.recoverToken(address(rnd), 22e18, rescueDest);
        assertEq(rnd.balanceOf(rescueDest), 22e18);
    }

    function test_Recover_Adaptive_NonOwner_Reverts() public {
        AdaptiveFeeDistributor adp = _deployAdaptive();
        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(adp), 1e18);
        vm.prank(attacker);
        vm.expectRevert();
        adp.recoverToken(address(rnd), 1e18, attacker);
    }

    function test_Recover_Adaptive_ZeroTo_Reverts() public {
        AdaptiveFeeDistributor adp = _deployAdaptive();
        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(adp), 1e18);
        vm.expectRevert(AdaptiveFeeDistributor.ZeroAddressNotAllowed.selector);
        adp.recoverToken(address(rnd), 1e18, address(0));
    }

    function test_Recover_Adaptive_EventEmitted() public {
        AdaptiveFeeDistributor adp = _deployAdaptive();
        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(adp), 7e18);
        vm.expectEmit(true, false, true, true, address(adp));
        emit TokenRecovered(address(rnd), 7e18, rescueDest);
        adp.recoverToken(address(rnd), 7e18, rescueDest);
    }

    // ═══════════════════════════════════════════════════════════
    // 8. TWAPBurner — LOW-1 event fix
    // ═══════════════════════════════════════════════════════════

    function test_Recover_TWAPBurner_EventEmitted_LOW1_Fix() public {
        MockERC20 usdc = new MockERC20("USDC", "USDC");
        MockERC20 lumina = new MockERC20("LUM", "LUM");
        TWAPBurner tb = ProxyDeployer.deployTWAPBurner(address(usdc), address(lumina), address(new InertDexRouter()));

        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(tb), 100e18);

        vm.expectEmit(true, false, true, true, address(tb));
        emit TokenRecovered(address(rnd), 100e18, address(this));
        tb.recoverToken(address(rnd), 100e18);
    }

    // ═══════════════════════════════════════════════════════════
    // 9. Attack surface — malicious admin cannot drain core tokens
    // ═══════════════════════════════════════════════════════════

    function test_AttackSurface_Admin_CannotDrain_BondVaultCore() public {
        (BondVault vault, MockERC20 lumina, ClaimBond cb) = _deployBondVault();
        lumina.mint(address(vault), 70_000_000e18);

        // LUMINA blocked.
        vm.expectRevert(abi.encodeWithSelector(BondVault.CoreTokenProtected.selector, address(lumina)));
        vault.recoverToken(address(lumina), 1e18, attacker);

        // ClaimBond blocked (both paths).
        vm.expectRevert(abi.encodeWithSelector(BondVault.CoreTokenProtected.selector, address(cb)));
        vault.recoverToken(address(cb), 1, attacker);
        vm.expectRevert(abi.encodeWithSelector(BondVault.CoreTokenProtected.selector, address(cb)));
        vault.recoverERC1155(address(cb), 202904, 1, attacker);

        // Vault balance intact.
        assertEq(lumina.balanceOf(address(vault)), 70_000_000e18);
    }

    function test_AttackSurface_Admin_CannotDrain_AcrossSevenContracts() public {
        // Deploy each of the 7 contracts with a minted core token and prove
        // no core-blacklisted token is drainable.
        {
            (BondVault vault, MockERC20 lumina,) = _deployBondVault();
            lumina.mint(address(vault), 1e18);
            vm.expectRevert(abi.encodeWithSelector(BondVault.CoreTokenProtected.selector, address(lumina)));
            vault.recoverToken(address(lumina), 1e18, attacker);
            assertEq(lumina.balanceOf(address(vault)), 1e18);
        }
        {
            (CEXLiquidityReserve cex, MockERC20 lumina) = _deployCEX();
            lumina.mint(address(cex), 1e18);
            vm.expectRevert(abi.encodeWithSelector(CEXLiquidityReserve.CoreTokenProtected.selector, address(lumina)));
            cex.recoverToken(address(lumina), 1e18, attacker);
            assertEq(lumina.balanceOf(address(cex)), 1e18);
        }
        {
            (TreasuryVesting tv, MockERC20 lumina) = _deployTV();
            lumina.mint(address(tv), 1e18);
            vm.expectRevert(abi.encodeWithSelector(TreasuryVesting.CoreTokenProtected.selector, address(lumina)));
            tv.recoverToken(address(lumina), 1e18, attacker);
            assertEq(lumina.balanceOf(address(tv)), 1e18);
        }
        {
            (CoverRouterV2 cr, MockERC20 usdc) = _deployCR();
            usdc.mint(address(cr), 1e18);
            vm.expectRevert(abi.encodeWithSelector(CoverRouterV2.CoreTokenProtected.selector, address(usdc)));
            cr.recoverToken(address(usdc), 1e18, attacker);
            assertEq(usdc.balanceOf(address(cr)), 1e18);
        }
        {
            (LuminaBondMarketplace mp, MockERC20 usdc,) = _deployMP();
            usdc.mint(address(mp), 1e18);
            vm.expectRevert(abi.encodeWithSelector(LuminaBondMarketplace.CoreTokenProtected.selector, address(usdc)));
            mp.recoverToken(address(usdc), 1e18, attacker);
            assertEq(usdc.balanceOf(address(mp)), 1e18);
        }
        {
            (BuybackEngine be, MockERC20 usdc,) = _deployBuyback();
            usdc.mint(address(be), 1e18);
            vm.expectRevert(abi.encodeWithSelector(BuybackEngine.CoreTokenProtected.selector, address(usdc)));
            be.recoverToken(address(usdc), 1e18, attacker);
            assertEq(usdc.balanceOf(address(be)), 1e18);
        }
        // AdaptiveFeeDistributor has no core tokens — skipped (by design).
    }

    // ═══════════════════════════════════════════════════════════
    // 10. Multiple recoveries in one test — no state leak between contracts
    // ═══════════════════════════════════════════════════════════

    function test_Recover_MultipleContracts_SameRun_Independent() public {
        (BondVault vault,,) = _deployBondVault();
        (CEXLiquidityReserve cex,) = _deployCEX();
        (TreasuryVesting tv,) = _deployTV();

        MockERC20 a = new MockERC20("A", "A");
        MockERC20 b = new MockERC20("B", "B");
        MockERC20 c = new MockERC20("C", "C");

        a.mint(address(vault), 10e18);
        b.mint(address(cex), 20e18);
        c.mint(address(tv), 30e18);

        vault.recoverToken(address(a), 10e18, rescueDest);
        cex.recoverToken(address(b), 20e18, rescueDest);
        tv.recoverToken(address(c), 30e18, rescueDest);

        assertEq(a.balanceOf(rescueDest), 10e18);
        assertEq(b.balanceOf(rescueDest), 20e18);
        assertEq(c.balanceOf(rescueDest), 30e18);
    }

    // ═══════════════════════════════════════════════════════════
    // 11. Storage-layout smoke-check via public getter preservation
    // ═══════════════════════════════════════════════════════════

    function test_Recover_StorageLayout_BondVault_PreservedPostDeploy() public {
        (BondVault vault, MockERC20 lumina, ClaimBond cb) = _deployBondVault();

        // The rescue path should NOT consume any of the 50 gap slots used by V1;
        // we verify by reading every public getter that occupies the prior layout.
        assertEq(address(vault.lumina()), address(lumina));
        assertEq(address(vault.claimBond()), address(cb));
        assertEq(vault.totalCommittedUSD(), 0);
        assertEq(vault.totalReservedUSD(), 0);
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));

        // Rescue a random token and re-read — no mutation of pre-existing slots.
        MockERC20 rnd = new MockERC20("R", "R");
        rnd.mint(address(vault), 1e18);
        vault.recoverToken(address(rnd), 1e18, rescueDest);

        assertEq(address(vault.lumina()), address(lumina));
        assertEq(address(vault.claimBond()), address(cb));
        assertEq(vault.totalCommittedUSD(), 0);
        assertEq(vault.totalReservedUSD(), 0);
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Minimal fake Marketplace for BuybackEngine deployment
// ─────────────────────────────────────────────────────────────────────────

contract FakeMarketplace {
    uint256 public constant BUYER_FEE_BPS = 150;
    uint256 public constant BPS_DENOMINATOR = 10000;

    function executeBuy(uint256) external {}

    function getListing(uint256)
        external
        pure
        returns (address seller, uint256 epochId, uint256 amount, uint256 priceUSDC, bool active)
    {
        return (address(0), 0, 0, 0, false);
    }
}
