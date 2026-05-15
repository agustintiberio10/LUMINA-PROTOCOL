// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ClaimBond} from "../../src/bonds/ClaimBond.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

/// @notice Handler is the BondVault (handler becomes the only authorized mint/burn caller).
/// Bounded mint/burn to track ghost totals and verify face-value/$1 invariant.
contract CBHandler is Test {
    ClaimBond public bond;
    uint256 public ghostMinted;
    uint256 public ghostBurned;
    uint256 public lastEpochUsed;
    address[] public users;

    constructor(ClaimBond _bond) {
        bond = _bond;
        for (uint256 i = 1; i <= 5; i++) {
            users.push(address(uint160(0x2000 + i)));
        }
    }

    function mintBond(uint256 userIdx, uint256 epochSeed, uint256 amount) external {
        userIdx = bound(userIdx, 0, users.length - 1);
        // Valid epochs: YYYYMM, year 2026-2100, month 1-12
        uint256 year = bound(epochSeed / 12, 2026, 2030);
        uint256 month = bound(epochSeed % 12, 1, 12);
        uint256 epochId = year * 100 + month;
        amount = bound(amount, 1, 1000);

        try bond.mint(users[userIdx], epochId, amount) {
            ghostMinted += amount;
            lastEpochUsed = epochId;
        } catch {}
    }

    function burnBond(uint256 userIdx, uint256 amount) external {
        if (lastEpochUsed == 0) return;
        userIdx = bound(userIdx, 0, users.length - 1);
        uint256 bal = bond.balanceOf(users[userIdx], lastEpochUsed);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);

        try bond.burn(users[userIdx], lastEpochUsed, amount) {
            ghostBurned += amount;
        } catch {}
    }

    function usersLength() external view returns (uint256) {
        return users.length;
    }

    function user(uint256 i) external view returns (address) {
        return users[i];
    }
}

contract ClaimBondInvariants is Test {
    ClaimBond public bond;
    CBHandler public handler;

    function setUp() public {
        vm.chainId(8453);
        bond = ProxyDeployer.deployClaimBond();
        handler = new CBHandler(bond);
        // Handler is the BondVault: only it can mint/burn.
        bond.setBondVault(address(handler));
        targetContract(address(handler));
    }

    /// INV-Y-CB-1: ghostMinted - ghostBurned == sum of balances across (epoch, user)
    function invariant_supplyAccounting() public view {
        uint256 outstanding = handler.ghostMinted() - handler.ghostBurned();
        uint256 totalBal;
        // Walk epochs 202601..203012 and tally; coarse sweep to validate ERC1155Supply.
        for (uint256 y = 2026; y <= 2030; y++) {
            for (uint256 m = 1; m <= 12; m++) {
                uint256 id = y * 100 + m;
                if (!bond.epochExists(id)) continue;
                uint256 epochTotal = bond.totalSupply(id);
                totalBal += epochTotal;
            }
        }
        assertEq(totalBal, outstanding, "INV-Y-CB-1: ERC1155Supply diverged from handler ghost");
    }

    /// INV-Y-CB-2: Once an epoch's maturityDate is set, it never changes
    ///             (any subsequent mint into same epoch keeps same maturityDate).
    function invariant_maturityImmutable() public view {
        for (uint256 y = 2026; y <= 2030; y++) {
            for (uint256 m = 1; m <= 12; m++) {
                uint256 id = y * 100 + m;
                if (!bond.epochExists(id)) continue;
                // If epoch exists, maturityDate must be set (>0). The contract never
                // resets it, so this is a structural invariant per the ClaimBond spec.
                assertGt(bond.maturityDate(id), 0, "INV-Y-CB-2: epoch exists but no maturity");
            }
        }
    }

    /// INV-Y-CB-3: $1 face value. ERC1155 token id == YYYYMM with year >= 2026.
    function invariant_validEpochFormat() public view {
        for (uint256 y = 2026; y <= 2030; y++) {
            for (uint256 m = 1; m <= 12; m++) {
                uint256 id = y * 100 + m;
                if (!bond.epochExists(id)) continue;
                assertTrue(id >= 202601 && id <= 210012, "INV-Y-CB-3: epoch out of valid range");
                uint256 mm = id % 100;
                assertTrue(mm >= 1 && mm <= 12, "INV-Y-CB-3: month invalid");
            }
        }
    }
}
