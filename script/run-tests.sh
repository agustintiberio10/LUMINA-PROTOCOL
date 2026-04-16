#!/bin/bash
# Run the complete Lumina V2 test suite against a fresh clone.
# Requires: forge (foundry) + network access.
# Reproduces the passing state of commit after SR3.
set -e

REPO_URL="${REPO_URL:-https://github.com/org-lumina/LUMINA-PROTOCOL.git}"
WORK_DIR="${WORK_DIR:-/tmp/lumina-test}"

echo "=== Cloning fresh repo from $REPO_URL ==="
rm -rf "$WORK_DIR"
git clone "$REPO_URL" "$WORK_DIR"
cd "$WORK_DIR"

echo "=== Installing forge-std ==="
forge install foundry-rs/forge-std

echo "=== Installing OpenZeppelin (pinned in lib/) ==="
# OZ is already vendored in lib/openzeppelin-contracts. No install needed.
ls lib/openzeppelin-contracts/contracts > /dev/null || {
    echo "ERROR: lib/openzeppelin-contracts missing. Run: forge install OpenZeppelin/openzeppelin-contracts"
    exit 1
}

echo "=== Checking remappings ==="
grep -E "forge-std|openzeppelin" foundry.toml || {
    echo "ERROR: remappings missing in foundry.toml"
    exit 1
}

echo "=== Building ALL contracts (V2 only, archive excluded) ==="
forge build 2>&1
BUILD_EXIT=$?
if [ $BUILD_EXIT -ne 0 ]; then
    echo "BUILD FAILED"
    exit 1
fi
echo "BUILD PASSED"

echo "=== Running ALL tests ==="
forge test --no-match-path "archive/**" -vv 2>&1
TEST_EXIT=$?
if [ $TEST_EXIT -ne 0 ]; then
    echo "SOME TESTS FAILED"
    exit 1
fi
echo "ALL TESTS PASSED"

echo "=== Gas report for key flows ==="
forge test --no-match-path "archive/**" --gas-report --match-contract "BondVaultTest|CoverRouterV2Test|TWAPBurnerTest" 2>&1

echo "=== Done ==="
