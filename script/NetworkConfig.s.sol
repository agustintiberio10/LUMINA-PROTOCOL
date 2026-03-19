// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title NetworkConfig — Base Mainnet addresses for Lumina Protocol
library NetworkConfig {
    // Settlement token: USDC (Circle) on Base Mainnet — 6 decimals
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // Chainlink price feeds on Base Mainnet
    address constant ETH_USD_ORACLE = 0x71041ddDad3595F8cEd3DcbcBE31195759958911;
    address constant BTC_USD_ORACLE = 0x45c32AEd995834F0A484FD092953258814774393;

    // Aave V3 on Base Mainnet
    address constant AAVE_POOL = 0xA238Dd80C259A72E81D7E4674A5471b2F0730305;
    address constant A_BAS_USDC = 0x4E65fe4dBA92790696D040BC24AA58D91f263A70;
}
