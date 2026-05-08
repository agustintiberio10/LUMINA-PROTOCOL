// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

interface ICoverRouterV2 {
    function setRelayer(address relayer, bool authorized) external;
    function authorizedRelayers(address) external view returns (bool);
    function owner() external view returns (address);
}

/// @title AuthorizeRelayer
/// @notice One-shot ops script that grants the lumina-api relayer service
///         permission to call CoverRouterV2.purchasePolicyFor on Base Sepolia.
///         Fixes the agent-ux-stress-test blocker #1 (every POST /api/v1/policies
///         returned 503 relayer_unauthorized).
contract AuthorizeRelayer is Script {
    address constant ROUTER = 0xebC3A783477FbD2720C024e16A8d63B8Db983D84;
    address constant RELAYER = 0x168dC7105e907294f9d066cee24f30caa5A17E4a;

    function run() external {
        require(block.chainid == 84532, "wrong chain (Base Sepolia only)");

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address sender = vm.addr(deployerKey);
        address routerOwner = ICoverRouterV2(ROUTER).owner();
        require(sender == routerOwner, "PRIVATE_KEY is not router owner");

        bool already = ICoverRouterV2(ROUTER).authorizedRelayers(RELAYER);
        console.log("Router owner:        ", routerOwner);
        console.log("Relayer:             ", RELAYER);
        console.log("Already authorized?: ", already);

        if (already) {
            console.log("No-op: relayer already authorized.");
            return;
        }

        vm.startBroadcast(deployerKey);
        ICoverRouterV2(ROUTER).setRelayer(RELAYER, true);
        vm.stopBroadcast();

        bool nowAuthorized = ICoverRouterV2(ROUTER).authorizedRelayers(RELAYER);
        require(nowAuthorized, "post-tx: relayer NOT authorized");
        console.log("OK relayer authorized.");
    }
}
