// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {LuminaTokenV2} from "../../../src/token/LuminaTokenV2.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

contract LuminaTokenV2Events is Test {
    event BurnedFromHolder(address indexed burner, address indexed account, uint256 amount);

    LuminaTokenV2 token;
    address burner = makeAddr("burner");
    address bondVault = makeAddr("bondVault");
    address cexReserve = makeAddr("cexReserve");
    address founderVesting = makeAddr("founderVesting");
    address lbpDeposit = makeAddr("lbpDeposit");
    address treasuryVesting = makeAddr("treasuryVesting");

    function setUp() public {
        token = ProxyDeployer.deployLuminaTokenV2(bondVault, cexReserve, founderVesting, lbpDeposit, treasuryVesting);
        token.grantRole(token.BURNER_ROLE(), burner);
    }

    function test_Event_BurnedFromHolder_Emitted() public {
        vm.expectEmit(true, true, false, true);
        emit BurnedFromHolder(burner, bondVault, 100e18);
        vm.prank(burner);
        token.burnFrom(bondVault, 100e18);
    }
}
