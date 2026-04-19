// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function decimals() external view returns (uint8);
}

contract BaseMainnetFork is Test {
    uint256 baseFork;

    // Base mainnet contract addresses
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant CHAINLINK_BTC_USD = 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F;
    address constant CHAINLINK_ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant UNISWAP_V3_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;

    modifier onlyFork() {
        if (block.chainid != 8453) return;
        _;
    }

    function setUp() public {
        try vm.createFork(vm.envString("BASE_RPC_URL")) returns (uint256 forkId) {
            baseFork = forkId;
            vm.selectFork(baseFork);
        } catch {
            // No BASE_RPC_URL set — tests will be skipped via onlyFork modifier
        }
    }

    // ═══════ USDC ═══════

    function test_fork_USDCExists() public onlyFork {
        uint256 codeSize;
        address target = BASE_USDC;
        assembly {
            codeSize := extcodesize(target)
        }
        assertGt(codeSize, 0, "USDC contract should have code on Base");

        // Verify USDC has 6 decimals
        (bool success, bytes memory data) = BASE_USDC.staticcall(abi.encodeWithSignature("decimals()"));
        assertTrue(success, "USDC decimals() call should succeed");
        uint8 decimals = abi.decode(data, (uint8));
        assertEq(decimals, 6, "USDC should have 6 decimals");
    }

    // ═══════ CHAINLINK BTC/USD ═══════

    function test_fork_ChainlinkBTCPriceReasonable() public onlyFork {
        AggregatorV3Interface btcFeed = AggregatorV3Interface(CHAINLINK_BTC_USD);
        (, int256 answer,,,) = btcFeed.latestRoundData();

        assertGt(answer, 0, "BTC price should be positive");

        uint8 decimals = btcFeed.decimals();
        // Normalize to USD (integer dollars)
        uint256 btcPrice = uint256(answer) / (10 ** decimals);

        assertGe(btcPrice, 20_000, "BTC price should be >= $20,000");
        assertLe(btcPrice, 200_000, "BTC price should be <= $200,000");
    }

    // ═══════ CHAINLINK ETH/USD ═══════

    function test_fork_ChainlinkETHPriceReasonable() public onlyFork {
        AggregatorV3Interface ethFeed = AggregatorV3Interface(CHAINLINK_ETH_USD);
        (, int256 answer,,,) = ethFeed.latestRoundData();

        assertGt(answer, 0, "ETH price should be positive");

        uint8 decimals = ethFeed.decimals();
        uint256 ethPrice = uint256(answer) / (10 ** decimals);

        assertGe(ethPrice, 500, "ETH price should be >= $500");
        assertLe(ethPrice, 20_000, "ETH price should be <= $20,000");
    }

    // ═══════ UNISWAP V3 ROUTER ═══════

    function test_fork_UniswapRouterExists() public onlyFork {
        uint256 codeSize;
        address target = UNISWAP_V3_ROUTER;
        assembly {
            codeSize := extcodesize(target)
        }
        assertGt(codeSize, 0, "Uniswap V3 Router should have code on Base");
    }
}
