// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../src/token/LuminaTokenV2.sol";

contract LuminaTokenV2Test is Test {
    LuminaTokenV2 token;
    address bondVault = makeAddr("bondVault");
    address cexReserve = makeAddr("cexReserve");
    address founderVesting = makeAddr("founderVesting");
    address lbpDeposit = makeAddr("lbpDeposit");
    address treasuryVesting = makeAddr("treasuryVesting");
    address deployer;

    function setUp() public {
        deployer = address(this);

        // Deploy implementation
        LuminaTokenV2 impl = new LuminaTokenV2();

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            LuminaTokenV2.initialize.selector, bondVault, cexReserve, founderVesting, lbpDeposit, treasuryVesting
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        token = LuminaTokenV2(address(proxy));
    }

    function test_totalSupply() public view {
        assertEq(token.totalSupply(), 100_000_000 * 1e18);
    }

    function test_distribution() public view {
        assertEq(token.balanceOf(bondVault), 70_000_000 * 1e18);
        assertEq(token.balanceOf(cexReserve), 14_000_000 * 1e18);
        assertEq(token.balanceOf(founderVesting), 8_000_000 * 1e18);
        assertEq(token.balanceOf(lbpDeposit), 5_000_000 * 1e18);
        assertEq(token.balanceOf(treasuryVesting), 3_000_000 * 1e18);
    }

    function test_noMint() public view {
        assertEq(token.totalSupply(), token.MAX_SUPPLY());
    }

    function test_totalBurned_initially_zero() public view {
        assertEq(token.totalBurned(), 0);
    }

    function test_burn_reduces_supply() public {
        vm.prank(lbpDeposit);
        token.burn(1000 * 1e18);
        assertEq(token.totalBurned(), 1000 * 1e18);
        assertEq(token.totalSupply(), 100_000_000 * 1e18 - 1000 * 1e18);
    }

    function test_burnerRole_can_burnFrom() public {
        token.grantRole(token.BURNER_ROLE(), deployer);
        vm.prank(lbpDeposit);
        token.approve(deployer, 500 * 1e18);
        token.burnFrom(lbpDeposit, 500 * 1e18);
        assertEq(token.totalBurned(), 500 * 1e18);
    }

    function test_nonBurner_cannot_burnFrom() public {
        address random = makeAddr("random");
        vm.prank(random);
        vm.expectRevert();
        token.burnFrom(lbpDeposit, 100 * 1e18);
    }

    function test_zeroAddress_reverts() public {
        LuminaTokenV2 impl = new LuminaTokenV2();

        vm.expectRevert();
        new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                LuminaTokenV2.initialize.selector, address(0), cexReserve, founderVesting, lbpDeposit, treasuryVesting
            )
        );

        vm.expectRevert();
        new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                LuminaTokenV2.initialize.selector, bondVault, address(0), founderVesting, lbpDeposit, treasuryVesting
            )
        );
    }

    function test_duplicateRecipient_reverts() public {
        LuminaTokenV2 impl = new LuminaTokenV2();

        vm.expectRevert();
        new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                LuminaTokenV2.initialize.selector, bondVault, cexReserve, founderVesting, lbpDeposit, bondVault
            )
        );

        vm.expectRevert();
        new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                LuminaTokenV2.initialize.selector, bondVault, bondVault, founderVesting, lbpDeposit, treasuryVesting
            )
        );

        vm.expectRevert();
        new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                LuminaTokenV2.initialize.selector, bondVault, cexReserve, cexReserve, lbpDeposit, treasuryVesting
            )
        );
    }

    function test_name_and_symbol() public view {
        assertEq(token.name(), "Lumina Protocol");
        assertEq(token.symbol(), "LUMINA");
    }

    function test_cannot_initialize_twice() public {
        vm.expectRevert();
        token.initialize(bondVault, cexReserve, founderVesting, lbpDeposit, treasuryVesting);
    }

    function test_implementation_cannot_be_initialized() public {
        LuminaTokenV2 impl = new LuminaTokenV2();
        vm.expectRevert();
        impl.initialize(bondVault, cexReserve, founderVesting, lbpDeposit, treasuryVesting);
    }
}
