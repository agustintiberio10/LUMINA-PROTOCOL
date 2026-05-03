// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TWAPBurner} from "../../src/core/TWAPBurner.sol";
import {LuminaTokenV2} from "../../src/token/LuminaTokenV2.sol";
import {IDexRouter} from "../../src/interfaces/IDexRouter.sol";

/// @notice Configurable mock DEX adapter — can be set to revert, return
///         a low amount, return a fixed amount, etc.
contract MockDexAdapter is IDexRouter {
    enum Mode {
        Healthy,        // returns expectedOut
        RevertOnSwap,   // reverts swap (DEX outage)
        RevertOnQuote,  // reverts getQuote (oracle path still works)
        ReturnZero      // returns 0 from swap (will trip the > 0 require)
    }

    Mode public swapMode;
    Mode public quoteMode;
    uint256 public mockOutput; // amount to return on swap success
    uint256 public mockQuote;
    string public revertReason = "MockDexAdapter: simulated outage";

    address public lumina; // we mint these

    constructor(address _lumina) {
        lumina = _lumina;
    }

    function setMode(Mode _swap, Mode _quote) external {
        swapMode = _swap;
        quoteMode = _quote;
    }

    function setMockOutput(uint256 _o) external {
        mockOutput = _o;
    }

    function setMockQuote(uint256 _q) external {
        mockQuote = _q;
    }

    function setRevertReason(string calldata _r) external {
        revertReason = _r;
    }

    function swap(address tokenIn, address /*tokenOut*/, uint256 amountIn, uint256 minAmountOut)
        external
        override
        returns (uint256)
    {
        if (swapMode == Mode.RevertOnSwap) revert(revertReason);

        // Pull amountIn (test setUps approve us beforehand).
        require(
            // Use call so we don't depend on the test contract's IERC20 import.
            _safeTransferFrom(tokenIn, msg.sender, address(this), amountIn),
            "transferFrom failed"
        );

        if (swapMode == Mode.ReturnZero) return 0;

        uint256 out = mockOutput == 0 ? amountIn : mockOutput;
        require(out >= minAmountOut, "MockDex: minOut not met");

        // Mint LUMINA out (test environment: TWAPBurner expects to receive
        // tokens it can then burn). We use a low-level mint via direct
        // storage write to bypass role checks; simpler: use deal.
        _safeMint(msg.sender, out);
        return out;
    }

    function getQuote(address /*tokenIn*/, address /*tokenOut*/, uint256 amountIn) external view returns (uint256) {
        if (quoteMode == Mode.RevertOnQuote) revert("MockDex: quote outage");
        return mockQuote == 0 ? amountIn : mockQuote;
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal returns (bool) {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, amount));
        return ok && (data.length == 0 || abi.decode(data, (bool)));
    }

    function _safeMint(address to, uint256 amount) internal {
        // For test purposes, use cheatcode-equivalent: ask Vm to deal more
        // to `to`. Since this contract isn't a Test contract, we instead
        // assume the test pre-funded us with LUMINA we now transfer. This
        // is a simplification: tests deal LUMINA to the adapter beforehand.
        // Use low-level call so we don't import IERC20.
        (bool ok,) = lumina.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        require(ok, "transfer to recipient failed");
    }
}

/// @title DexFallbackTest
/// @notice Audit V5.1 fix M-12 — TWAPBurner now degrades gracefully to
///         secondary/tertiary DEX adapters when the primary fails.
contract DexFallbackTest is Test {
    event BurnAdapterUsed(address indexed adapter, uint256 usdcAmount, uint256 luminaReceived);
    event DexAdapterFailed(address indexed adapter, bytes reason);
    event AllDexAdaptersFailed(uint256 usdcAmount);
    event DexAdaptersUpdated(address[] adapters);
    event BurnRetried(uint256 amount, address indexed by);

    TWAPBurner burner;
    LuminaTokenV2 token;
    MockDexAdapter primary;
    MockDexAdapter secondary;
    MockDexAdapter tertiary;

    address owner = address(this);
    address authSender = makeAddr("authSender");

    // Mock USDC: simple ERC20 we can mint/transferFrom.
    MockUSDC usdc;

    uint256 constant BURN_AMOUNT = 1000e6; // 1000 USDC

    function setUp() public {
        usdc = new MockUSDC();

        // LuminaTokenV2 proxy.
        LuminaTokenV2 tImpl = new LuminaTokenV2();
        ERC1967Proxy tProxy = new ERC1967Proxy(
            address(tImpl),
            abi.encodeWithSelector(
                LuminaTokenV2.initialize.selector,
                makeAddr("vault"),
                makeAddr("cex"),
                makeAddr("founder"),
                makeAddr("lbp"),
                makeAddr("treasury")
            )
        );
        token = LuminaTokenV2(address(tProxy));

        // 3 mock adapters chained.
        primary = new MockDexAdapter(address(token));
        secondary = new MockDexAdapter(address(token));
        tertiary = new MockDexAdapter(address(token));

        // TWAPBurner proxy with primary.
        TWAPBurner bImpl = new TWAPBurner();
        ERC1967Proxy bProxy = new ERC1967Proxy(
            address(bImpl),
            abi.encodeWithSelector(
                TWAPBurner.initialize.selector, address(usdc), address(token), address(primary)
            )
        );
        burner = TWAPBurner(address(bProxy));

        // Wire secondary + tertiary.
        address[] memory chain = new address[](3);
        chain[0] = address(primary);
        chain[1] = address(secondary);
        chain[2] = address(tertiary);
        burner.setDexRouters(chain);

        // Default: all adapters healthy, return 1:1 (so minOut = quote * 0.95
        // is below the 1:1 swap output).
        primary.setMockQuote(1000e6 * 1e12); // 1e18 LUMINA per 1e6 USDC = 1:1 in 18-dec
        primary.setMockOutput(1000e6 * 1e12);
        secondary.setMockQuote(1000e6 * 1e12);
        secondary.setMockOutput(1000e6 * 1e12);
        tertiary.setMockQuote(1000e6 * 1e12);
        tertiary.setMockOutput(1000e6 * 1e12);

        // Mint USDC to the burner so executeBurn has something to burn.
        usdc.mint(address(burner), BURN_AMOUNT);

        // Fund each adapter with LUMINA so its swap can return tokens.
        deal(address(token), address(primary), 1_000_000 ether);
        deal(address(token), address(secondary), 1_000_000 ether);
        deal(address(token), address(tertiary), 1_000_000 ether);
    }

    // ═══════ CRITICAL — fallback chain ═══════

    function test_PrimaryDexSucceeds() public {
        // Happy path: primary works, secondary + tertiary not consulted.
        // Warp past cooldown.
        vm.warp(block.timestamp + burner.burnCooldown() + 1);

        vm.expectEmit(true, false, false, false);
        emit BurnAdapterUsed(address(primary), 0, 0);
        burner.executeBurn();

        assertGt(burner.totalLUMINABurned(), 0);
    }

    function test_PrimaryFailsSecondaryWorks() public {
        primary.setMode(MockDexAdapter.Mode.RevertOnSwap, MockDexAdapter.Mode.Healthy);
        vm.warp(block.timestamp + burner.burnCooldown() + 1);

        // Expect: DexAdapterFailed(primary), then BurnAdapterUsed(secondary).
        vm.expectEmit(true, false, false, false);
        emit DexAdapterFailed(address(primary), "");
        vm.expectEmit(true, false, false, false);
        emit BurnAdapterUsed(address(secondary), 0, 0);
        burner.executeBurn();

        assertGt(burner.totalLUMINABurned(), 0);
    }

    function test_PrimaryAndSecondaryFailTertiaryWorks() public {
        primary.setMode(MockDexAdapter.Mode.RevertOnSwap, MockDexAdapter.Mode.Healthy);
        secondary.setMode(MockDexAdapter.Mode.RevertOnSwap, MockDexAdapter.Mode.Healthy);
        vm.warp(block.timestamp + burner.burnCooldown() + 1);

        vm.expectEmit(true, false, false, false);
        emit BurnAdapterUsed(address(tertiary), 0, 0);
        burner.executeBurn();

        assertGt(burner.totalLUMINABurned(), 0);
    }

    function test_AllDexFailReverts() public {
        primary.setMode(MockDexAdapter.Mode.RevertOnSwap, MockDexAdapter.Mode.Healthy);
        secondary.setMode(MockDexAdapter.Mode.RevertOnSwap, MockDexAdapter.Mode.Healthy);
        tertiary.setMode(MockDexAdapter.Mode.RevertOnSwap, MockDexAdapter.Mode.Healthy);
        vm.warp(block.timestamp + burner.burnCooldown() + 1);

        vm.expectRevert("All DEX adapters failed");
        burner.executeBurn();

        // USDC NOT consumed (revert rolled back any approvals + balance moves).
        assertEq(usdc.balanceOf(address(burner)), BURN_AMOUNT);
    }

    function test_RetryBurnAfterDexRecovery() public {
        // First attempt: all adapters down.
        primary.setMode(MockDexAdapter.Mode.RevertOnSwap, MockDexAdapter.Mode.Healthy);
        secondary.setMode(MockDexAdapter.Mode.RevertOnSwap, MockDexAdapter.Mode.Healthy);
        tertiary.setMode(MockDexAdapter.Mode.RevertOnSwap, MockDexAdapter.Mode.Healthy);
        vm.warp(block.timestamp + burner.burnCooldown() + 1);
        vm.expectRevert("All DEX adapters failed");
        burner.executeBurn();

        // DEX recovers.
        secondary.setMode(MockDexAdapter.Mode.Healthy, MockDexAdapter.Mode.Healthy);

        // Operator manually retries via retryBurn (bypasses cooldown).
        vm.expectEmit(false, true, false, false);
        emit BurnRetried(BURN_AMOUNT, address(this));
        burner.retryBurn(BURN_AMOUNT);

        assertGt(burner.totalLUMINABurned(), 0);
    }

    function test_DexAdapterFailedEventEmitted() public {
        primary.setMode(MockDexAdapter.Mode.RevertOnSwap, MockDexAdapter.Mode.Healthy);
        primary.setRevertReason("primary down");
        vm.warp(block.timestamp + burner.burnCooldown() + 1);

        // Expect: DexAdapterFailed for primary at minimum.
        vm.expectEmit(true, false, false, false);
        emit DexAdapterFailed(address(primary), "");
        burner.executeBurn();
    }

    // ═══════ PROTECCIONES ═══════

    function test_OnlyAdminCanSetAdapters() public {
        address[] memory chain = new address[](1);
        chain[0] = address(primary);
        vm.expectRevert();
        vm.prank(makeAddr("attacker"));
        burner.setDexRouters(chain);
    }

    function test_MaxFiveAdapters() public {
        address[] memory tooMany = new address[](6);
        for (uint256 i = 0; i < 6; i++) tooMany[i] = address(primary);
        vm.expectRevert("Exceeds max adapters");
        burner.setDexRouters(tooMany);
    }

    function test_FiveAdaptersExactly() public {
        address[] memory exact = new address[](5);
        for (uint256 i = 0; i < 5; i++) exact[i] = address(primary);
        burner.setDexRouters(exact);
        assertEq(burner.dexRouterCount(), 5);
    }

    function test_AddDexRouterCapEnforced() public {
        // Already have 3 in setUp. Add 2 more (total 5), then 6th must fail.
        burner.addDexRouter(address(secondary));
        burner.addDexRouter(address(tertiary));
        assertEq(burner.dexRouterCount(), 5);
        vm.expectRevert("Max adapters reached");
        burner.addDexRouter(address(primary));
    }

    function test_EmptyAdaptersArrayReverts() public {
        address[] memory empty = new address[](0);
        vm.expectRevert("Empty routers");
        burner.setDexRouters(empty);
    }

    function test_InvalidAdapterAddressReverts() public {
        address[] memory bad = new address[](2);
        bad[0] = address(primary);
        bad[1] = address(0);
        vm.expectRevert("Zero router");
        burner.setDexRouters(bad);
    }

    function test_RetryBurnOnlyOwner() public {
        vm.expectRevert();
        vm.prank(makeAddr("attacker"));
        burner.retryBurn(BURN_AMOUNT);
    }

    function test_RetryBurnZeroAmountReverts() public {
        vm.expectRevert("Zero amount");
        burner.retryBurn(0);
    }

    function test_RetryBurnInsufficientUSDC() public {
        vm.expectRevert("Insufficient USDC");
        burner.retryBurn(BURN_AMOUNT * 100);
    }

    // ═══════ REGRESSION ═══════

    function test_NormalBurnFlowStillWorks() public {
        vm.warp(block.timestamp + burner.burnCooldown() + 1);
        burner.executeBurn();
        assertGt(burner.totalLUMINABurned(), 0);
    }

    function test_ConstantsHaveSpecValues() public view {
        assertEq(burner.MAX_DEX_ADAPTERS(), 5);
    }

    function test_DexAdaptersUpdatedEventEmitted() public {
        address[] memory chain = new address[](2);
        chain[0] = address(primary);
        chain[1] = address(secondary);
        vm.expectEmit(false, false, false, true);
        emit DexAdaptersUpdated(chain);
        burner.setDexRouters(chain);
    }
}

contract MockUSDC {
    string public constant name = "USDC";
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address s, uint256 amount) external returns (bool) {
        allowance[msg.sender][s] = amount;
        return true;
    }
}
