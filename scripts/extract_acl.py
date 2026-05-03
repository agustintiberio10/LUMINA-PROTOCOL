"""Parse every .sol file in src/ and emit a function -> modifier table
for the access-control matrix. Filters to functions that carry at least
one access-control modifier (onlyOwner, onlyRole, etc.) and skips the
shield products (their admin surface is the same setOracle/setRouter
inherited from BaseShield)."""

import os
import re

SRC = r"C:\Users\AGUSTIN\AppData\Local\Temp\fix-m1\src"

# What counts as an access-control modifier.
AC_MOD_PAT = re.compile(
    r"\b(onlyOwner|onlyRole\([^)]*\)|onlyRouter|onlyAdmin|onlyMultisig)\b"
)

# Capture: optional doc comments + function signature up to opening brace.
# Multiline because Solidity wraps long signatures.
FN_PAT = re.compile(
    r"function\s+(\w+)\s*\(([^)]*)\)"
    r"((?:\s+\w+(?:\([^)]*\))?)*)"  # modifiers / visibility / view
    r"\s*(?:returns\s*\([^)]*\))?\s*\{",
    re.DOTALL,
)

def parse_contract(path: str) -> list[tuple[str, str]]:
    with open(path, "r", encoding="utf-8") as f:
        src = f.read()
    rows = []
    for m in FN_PAT.finditer(src):
        name = m.group(1)
        mods = m.group(3)
        ac = AC_MOD_PAT.findall(mods)
        if not ac:
            continue
        # Compress role names: e.g. `onlyRole(ALLOCATOR_ROLE)` -> "ALLOCATOR_ROLE"
        compressed = []
        for a in ac:
            r = re.match(r"onlyRole\(([^)]+)\)", a)
            if r:
                compressed.append(r.group(1).strip())
            else:
                compressed.append(a)
        rows.append((name, ", ".join(compressed)))
    return rows


def main() -> None:
    out_lines: list[str] = []
    for dp, _, fs in sorted(os.walk(SRC)):
        for fn in sorted(fs):
            if not fn.endswith(".sol"):
                continue
            # Skip interfaces and shields' admin surface (covered by BaseShield).
            if "interfaces" in dp:
                continue
            if "products" in dp and fn != "BaseShield.sol":
                continue
            path = os.path.join(dp, fn)
            rows = parse_contract(path)
            if not rows:
                continue
            rel = os.path.relpath(path, SRC).replace("\\", "/")
            out_lines.append(f"### {rel}")
            out_lines.append("")
            out_lines.append("| Function | Access Control |")
            out_lines.append("|---|---|")
            for name, ac in rows:
                out_lines.append(f"| `{name}` | `{ac}` |")
            out_lines.append("")
    print("\n".join(out_lines))


if __name__ == "__main__":
    main()
