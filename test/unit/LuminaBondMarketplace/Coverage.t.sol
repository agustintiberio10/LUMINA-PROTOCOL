// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {LuminaBondMarketplace} from "../../../src/marketplace/LuminaBondMarketplace.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

contract LuminaBondMarketplaceCoverage is Test {
    LuminaBondMarketplace mp;
    address claimBond = makeAddr("claimBond");
    address usdc = makeAddr("usdc");
    address twapBurner = makeAddr("twapBurner");
    address admin = makeAddr("admin");

    function setUp() public {
        mp = ProxyDeployer.deployLuminaBondMarketplace(claimBond, usdc, twapBurner, admin);
    }

    /// Covers L208-215 supportsInterface body — AccessControl + ERC1155Holder + ERC165.
    function test_SupportsInterface_IERC165() public view {
        assertTrue(mp.supportsInterface(type(IERC165).interfaceId));
    }

    function test_SupportsInterface_IAccessControl() public view {
        assertTrue(mp.supportsInterface(type(IAccessControl).interfaceId));
    }

    function test_SupportsInterface_IERC1155Receiver() public view {
        assertTrue(mp.supportsInterface(type(IERC1155Receiver).interfaceId));
    }

    function test_SupportsInterface_RandomInterface_Returns_False() public view {
        assertFalse(mp.supportsInterface(0xdeadbeef));
    }
}
