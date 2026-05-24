// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {LuminaBondMarketplace} from "../../src/marketplace/LuminaBondMarketplace.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @dev Minimal ERC-1155-ish ClaimBond mock implementing the interface the marketplace consumes.
contract MockClaimBond {
    mapping(address => mapping(uint256 => uint256)) public bal;
    mapping(uint256 => uint256) public maturity;
    bool public revertOnReceiveCallbackTarget;

    function setMaturity(uint256 epochId, uint256 ts) external {
        maturity[epochId] = ts;
    }

    function maturityDate(uint256 epochId) external view returns (uint256) {
        return maturity[epochId];
    }

    function mint(address to, uint256 epochId, uint256 amount) external {
        bal[to][epochId] += amount;
    }

    function balanceOf(address account, uint256 epochId) external view returns (uint256) {
        return bal[account][epochId];
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata) external {
        require(bal[from][id] >= amount, "insufficient");
        bal[from][id] -= amount;
        bal[to][id] += amount;
    }
}

/// @dev USDC mock with a blacklist that makes `transfer`/`transferFrom` to/from a blacklisted
///      address revert — exactly the USDC-on-Base behaviour the F-14 fix must survive.
contract MockBlacklistUSDC {
    string public name = "Mock USDC";
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public blacklisted;

    function setBlacklist(address a, bool v) external {
        blacklisted[a] = v;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(!blacklisted[from], "USDC: sender blacklisted");
        require(!blacklisted[to], "USDC: recipient blacklisted");
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract F14_PullPayment is Test {
    LuminaBondMarketplace market;
    MockClaimBond claimBond;
    MockBlacklistUSDC usdc;

    address admin = makeAddr("admin");
    address twapBurner = makeAddr("twapBurner");
    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");

    uint256 constant EPOCH = 7;
    uint256 constant AMOUNT = 10;
    uint256 constant PRICE = 100e6; // $100

    function setUp() public {
        claimBond = new MockClaimBond();
        usdc = new MockBlacklistUSDC();

        LuminaBondMarketplace impl = new LuminaBondMarketplace();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                LuminaBondMarketplace.initialize.selector, address(claimBond), address(usdc), twapBurner, admin
            )
        );
        market = LuminaBondMarketplace(address(proxy));

        // Bond not matured.
        claimBond.setMaturity(EPOCH, block.timestamp + 365 days);

        // Seller lists.
        claimBond.mint(seller, EPOCH, AMOUNT);
        vm.prank(seller);
        market.list(EPOCH, AMOUNT, PRICE);

        // Buyer funds + approval.
        uint256 buyerFee = (PRICE * 150) / 10000;
        usdc.mint(buyer, PRICE + buyerFee);
        vm.prank(buyer);
        usdc.approve(address(market), type(uint256).max);
    }

    function test_BlacklistedSellerDoesNotBrickFill() public {
        // Seller is blacklisted on USDC: a push-transfer to them would revert.
        usdc.setBlacklist(seller, true);

        uint256 sellerFee = (PRICE * 150) / 10000;
        uint256 sellerReceives = PRICE - sellerFee;

        // The fill must STILL succeed (pull-payment): buyer gets the bond.
        vm.prank(buyer);
        market.executeBuy(0);

        assertEq(claimBond.balanceOf(buyer, EPOCH), AMOUNT, "buyer received bonds");
        // Seller proceeds are parked, not pushed.
        assertEq(market.pendingWithdrawals(seller), sellerReceives, "seller proceeds credited");
        // Fee reached the burner (burner not blacklisted).
        assertEq(usdc.balanceOf(twapBurner), sellerFee + ((PRICE * 150) / 10000), "fee to burner");
    }

    function test_SellerCanWithdraw() public {
        uint256 sellerFee = (PRICE * 150) / 10000;
        uint256 sellerReceives = PRICE - sellerFee;

        vm.prank(buyer);
        market.executeBuy(0);

        assertEq(market.pendingWithdrawals(seller), sellerReceives);

        // Seller (not blacklisted) pulls funds.
        vm.prank(seller);
        market.withdraw();

        assertEq(usdc.balanceOf(seller), sellerReceives, "seller withdrew proceeds");
        assertEq(market.pendingWithdrawals(seller), 0, "ledger zeroed");

        // Second withdraw reverts (nothing left).
        vm.prank(seller);
        vm.expectRevert(bytes("Nothing to withdraw"));
        market.withdraw();
    }

    function test_BlacklistedSellerCanWithdrawOnceUnblacklisted() public {
        usdc.setBlacklist(seller, true);
        vm.prank(buyer);
        market.executeBuy(0);

        // While blacklisted, withdraw reverts inside the USDC transfer.
        vm.prank(seller);
        vm.expectRevert(bytes("USDC: recipient blacklisted"));
        market.withdraw();

        // Once unblacklisted, funds are recoverable — no funds lost.
        usdc.setBlacklist(seller, false);
        uint256 sellerReceives = PRICE - (PRICE * 150) / 10000;
        vm.prank(seller);
        market.withdraw();
        assertEq(usdc.balanceOf(seller), sellerReceives);
    }
}
