// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TWAPBurner} from "../../../src/core/TWAPBurner.sol";
import {AerodromeAdapter, IAerodromeRouter} from "../../../src/dex/AerodromeAdapter.sol";
import {FounderVesting, IAaveV3PoolReader} from "../../../src/token/FounderVesting.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

// Reuse the same mock shape used by AdapterIntegration.t.sol but local-scoped to avoid name collision.

contract SI_USDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract SI_LUMINA is ERC20 {
    constructor() ERC20("LUMINA", "LUM") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function burn(uint256 amt) external {
        _burn(msg.sender, amt);
    }
}

contract SI_AeroRouter is IAerodromeRouter {
    SI_USDC public usdc;
    SI_LUMINA public lumina;
    uint256 public rate = 30;

    constructor(SI_USDC _u, SI_LUMINA _l) {
        usdc = _u;
        lumina = _l;
    }

    function swapExactTokensForTokens(uint256 amountIn, uint256 minOut, Route[] calldata, address to, uint256)
        external
        returns (uint256[] memory amounts)
    {
        usdc.transferFrom(msg.sender, address(this), amountIn);
        uint256 out = amountIn * rate;
        require(out >= minOut, "minOut");
        lumina.mint(to, out);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = out;
    }

    function getAmountsOut(uint256 amountIn, Route[] memory) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn * rate;
    }
}

contract SI_Oracle {
    int256 public ethPrice;
    int256 public btcPrice;

    function setPrices(int256 e, int256 b) external {
        ethPrice = e;
        btcPrice = b;
    }

    function getLatestPrice(bytes32 a) external view returns (int256) {
        if (a == bytes32("ETH")) return ethPrice;
        if (a == bytes32("BTC")) return btcPrice;
        return 0;
    }
}

contract SI_Aave {
    uint128 public rate;

    function setRate(uint128 r) external {
        rate = r;
    }

    function getReserveData(address) external view returns (IAaveV3PoolReader.ReserveData memory d) {
        d.currentVariableBorrowRate = rate;
    }
}

/// @title StressIntegration
/// @notice Sprint Z.1 Phase 3 — stress + cross-contract isolation tests.
contract StressIntegrationTest is Test {
    SI_USDC usdc;
    SI_LUMINA lumina;
    SI_AeroRouter router;
    AerodromeAdapter adapter;
    TWAPBurner burner;
    FounderVesting vesting;
    SI_Oracle oracle;
    SI_Aave aave;
    address founder = makeAddr("founder");

    function setUp() public {
        vm.chainId(8453);
        usdc = new SI_USDC();
        lumina = new SI_LUMINA();
        router = new SI_AeroRouter(usdc, lumina);
        adapter = new AerodromeAdapter(address(router), address(0xFAC10), false);
        burner = ProxyDeployer.deployTWAPBurner(address(usdc), address(lumina), address(adapter));

        oracle = new SI_Oracle();
        aave = new SI_Aave();
        vesting = new FounderVesting(address(oracle), address(aave), address(lumina), address(usdc), founder);
        lumina.mint(address(vesting), 8_000_000 * 1e18);
    }

    function test_Stress_100ConsecutiveBurns_AdapterStatePreserved() public {
        // 100 cycles. Each cycle: deposit USDC, wait cooldown, burn.
        for (uint256 i = 0; i < 100; i++) {
            usdc.mint(address(burner), 50e6);
            vm.warp(block.timestamp + burner.burnCooldown() + 1);
            burner.executeBurn();
        }
        // Invariants after 100 burns:
        assertEq(burner.totalUSDCBurned(), 100 * 50e6, "totalUSDCBurned must sum exactly");
        assertGt(burner.totalLUMINABurned(), 0);
        // Adapter holds no residue.
        assertEq(usdc.balanceOf(address(adapter)), 0, "adapter must NOT retain USDC");
        assertEq(lumina.balanceOf(address(adapter)), 0, "adapter must NOT retain LUMINA");
        // Router immutable preserved.
        assertEq(address(adapter.router()), address(router));
    }

    function test_Stress_FounderVestingClaim_DoesNotAffect_TWAPBurnerState() public {
        // Trigger via fallback so vesting is independent of oracle state.
        uint256 t0 = vesting.deployedAt() + vesting.FALLBACK_DURATION() + 1;
        vm.warp(t0);
        vesting.triggerFallback();

        // Snapshot burner state (still zero — never burned).
        uint256 burnerUSDCBefore = burner.totalUSDCBurned();
        uint256 burnerLUMBefore = burner.totalLUMINABurned();
        uint256 burnerLastTs = burner.lastBurnTimestamp();

        // Release all 3 vesting tranches. Use absolute warps (via_ir caches block.timestamp).
        vesting.releaseTranche();
        vm.warp(t0 + 31 days);
        vesting.releaseTranche();
        vm.warp(t0 + 62 days);
        vesting.releaseTranche();

        // Burner state must be untouched.
        assertEq(burner.totalUSDCBurned(), burnerUSDCBefore, "burner USDC counter must NOT shift");
        assertEq(burner.totalLUMINABurned(), burnerLUMBefore, "burner LUMINA counter must NOT shift");
        assertEq(burner.lastBurnTimestamp(), burnerLastTs, "burner timestamp must NOT shift");

        // Vesting fully drained, founder fully credited — full system invariant.
        assertEq(lumina.balanceOf(founder), 8_000_000 * 1e18);
        assertEq(vesting.totalReleased(), 8_000_000 * 1e18);
    }
}
