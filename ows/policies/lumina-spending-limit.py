#!/usr/bin/env python3
"""
Lumina Protocol — OWS Spending Limit Policy
Limits daily spending to a configurable amount.
"""
import json, sys, os, time

DAILY_LIMIT_USD = 10000  # $10,000 per day default
SPENDING_FILE = os.path.expanduser("~/.ows/lumina-spending.json")


def load_spending():
    try:
        with open(SPENDING_FILE) as f:
            data = json.load(f)
            if data.get("date") != time.strftime("%Y-%m-%d"):
                return {"date": time.strftime("%Y-%m-%d"), "total": 0}
            return data
    except Exception:
        return {"date": time.strftime("%Y-%m-%d"), "total": 0}


def save_spending(data):
    os.makedirs(os.path.dirname(SPENDING_FILE), exist_ok=True)
    with open(SPENDING_FILE, "w") as f:
        json.dump(data, f)


try:
    ctx = json.load(sys.stdin)
    config = ctx.get("policy_config", {})
    limit = config.get("daily_limit_usd", DAILY_LIMIT_USD)

    # Estimate transaction value from tx data (simplified)
    tx = ctx.get("transaction", {})
    value_wei = int(tx.get("value", "0"), 16) if isinstance(tx.get("value"), str) else int(tx.get("value", 0))
    # For USDC approve/transfer, the value is in the calldata, not tx.value
    # This is a simplified check — a production policy would decode the calldata
    estimated_usd = value_wei / 1e18 * 2000  # rough ETH→USD (for ETH transfers)

    spending = load_spending()

    if spending["total"] + estimated_usd > limit:
        json.dump({
            "allow": False,
            "reason": f"Daily spending limit reached. Spent: ${spending['total']:.2f}, Limit: ${limit:.2f}"
        }, sys.stdout)
    else:
        spending["total"] += estimated_usd
        save_spending(spending)
        json.dump({"allow": True}, sys.stdout)

except Exception as e:
    json.dump({"allow": False, "reason": f"Spending policy error: {str(e)}"}, sys.stdout)
