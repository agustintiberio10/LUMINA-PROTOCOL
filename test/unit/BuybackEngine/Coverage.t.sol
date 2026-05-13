// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {BuybackEngine} from "../../../src/marketplace/BuybackEngine.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

contract BuybackEngineCoverage is Test {
    BuybackEngine engine;
    address claimBond = makeAddr("claimBond");
    address bondVault = makeAddr("bondVault");
    address solvencyOracle = makeAddr("solvencyOracle");
    address capacityOracle = makeAddr("capacityOracle");
    address marketplace = makeAddr("marketplace");
    address usdc = makeAddr("usdc");
    address admin = makeAddr("admin");

    function setUp() public {
        engine = ProxyDeployer.deployBuybackEngine(
            claimBond, bondVault, solvencyOracle, capacityOracle, marketplace, usdc, admin
        );
    }

    /// Covers L198-205 supportsInterface body — AccessControl + ERC1155Holder + ERC165.
    function test_SupportsInterface_IERC165() public view {
        assertTrue(engine.supportsInterface(type(IERC165).interfaceId));
    }

    function test_SupportsInterface_IAccessControl() public view {
        assertTrue(engine.supportsInterface(type(IAccessControl).interfaceId));
    }

    function test_SupportsInterface_IERC1155Receiver() public view {
        assertTrue(engine.supportsInterface(type(IERC1155Receiver).interfaceId));
    }

    function test_SupportsInterface_RandomInterface_Returns_False() public view {
        assertFalse(engine.supportsInterface(0xdeadbeef));
    }
}
