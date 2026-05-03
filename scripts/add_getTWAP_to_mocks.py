"""Bulk-add `getTWAP(uint32) returns (uint256)` to every mock in test/
that currently implements `getLuminaPrice() external view returns (uint256)`.
The M-6 fix extends the IPriceOracle interface, so every mock that BondVault
treats as IPriceOracle must also expose getTWAP.

Strategy: insert a getTWAP function right after the closing brace of
getLuminaPrice's body. By default it returns the same value as getLuminaPrice
(so legacy tests that don't care about the TWAP path are unaffected)."""

import re
from pathlib import Path

TEST_ROOT = Path(r"C:\Users\AGUSTIN\AppData\Local\Temp\fix-m6\test")

# Match `function getLuminaPrice() ... { <body> }` then we'll insert after.
# We accept any visibility/modifiers between the parens and the first `{`.
LUMINA_FN_RE = re.compile(
    r"function\s+getLuminaPrice\s*\(\s*\)\s*"
    r"(?P<rest>[^{]*)"   # external view returns (uint256) etc.
    r"\{",
    re.DOTALL,
)

INJECT_TEMPLATE = """
    /// @dev [Fix M-6 mock] Returns the same value as `getLuminaPrice()` so
    ///      tests that don't drive the TWAP path explicitly remain unaffected.
    function getTWAP(uint32 /*secondsAgo*/) external view returns (uint256) {
        return this.getLuminaPrice();
    }
"""


def already_has_twap(src: str) -> bool:
    return bool(re.search(r"function\s+getTWAP\s*\(", src))


def patch_file(path: Path) -> tuple[bool, str]:
    src = path.read_text(encoding="utf-8")
    if already_has_twap(src):
        return False, "already-has-getTWAP"
    if not LUMINA_FN_RE.search(src):
        return False, "no-getLuminaPrice"

    out = src
    # We may need to inject after the closing `}` of getLuminaPrice. To find
    # that, walk braces from the `{` we matched.
    matches = list(LUMINA_FN_RE.finditer(src))
    if not matches:
        return False, "no-match-after-check"

    # Walk backwards so offsets stay valid.
    inserted = 0
    for m in reversed(matches):
        # Find the close of the function body starting from m.end() - 1 (the `{`).
        i = m.end()  # position right after `{`
        depth = 1
        while i < len(out) and depth > 0:
            if out[i] == "{":
                depth += 1
            elif out[i] == "}":
                depth -= 1
            i += 1
        if depth != 0:
            continue
        # Insert AFTER the closing `}` (i now points 1 past it).
        out = out[:i] + INJECT_TEMPLATE + out[i:]
        inserted += 1

    if inserted == 0:
        return False, "could-not-find-closing-brace"

    path.write_text(out, encoding="utf-8")
    return True, f"injected-{inserted}-getTWAP"


def main() -> None:
    files = sorted(TEST_ROOT.rglob("*.sol"))
    patched = 0
    skipped = 0
    for f in files:
        rel = f.relative_to(TEST_ROOT)
        ok, status = patch_file(f)
        if ok:
            patched += 1
            print(f"  OK {rel}: {status}")
        else:
            if status == "no-getLuminaPrice":
                continue
            skipped += 1
            print(f"  .. {rel}: {status}")
    print(f"\nDone: {patched} patched, {skipped} skipped (had reason).")


if __name__ == "__main__":
    main()
