// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";
import {TWAPBurner} from "../../src/core/TWAPBurner.sol";
import {IDexRouter} from "../../src/interfaces/IDexRouter.sol";

contract F19MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract F19MockLumina is ERC20 {
    constructor() ERC20("LUMINA", "LUMINA") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

/// @notice DEX that REPORTS a huge quote (as a sandwicher would, to lift the
///         pool-derived floor) but DELIVERS only `actualOut`. If minOut were
///         derived from `getQuote`, the swap would revert on the inflated
///         floor; if minOut is derived from the oracle, it passes/fails based
///         on the honest oracle price only — exposing the sandwich.
contract F19SandwichDex is IDexRouter {
    using SafeERC20 for IERC20;

    uint256 public reportedQuote;
    uint256 public actualOut;
    uint256 public lastMinOut;

    function configure(uint256 _reportedQuote, uint256 _actualOut) external {
        reportedQuote = _reportedQuote;
        actualOut = _actualOut;
    }

    function getQuote(address, address, uint256) external view returns (uint256) {
        return reportedQuote;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        external
        returns (uint256 amountOut)
    {
        lastMinOut = minOut;
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        amountOut = actualOut;
        require(amountOut >= minOut, "slippage");
        if (IERC20(tokenOut).balanceOf(address(this)) >= amountOut) {
            IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
        }
    }
}

contract F19MockOracle {
    uint256 public price;
    bool public doRevert;

    function setPrice(uint256 p) external {
        price = p;
    }

    function setRevert(bool r) external {
        doRevert = r;
    }

    function getLuminaPrice() external view returns (uint256) {
        require(!doRevert, "ORACLE_UNAVAILABLE");
        return price;
    }
}

contract F19BurnMinOutTest is Test {
    using SafeERC20 for IERC20;

    F19MockUSDC internal usdc;
    F19MockLumina internal lumina;
    F19SandwichDex internal dex;
    F19MockOracle internal oracle;
    TWAPBurner internal burner;

    function setUp() public {
        vm.chainId(8453);
        // Realistic chain time: with lastBurnTimestamp==0 the burnCooldown gate
        // (block.timestamp >= 0 + cooldown) is only meaningful at real-world
        // timestamps. Foundry's default ts=1 would spuriously block the first
        // burn ("Cooldown active") — a test-harness artifact, not contract logic.
        vm.warp(1_700_000_000);
        usdc = new F19MockUSDC();
        lumina = new F19MockLumina();
        dex = new F19SandwichDex();
        oracle = new F19MockOracle();
        lumina.mint(address(dex), 100_000_000e18);

        burner = ProxyDeployer.deployTWAPBurner(address(usdc), address(lumina), address(dex));
        burner.setCapacityOracle(address(oracle));

        // Fund the burner with USDC to burn.
        usdc.mint(address(burner), 1_000e6);
        // Default slippage 500 bps (5%).
    }

    /// minOut must be derived from the oracle, NOT the pool's self-reported quote.
    function test_MinOutFromOracleNotPoolQuote() external {
        // Oracle price $0.01 (1e16). For 1000 USDC (capped at maxBurn=10_000e6,
        // balance 1000e6 used): expectedOut = 1000e6 * 1e12 * 1e18 / 1e16
        //   = 1000e18 * 1e12 / 1e16 *... let's just compute the oracle minOut.
        oracle.setPrice(1e16); // $0.01

        // The pool LIES with a tiny quote (would yield a ~0 floor if trusted),
        // but DELIVERS a healthy amount. Oracle-derived floor governs instead.
        // expectedOut = (1000e6 * 1e12 * 1e18) / 1e16 = 1e29 / 1e16 = 1e... compute:
        // 1000e6 = 1e9; *1e12 = 1e21; *1e18 = 1e39; /1e16 = 1e23 = 100000e18.
        uint256 expectedOut = (1_000e6 * 1e12 * 1e18) / 1e16; // 100_000e18
        uint256 oracleMinOut = (expectedOut * (10_000 - 500)) / 10_000; // -5%

        // Pool reports a tiny quote (sandwich attempt to drop the floor) but
        // delivers exactly the oracle floor.
        dex.configure(1, oracleMinOut);

        burner.executeBurn();

        // The minOut handed to the DEX equals the ORACLE-derived value, NOT the
        // pool's reported quote of `1`.
        assertEq(dex.lastMinOut(), oracleMinOut, "minOut must come from oracle");
        assertGt(burner.totalLUMINABurned(), 0, "burn executed at oracle floor");
    }

    /// If the oracle is unavailable, the burn must REVERT (no pool-quote fallback).
    function test_BurnRevertsWhenOracleUnavailable() external {
        oracle.setPrice(1e16);
        // Pool reports a generous quote — under the OLD code this would have
        // provided a fallback floor and the swap would proceed.
        dex.configure(200_000e18, 200_000e18);

        oracle.setRevert(true);

        vm.expectRevert(bytes("ORACLE_UNAVAILABLE"));
        burner.executeBurn();

        assertEq(burner.totalLUMINABurned(), 0, "no burn when oracle down");
    }

    /// Oracle unset must also revert (no silent permissive path).
    function test_BurnRevertsWhenOracleUnset() external {
        // Deploy a fresh burner with no oracle wired.
        TWAPBurner b2 = ProxyDeployer.deployTWAPBurner(address(usdc), address(lumina), address(dex));
        usdc.mint(address(b2), 1_000e6);
        vm.expectRevert(bytes("TWAPBurner: oracle unset"));
        b2.executeBurn();
    }
}
