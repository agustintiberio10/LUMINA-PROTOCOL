#!/usr/bin/env python3
"""
Lumina Protocol — OWS Custom Policy
Only allows transactions to Lumina contracts on Base.
"""
import json, sys

# Lumina contract addresses (update after production deploy)
ALLOWED_CONTRACTS = {
    # USDC (production)
    "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
    # Test MockUSDC
    "0x8a342233cfc95f4aeb11c2855bff1f441241e8d1",
    # CoverRouter
    "0x5755af9cd293b9a0a798b7e2e816eabe659750c0",
    # PolicyManager
    "0x5b337325b854a68cd262aa2b6fe48ebe18073902",
    # Vaults
    "0xe74d19551cbb809aadcab568c0e150b6bf0e3354",
    "0xc0016248e171b2a20fb0c212ab917ab7fa07502a",
    "0xa682dc763e6a99607797989c5f44c8aa05a8511e",
    "0xe5e3f6898eeceea4245558429cbfae9ce255c05e",
    # Shields
    "0x149e1d0474a7c212a5eaa78432863b01b98479d8",
    "0xad1eb669b4a9dc6c9432b904f65b360962e1d381",
    "0xc2262311ed02e9c937cbc33f34426d5d9134f6cf",
    "0x931427ced326eb49a3e5268b9b3e713eb2ec5440",
}

try:
    ctx = json.load(sys.stdin)
    tx = ctx.get("transaction", {})
    to_addr = tx.get("to", "").lower()

    if not to_addr:
        json.dump({"allow": False, "reason": "No recipient address in transaction"}, sys.stdout)
    elif to_addr in ALLOWED_CONTRACTS:
        json.dump({"allow": True}, sys.stdout)
    else:
        json.dump({
            "allow": False,
            "reason": f"Recipient {to_addr} is not a Lumina contract. Only Lumina Protocol contracts are allowed."
        }, sys.stdout)
except Exception as e:
    json.dump({"allow": False, "reason": f"Policy error: {str(e)}"}, sys.stdout)
