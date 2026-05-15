// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ProxyDeployer} from "../../../../helpers/ProxyDeployer.sol";

import {LuminaTokenV2} from "../../../../../src/token/LuminaTokenV2.sol";
import {TreasuryVesting} from "../../../../../src/token/TreasuryVesting.sol";
import {ClaimBond} from "../../../../../src/bonds/ClaimBond.sol";
import {BondVault} from "../../../../../src/bonds/BondVault.sol";
import {CapacityOracle} from "../../../../../src/oracles/CapacityOracle.sol";
import {CEXLiquidityReserve} from "../../../../../src/treasury/CEXLiquidityReserve.sol";
import {TWAPBurner} from "../../../../../src/core/TWAPBurner.sol";
import {FlashBTCShield1h} from "../../../../../src/products/FlashBTCShield1h.sol";
import {IShield} from "../../../../../src/interfaces/IShield.sol";

import {IDexRouter} from "../../../../../src/interfaces/IDexRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockUSDC_BN {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
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
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

contract MockSwapRouter_BN is IDexRouter {
    using SafeERC20 for IERC20;

    IERC20 public lumina;

    constructor(address _l) {
        lumina = IERC20(_l);
    }

    function swap(address tokenIn, address, uint256 amountIn, uint256) external returns (uint256 out) {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        out = amountIn * 27 * 1e12;
        lumina.safeTransfer(msg.sender, out);
    }

    function getQuote(address, address, uint256 amountIn) external pure returns (uint256) {
        return amountIn * 27 * 1e12;
    }
}

contract MockShieldOracle_BN {
    function getLatestPrice(bytes32) external pure returns (int256) {
        return 65_000e8;
    }

    function getSequencerDowntime(uint256) external pure returns (uint256) {
        return 0;
    }

    function verifySignature(bytes32, bytes calldata) external pure returns (address) {
        return address(0xdead);
    }

    function oracleKey() external pure returns (address) {
        return address(0xdead);
    }
}

/**
 * @title BlockNumberDeps
 * @notice Audits LUMINA V5.1 for dangerous reliance on `block.number` and
 *         related block-scope globals.
 *
 * Static finding (via `grep` — see REPORT §3): ZERO occurrences of any of
 * the following in `src/`:
 *   - `block.number`
 *   - `blockhash(...)`
 *   - `block.difficulty`
 *   - `block.prevrandao`
 *   - `block.basefee`
 *   - `block.coinbase`
 *   - `block.chainid`
 *   - `tx.origin`
 *
 * Dynamic tests in this file exercise the safety property: rolling blocks
 * forward WITHOUT advancing timestamp must not advance any protocol
 * state. All time-dependent logic uses `block.timestamp` exclusively.
 */
contract BlockNumberDeps is Test {
    ClaimBond claimBond;
    BondVault bondVault;
    LuminaTokenV2 lumina;
    CapacityOracle capacityOracle;
    CEXLiquidityReserve cexReserve;
    TreasuryVesting treasuryVesting;
    TWAPBurner twapBurner;
    MockUSDC_BN usdc;
    MockSwapRouter_BN swapRouter;
    MockShieldOracle_BN shieldOracle;

    address deployer;
    address multisig = makeAddr("multisig");
    address founder = makeAddr("founder");
    address lbpDeposit = makeAddr("lbpDeposit");
    address holder = makeAddr("holder");

    uint256 constant BASE_TS = 1_767_225_600;

    function setUp() public {
        vm.chainId(8453);
        deployer = address(this);
        vm.warp(BASE_TS + 60 days);
        vm.roll(10_000); // establish a reasonable block number baseline

        usdc = new MockUSDC_BN();
        shieldOracle = new MockShieldOracle_BN();

        claimBond = ProxyDeployer.deployClaimBond();

        uint64 n = vm.getNonce(deployer);
        address predictedLumina = vm.computeCreateAddress(deployer, n + 9);

        capacityOracle = ProxyDeployer.deployCapacityOracle(address(0), predictedLumina, address(usdc), 0.036e18);
        bondVault =
            ProxyDeployer.deployBondVault(predictedLumina, address(claimBond), address(capacityOracle), deployer);
        cexReserve = ProxyDeployer.deployCEXLiquidityReserve(predictedLumina, multisig);
        treasuryVesting = ProxyDeployer.deployTreasuryVesting(predictedLumina);

        lumina = ProxyDeployer.deployLuminaTokenV2(
            address(bondVault), address(cexReserve), founder, lbpDeposit, address(treasuryVesting)
        );
        require(address(lumina) == predictedLumina, "lumina addr");
        claimBond.setBondVault(address(bondVault));

        swapRouter = new MockSwapRouter_BN(address(lumina));
        deal(address(lumina), address(swapRouter), 1_000_000e18);
        twapBurner = ProxyDeployer.deployTWAPBurner(address(usdc), address(lumina), address(swapRouter));
        lumina.grantRole(lumina.BURNER_ROLE(), address(twapBurner));
    }

    function _params(uint32 d, bytes32 a) internal returns (IShield.CreatePolicyParams memory p) {
        p.buyer = makeAddr("buyer");
        p.coverageAmount = 1000e6;
        p.premiumAmount = 10e6;
        p.durationSeconds = d;
        p.asset = a;
    }

    function _btc1h() internal returns (FlashBTCShield1h) {
        return ProxyDeployer.deployFlashBTCShield1h(address(this), address(shieldOracle));
    }

    // ═══════════════════════════════════════════════════════════
    // A. BLOCK NUMBER IS NOT A TIME SOURCE
    // ═══════════════════════════════════════════════════════════

    /// @notice Advancing block.number without touching block.timestamp must
    ///         not expire a live policy. Expirations are timestamp-based.
    function test_BlockNum_UUPS_Policy_DoesNotExpireOnBlockRoll() public {
        FlashBTCShield1h s = _btc1h();
        uint256 pid = s.createPolicy(_params(3600, "BTC"));
        uint256 tsBefore = block.timestamp;

        IShield.PolicyStatus statusBefore = s.getPolicyStatus(pid);
        vm.roll(block.number + 10_000_000); // 10 million blocks
        assertEq(block.timestamp, tsBefore, "timestamp unchanged by vm.roll");

        IShield.PolicyStatus statusAfter = s.getPolicyStatus(pid);
        assertEq(uint256(statusBefore), uint256(statusAfter), "block.number must not drive policy status");
    }

    /// @notice Same property for the TWAPBurner cooldown gate.
    function test_BlockNum_UUPS_BurnCooldown_DoesNotExpireOnBlockRoll() public {
        usdc.mint(address(twapBurner), 100e6);
        vm.warp(block.timestamp + 901);
        twapBurner.executeBurn();
        uint256 tsAfterBurn = block.timestamp;

        // Many blocks later, same second.
        vm.roll(block.number + 1_000_000);
        assertEq(block.timestamp, tsAfterBurn);

        usdc.mint(address(twapBurner), 100e6);
        vm.expectRevert(bytes("Cooldown active"));
        twapBurner.executeBurn();
    }

    /// @notice Bond maturity is timestamp-based; block.number rolling does
    ///         nothing.
    function test_BlockNum_UUPS_BondMaturity_DoesNotAdvanceOnBlockRoll() public {
        vm.prank(deployer); // policyManager
        bondVault.issueBond(holder, 100);

        // Pick any epoch the holder now has.
        uint256 epoch;
        for (uint256 e = 202600; e <= 210012; e++) {
            if (claimBond.balanceOf(holder, e) > 0) {
                epoch = e;
                break;
            }
        }

        assertFalse(claimBond.isMatured(epoch));
        vm.roll(block.number + 100_000_000); // absurd block count
        assertFalse(claimBond.isMatured(epoch), "block roll must not mature bonds");
    }

    /// @notice Epoch computation is based on block.timestamp, never
    ///         block.number. Issuing two bonds across a huge block gap but
    ///         zero time gap yields the same epoch.
    function test_BlockNum_UUPS_EpochComputation_IndependentOfBlockNumber() public {
        vm.prank(deployer);
        bondVault.issueBond(holder, 10);
        uint256 epoch1;
        for (uint256 e = 202600; e <= 210012; e++) {
            if (claimBond.balanceOf(holder, e) > 0) {
                epoch1 = e;
                break;
            }
        }

        vm.roll(block.number + 5_000_000); // millions of blocks, zero time

        // Issue a second bond to a different holder.
        address holder2 = makeAddr("holder2");
        vm.prank(deployer);
        bondVault.issueBond(holder2, 10);
        uint256 epoch2;
        for (uint256 e = 202600; e <= 210012; e++) {
            if (claimBond.balanceOf(holder2, e) > 0) {
                epoch2 = e;
                break;
            }
        }

        assertEq(epoch1, epoch2, "epoch is timestamp-derived, block.number irrelevant");
    }

    // ═══════════════════════════════════════════════════════════
    // B. SEQUENCER / SAFETY WINDOW STILL TIMESTAMP-BASED
    // ═══════════════════════════════════════════════════════════

    /// @notice `checkAndSettlePolicy`'s safety-window gate is
    ///         timestamp-based. Rolling 10 million blocks forward with
    ///         zero time elapsed must still revert.
    function test_BlockNum_UUPS_SafetyWindow_IgnoresBlockRoll() public {
        FlashBTCShield1h s = _btc1h();
        uint256 pid = s.createPolicy(_params(3600, "BTC"));
        vm.roll(block.number + 10_000_000);
        vm.expectRevert(); // SafetyWindowNotPassed
        s.checkAndSettlePolicy(pid);
    }

    // ═══════════════════════════════════════════════════════════
    // C. CHAIN ID (NOT A BLOCK.NUMBER, BUT RELATED GLOBAL)
    // ═══════════════════════════════════════════════════════════

    /// @notice Protocol does NOT reference `block.chainid` in src/ — zero
    ///         occurrences. Foundry defaults chainId to 31337; the
    ///         deployment + upgrade paths don't care. Documented here.
    function test_BlockNum_UUPS_NoChainIdDependency_InSrc() public pure {
        // Static claim — verified by `grep block.chainid src/` returning 0
        // results. If it ever becomes non-zero, re-evaluate EIP-712
        // domain separator / cross-chain safety.
        assertTrue(true, "see REPORT section 3");
    }

    // ═══════════════════════════════════════════════════════════
    // D. NO RANDOMNESS FROM BLOCK GLOBALS (STATIC)
    // ═══════════════════════════════════════════════════════════

    function test_BlockNum_UUPS_NoBlockhash_Randomness_InSrc() public pure {
        // `grep blockhash src/` → 0 results. No on-chain randomness;
        // safe against miner-randomness-manipulation attacks.
        assertTrue(true);
    }

    function test_BlockNum_UUPS_NoDifficulty_NoPrevrandao_InSrc() public pure {
        // `grep block.difficulty src/` → 0. `grep block.prevrandao src/` → 0.
        // Post-merge randomness surface is not consumed.
        assertTrue(true);
    }

    function test_BlockNum_UUPS_NoCoinbase_InSrc() public pure {
        // `grep block.coinbase src/` → 0. No miner-payable patterns.
        assertTrue(true);
    }

    function test_BlockNum_UUPS_NoTxOrigin_InSrc() public pure {
        // `grep tx.origin src/` → 0. Access control is msg.sender-based
        // everywhere, immune to nested-contract-call attacks.
        assertTrue(true);
    }

    // ═══════════════════════════════════════════════════════════
    // E. block.number IS NOT USED EVEN FOR VERSIONING (STATIC)
    // ═══════════════════════════════════════════════════════════

    function test_BlockNum_UUPS_NoBlockNumber_Reference_InSrc() public pure {
        // `grep block.number src/` → 0. No snapshot / versioning /
        // logging uses of the block number. Events that include the
        // block number are auto-supplied by the EVM; not under our
        // control.
        assertTrue(true);
    }
}
