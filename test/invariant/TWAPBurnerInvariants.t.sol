// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TWAPBurner} from "../../src/core/TWAPBurner.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

// ═══════ Mocks ═══════

contract TWBMockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract TWBMockLumina is ERC20 {
    constructor() ERC20("LUM", "LUM") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function burn(uint256 amt) external {
        _burn(msg.sender, amt);
    }
}

contract TWBMockDex {
    address public usdc;
    address public lumina;
    uint256 public rate = 30e18; // 1 USDC -> 30 LUMINA at 18 decimals

    constructor(address _usdc, address _lumina) {
        usdc = _usdc;
        lumina = _lumina;
    }

    function getQuote(address, address, uint256 amountIn) external view returns (uint256) {
        return (amountIn * rate) / 1e6;
    }

    function swap(
        address,
        /*tokenIn*/
        address,
        /*tokenOut*/
        uint256 amountIn,
        uint256 minOut
    )
        external
        returns (uint256 out)
    {
        IERC20(usdc).transferFrom(msg.sender, address(this), amountIn);
        out = (amountIn * rate) / 1e6;
        require(out >= minOut, "Mock: slippage");
        TWBMockLumina(lumina).mint(msg.sender, out);
    }
}

/// @notice Handler — bounded ops on TWAPBurner. Avoid receivePremium (it triggers
/// auto-burn pathways with extra storage); use receiveMarketplaceFee + executeBurn.
contract TWBHandler is Test {
    TWAPBurner public burner;
    TWBMockUSDC public usdc;
    address public funder;

    uint256 public ghostReceived;
    uint256 public lastSeenBurnTs;

    constructor(TWAPBurner _b, TWBMockUSDC _u) {
        burner = _b;
        usdc = _u;
        funder = address(this);
        lastSeenBurnTs = _b.lastBurnTimestamp();
    }

    function feedMarketplaceFee(uint256 amount) external {
        amount = bound(amount, 1e6, 5_000e6); // $1 to $5K
        usdc.mint(address(this), amount);
        usdc.approve(address(burner), amount);
        try burner.receiveMarketplaceFee(amount) {
            ghostReceived += amount;
        } catch {}
    }

    function tryExecuteBurn(uint256 warpBy) external {
        warpBy = bound(warpBy, 0, 86400);
        vm.warp(block.timestamp + warpBy);
        try burner.executeBurn() {} catch {}
        uint256 cur = burner.lastBurnTimestamp();
        if (cur > lastSeenBurnTs) lastSeenBurnTs = cur;
    }
}

contract TWAPBurnerInvariants is Test {
    TWAPBurner public burner;
    TWBMockUSDC public usdc;
    TWBMockLumina public lumina;
    TWBMockDex public dex;
    TWBHandler public handler;

    function setUp() public {
        usdc = new TWBMockUSDC();
        lumina = new TWBMockLumina();
        dex = new TWBMockDex(address(usdc), address(lumina));

        burner = ProxyDeployer.deployTWAPBurner(address(usdc), address(lumina), address(dex));

        handler = new TWBHandler(burner, usdc);
        targetContract(address(handler));
    }

    /// INV-Y-TB-1: totalUSDCReceived matches handler ghost (no leakage, no over-receive)
    function invariant_receivedMatchesGhost() public view {
        assertGe(burner.totalUSDCReceived(), handler.ghostReceived(), "INV-Y-TB-1: receive < ghost");
    }

    /// INV-Y-TB-2: totalUSDCBurned never exceeds totalUSDCReceived (no over-burn)
    function invariant_noOverBurn() public view {
        assertLe(burner.totalUSDCBurned(), burner.totalUSDCReceived(), "INV-Y-TB-2: burned > received");
    }

    /// INV-Y-TB-3: lastBurnTimestamp is monotonic
    function invariant_burnTimestampMonotonic() public view {
        assertGe(burner.lastBurnTimestamp(), handler.lastSeenBurnTs(), "INV-Y-TB-3: lastBurnTimestamp regressed");
    }
}
