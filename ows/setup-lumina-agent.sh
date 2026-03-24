#!/bin/bash
# ═══════════════════════════════════════════════════════════
# Lumina Protocol — OWS Agent Setup
# Creates a secure wallet for your AI agent with policies
# ═══════════════════════════════════════════════════════════

set -e

AGENT_NAME="${1:-lumina-agent}"
POLICY_DIR="$(dirname "$0")/policies"

echo "═══════════════════════════════════════════"
echo "  Lumina Protocol — OWS Agent Setup"
echo "═══════════════════════════════════════════"
echo ""
echo "Agent name: $AGENT_NAME"
echo ""

# 1. Check OWS is installed
if ! command -v ows &> /dev/null; then
    echo "OWS not found. Installing..."
    curl -fsSL https://openwallet.sh/install.sh | bash
fi

echo "OWS version: $(ows --version)"
echo ""

# 2. Create wallet
echo "[1/4] Creating wallet..."
ows wallet create --name "$AGENT_NAME"
echo ""

# 3. Show address (user needs to fund this)
echo "[2/4] Wallet created. Address:"
ows wallet list
echo ""
echo "⚠️  Fund this address with:"
echo "  - USDC on Base (for insurance premiums)"
echo "  - ETH on Base (for gas, ~$5)"
echo ""

# 4. Install policies
echo "[3/4] Installing Lumina policies..."

if [ -f "$POLICY_DIR/lumina-base-only.json" ]; then
    ows policy create --file "$POLICY_DIR/lumina-base-only.json"
    echo "  ✓ Base-only chain restriction"
fi

if [ -f "$POLICY_DIR/lumina-full-protection.json" ]; then
    # Copy executable to OWS plugins dir
    mkdir -p ~/.ows/plugins/policies/
    cp "$POLICY_DIR/lumina-contracts-allowlist.py" ~/.ows/plugins/policies/
    cp "$POLICY_DIR/lumina-spending-limit.py" ~/.ows/plugins/policies/
    chmod +x ~/.ows/plugins/policies/*.py

    # Update executable path in policy
    sed "s|lumina-contracts-allowlist.py|$HOME/.ows/plugins/policies/lumina-contracts-allowlist.py|" \
        "$POLICY_DIR/lumina-full-protection.json" > /tmp/lumina-full-protection.json
    ows policy create --file /tmp/lumina-full-protection.json
    echo "  ✓ Contract allowlist (only Lumina contracts)"
    echo "  ✓ Daily spending limit ($10,000)"
fi
echo ""

# 5. Create API key
echo "[4/4] Creating API key with policies..."
ows key create --name "$AGENT_NAME-key" --wallet "$AGENT_NAME" --policy lumina-base-only --policy lumina-full-protection
echo ""

echo "═══════════════════════════════════════════"
echo "  SETUP COMPLETE"
echo "═══════════════════════════════════════════"
echo ""
echo "Save the ows_key_xxx token above!"
echo "Add it to your agent's environment:"
echo "  export OWS_TOKEN=ows_key_xxx"
echo ""
echo "Your agent can now operate Lumina with:"
echo "  ✓ Base L2 only (no other chains)"
echo "  ✓ Lumina contracts only (no random approves)"
echo "  ✓ \$10,000/day spending limit"
echo "  ✓ Auto-expires Jan 1, 2027"
echo ""
echo "To revoke access: ows key revoke --name $AGENT_NAME-key"
