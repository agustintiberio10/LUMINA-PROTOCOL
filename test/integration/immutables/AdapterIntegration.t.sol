// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TWAPBurner} from "../../../src/core/TWAPBurner.sol";
import {AerodromeAdapter, IAerodromeRouter} from "../../../src/dex/AerodromeAdapter.sol";
import {UniswapV3Adapter, ISwapRouter, IQuoterV2} from "../../../src/dex/UniswapV3Adapter.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

// ─── Proper ERC20 mocks (OZ-based, allowance + burn) ───

contract AI_USDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract AI_LUMINA is ERC20 {
    constructor() ERC20("LUMINA", "LUM") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function burn(uint256 amt) external {
        _burn(msg.sender, amt);
    }
}

// ─── Aerodrome router mock implementing the full IAerodromeRouter ───

contract AI_AeroRouter is IAerodromeRouter {
    AI_USDC public usdc;
    AI_LUMINA public lumina;
    uint256 public rate; // multiplier: lumina_out = usdc_in * rate
    bool public swapShouldRevert;
    bool public quoteShouldRevert;

    constructor(AI_USDC _u, AI_LUMINA _l, uint256 _rate) {
        usdc = _u;
        lumina = _l;
        rate = _rate;
    }

    function setRate(uint256 r) external {
        rate = r;
    }

    function setSwapRevert(bool r) external {
        swapShouldRevert = r;
    }

    function setQuoteRevert(bool r) external {
        quoteShouldRevert = r;
    }

    function swapExactTokensForTokens(uint256 amountIn, uint256 minOut, Route[] calldata, address to, uint256)
        external
        returns (uint256[] memory amounts)
    {
        require(!swapShouldRevert, "AeroMock: swap revert");
        usdc.transferFrom(msg.sender, address(this), amountIn);
        uint256 out = amountIn * rate;
        require(out >= minOut, "AeroMock: minOut");
        lumina.mint(to, out);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = out;
    }

    function getAmountsOut(uint256 amountIn, Route[] memory) external view returns (uint256[] memory amounts) {
        require(!quoteShouldRevert, "AeroMock: quote revert");
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn * rate;
    }
}

// ─── Uniswap V3 router + quoter mocks ───

contract AI_UniRouter is ISwapRouter {
    AI_USDC public usdc;
    AI_LUMINA public lumina;
    uint256 public rate;
    bool public shouldRevert;

    constructor(AI_USDC _u, AI_LUMINA _l, uint256 _rate) {
        usdc = _u;
        lumina = _l;
        rate = _rate;
    }

    function setRate(uint256 r) external {
        rate = r;
    }

    function setRevert(bool r) external {
        shouldRevert = r;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 amountOut) {
        require(!shouldRevert, "UniMock: swap revert");
        usdc.transferFrom(msg.sender, address(this), p.amountIn);
        amountOut = p.amountIn * rate;
        require(amountOut >= p.amountOutMinimum, "UniMock: minOut");
        lumina.mint(p.recipient, amountOut);
    }
}

contract AI_UniQuoter is IQuoterV2 {
    uint256 public rate;
    bool public shouldRevert;

    constructor(uint256 _rate) {
        rate = _rate;
    }

    function setRate(uint256 r) external {
        rate = r;
    }

    function setRevert(bool r) external {
        shouldRevert = r;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory p)
        external
        view
        returns (uint256, uint160, uint32, uint256)
    {
        require(!shouldRevert, "UniMock: quote revert");
        return (p.amountIn * rate, 0, 0, 21000);
    }
}

/// @title AdapterIntegration
/// @notice Sprint Z.1 Phase 3 — full e2e burn flow via TWAPBurner with both adapters.
///         No mainnet fork required; verifies the adapter abstraction end-to-end
///         including best-price selection across multiple DEXes and graceful
///         degradation when one router's quote reverts.
contract AdapterIntegrationTest is Test {
    AI_USDC usdc;
    AI_LUMINA lumina;
    AI_AeroRouter aeroRouter;
    AI_UniRouter uniRouter;
    AI_UniQuoter uniQuoter;
    AerodromeAdapter aeroAdapter;
    UniswapV3Adapter uniAdapter;
    TWAPBurner burner;
    address factory = address(0xFAC10);

    function setUp() public {
        vm.chainId(8453);
        usdc = new AI_USDC();
        lumina = new AI_LUMINA();
        aeroRouter = new AI_AeroRouter(usdc, lumina, 30);
        uniRouter = new AI_UniRouter(usdc, lumina, 30);
        uniQuoter = new AI_UniQuoter(30);
        aeroAdapter = new AerodromeAdapter(address(aeroRouter), factory, false);
        uniAdapter = new UniswapV3Adapter(address(uniRouter), address(uniQuoter), 3000);
        burner = ProxyDeployer.deployTWAPBurner(address(usdc), address(lumina), address(aeroAdapter));
    }

    function test_AeroAdapter_TWAPBurner_FullBurnFlow_E2E() public {
        usdc.mint(address(burner), 100e6);
        vm.warp(block.timestamp + burner.burnCooldown() + 1);
        uint256 lumBefore = lumina.totalSupply();
        burner.executeBurn();
        // 100e6 USDC * rate(30) = 3000e6 LUMINA minted then burned.
        assertEq(burner.totalUSDCBurned(), 100e6);
        assertGt(burner.totalLUMINABurned(), 0);
        // Net supply unchanged (minted == burned within executeBurn).
        assertEq(lumina.totalSupply(), lumBefore);
    }

    function test_UniAdapter_TWAPBurner_FullBurnFlow_E2E() public {
        // Replace AeroAdapter with UniAdapter.
        address[] memory routers = new address[](1);
        routers[0] = address(uniAdapter);
        burner.setDexRouters(routers);
        usdc.mint(address(burner), 100e6);
        vm.warp(block.timestamp + burner.burnCooldown() + 1);
        burner.executeBurn();
        assertEq(burner.totalUSDCBurned(), 100e6);
        assertGt(burner.totalLUMINABurned(), 0);
    }

    function test_BothAdapters_BestPriceSelection_PicksHigher() public {
        burner.addDexRouter(address(uniAdapter));
        // Uni quotes a higher rate → should be picked.
        uniQuoter.setRate(50);
        aeroRouter.setRate(30);
        uniRouter.setRate(50); // ensure actual swap matches quote
        usdc.mint(address(burner), 100e6);
        vm.warp(block.timestamp + burner.burnCooldown() + 1);
        burner.executeBurn();
        // At rate 50, LUMINA out = 100e6 * 50 = 5_000e6. Aero would be 3_000e6.
        assertEq(burner.totalLUMINABurned(), 5_000e6, "best-price selection must pick Uni at rate 50");
    }

    function test_AdapterFailover_OneQuoteReverts_OtherWins() public {
        burner.addDexRouter(address(uniAdapter));
        // Force Aero's quote path to revert → its quote=0 → Uni picked.
        aeroRouter.setQuoteRevert(true);
        uniRouter.setRate(40);
        uniQuoter.setRate(40);
        usdc.mint(address(burner), 100e6);
        vm.warp(block.timestamp + burner.burnCooldown() + 1);
        burner.executeBurn();
        assertEq(burner.totalLUMINABurned(), 100e6 * 40, "Uni must win when Aero quote reverts");
    }
}
