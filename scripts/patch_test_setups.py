"""Lower the M-3 minPricePerUnit floor to 1 wei in legacy test setUps.

The fix M-3 adds a 1-USDC/unit floor to LuminaBondMarketplace.list(). Many
existing tests use pricePerUnit < 1 USDC for arbitrary numerical reasons
(testing fee math, race conditions, etc) - they are not testing the floor
itself. To keep them passing without rewriting every numeric assertion,
this script injects a setMinPricePerUnit(1) call right after the marketplace
is deployed in each affected test's setUp.

The 4th argument of `deployLuminaBondMarketplace(claimBond, usdc, twapBurner,
admin)` is the admin we need to vm.prank from. The script parses it out of
the call rather than guessing - call sites use `admin`, `multisig`, or
`address(this)` interchangeably.
"""

import re
from pathlib import Path

TEST_ROOT = Path(r"C:\Users\AGUSTIN\AppData\Local\Temp\fix-m3\test")

TARGETS = [
    "marketplace/LuminaBondMarketplaceTest.t.sol",
    "attacks/AttackVectors.t.sol",
    "audit/phase7/EconomicExploits.t.sol",
    "audit/phase7/ReentrancyAttacks.t.sol",
    "audit/race/RaceConditions.t.sol",
    "audit/v5.1-uups/integration/e2e/E2EIntegration.t.sol",
    "audit/v5.1-uups/performance/dos/DOSAttacks.t.sol",
    "audit/v5.1-uups/performance/stress/StressVolume.t.sol",
    "audit/v5.1-uups/token-nft/approvals/FixM03BuybackApproval.t.sol",
    "audit/v5.1-uups/token-nft/approvals/TokenApprovals.t.sol",
    "audit/v5.1-uups/token-nft/NFTMetadataFix.t.sol",
    "functional/roles/BondSecondaryBuyerRole.t.sol",
    "functional/UserJourneys.t.sol",
    "integration/scenarios/UpgradePaths.t.sol",
    "simulation/MarketplaceAndRedemption.t.sol",
]


def split_args(arg_text: str) -> list[str]:
    """Split a comma-separated argument list while respecting parentheses."""
    args = []
    depth = 0
    cur = []
    for ch in arg_text:
        if ch == "," and depth == 0:
            args.append("".join(cur).strip())
            cur = []
            continue
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        cur.append(ch)
    if cur:
        args.append("".join(cur).strip())
    return args


def find_deploy_calls(src: str):
    """Yield (start_idx, end_idx_after_semicolon, var_name, admin_expr)
    for every `<lhs> = ProxyDeployer.deployLuminaBondMarketplace(...)` call."""
    out = []
    pat = re.compile(
        r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*ProxyDeployer\.deployLuminaBondMarketplace\("
    )
    for m in pat.finditer(src):
        var = m.group(1)
        # Find the matching close-paren for the call.
        i = m.end()
        depth = 1
        while i < len(src) and depth > 0:
            if src[i] == "(":
                depth += 1
            elif src[i] == ")":
                depth -= 1
            i += 1
        if depth != 0:
            continue
        close_paren = i  # position right after the closing ')'
        # Then find the terminating ';'
        semi = src.find(";", close_paren)
        if semi == -1:
            continue
        # Newline after the semicolon
        nl = src.find("\n", semi)
        nl = nl + 1 if nl != -1 else semi + 1
        arg_text = src[m.end():close_paren - 1]
        args = split_args(arg_text)
        if len(args) != 4:
            # signature has 4 args; if not, skip
            continue
        admin_expr = args[3]
        out.append((m.start(), nl, var, admin_expr))
    return out


def patch_file(path: Path) -> tuple[bool, str]:
    src = path.read_text(encoding="utf-8")
    if "[Fix M-3 regression]" in src:
        return False, "already-patched"

    calls = find_deploy_calls(src)
    if not calls:
        return False, "no-deploy-found"

    # Inject after each deploy line, walking backwards.
    out = src
    for _, nl, var, admin_expr in reversed(calls):
        # Match the indentation of the line containing `nl - 1` (the end-of-line).
        line_start = out.rfind("\n", 0, nl - 1) + 1
        line = out[line_start:nl - 1]
        indent = re.match(r"^(\s*)", line).group(1)
        injection = (
            f"{indent}// [Fix M-3 regression] Lower the per-unit price floor for this legacy\n"
            f"{indent}// test - it predates the M-3 spam floor and uses arbitrary price/amount\n"
            f"{indent}// ratios that aren't relevant to the M-3 behavior under test.\n"
            f"{indent}vm.prank({admin_expr});\n"
            f"{indent}{var}.setMinPricePerUnit(1);\n"
        )
        out = out[:nl] + injection + out[nl:]

    path.write_text(out, encoding="utf-8")
    return True, f"patched-{len(calls)}-deploy-call(s)"


def main() -> None:
    for rel in TARGETS:
        p = TEST_ROOT / rel
        if not p.exists():
            print(f"  -- {rel}: not-found")
            continue
        ok, status = patch_file(p)
        prefix = "OK" if ok else ".."
        print(f"  {prefix} {rel}: {status}")


if __name__ == "__main__":
    main()
