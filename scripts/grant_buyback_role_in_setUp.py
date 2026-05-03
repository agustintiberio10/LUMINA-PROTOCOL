"""For every test file that contains a `[Fix M-10 patch]` block (i.e.
calls our new commit-reveal flow) AND a `ProxyDeployer.deployBuybackEngine`
call, inject a role-grant snippet right after the deploy so `address(this)`
holds `BUYBACK_OPERATOR_ROLE`. Without this, the patched call sites that
previously relied on permissionless `executeOffer` revert with
AccessControlUnauthorizedAccount.

Idempotent — looks for marker `[M-10 grant]` to avoid double-injection."""

import re
from pathlib import Path

TEST_ROOT = Path(r"C:\Users\AGUSTIN\AppData\Local\Temp\fix-m10\test")
MARKER = "// [M-10 grant]"


def split_args(arg_text: str) -> list[str]:
    args, depth, cur = [], 0, []
    for ch in arg_text:
        if ch == "," and depth == 0:
            args.append("".join(cur).strip()); cur = []; continue
        if ch == "(": depth += 1
        elif ch == ")": depth -= 1
        cur.append(ch)
    if cur: args.append("".join(cur).strip())
    # Strip inline `//` comments from each argument so the captured text
    # is safe to embed inside another expression (e.g. `vm.prank(arg)`).
    cleaned = []
    for a in args:
        # Drop everything from the first `//` onward (only at top level —
        # the args have already been split, so we don't need to worry
        # about strings in this code base).
        idx = a.find("//")
        if idx != -1:
            a = a[:idx]
        cleaned.append(a.strip())
    return cleaned


def find_deploy(src: str):
    """Yield (insert_pos, var_name, multisig_arg) per deploy call."""
    out = []
    pat = re.compile(r"([A-Za-z_][A-Za-z0-9_.]*)\s*=\s*ProxyDeployer\.deployBuybackEngine\(")
    for m in pat.finditer(src):
        var = m.group(1)
        i = m.end()
        depth = 1
        while i < len(src) and depth > 0:
            if src[i] == "(": depth += 1
            elif src[i] == ")": depth -= 1
            i += 1
        if depth != 0:
            continue
        close_paren = i
        semi = src.find(";", close_paren)
        if semi == -1:
            continue
        nl = src.find("\n", semi)
        nl = nl + 1 if nl != -1 else semi + 1
        arg_text = src[m.end():close_paren - 1]
        args = split_args(arg_text)
        if len(args) != 7:
            continue
        multisig = args[6]
        out.append((nl, var, multisig))
    return out


def patch_file(path: Path) -> tuple[bool, int]:
    src = path.read_text(encoding="utf-8")
    if "[Fix M-10 patch]" not in src:
        return False, 0
    if MARKER in src:
        return False, 0

    deploys = find_deploy(src)
    if not deploys:
        return False, 0

    out = src
    for nl, var, multisig in reversed(deploys):
        # Determine the indent of the deploy line.
        line_start = out.rfind("\n", 0, nl - 1) + 1
        line = out[line_start:nl - 1]
        indent_match = re.match(r"^(\s*)", line)
        indent = indent_match.group(1) if indent_match else ""
        # Use a unique-ish local var name based on the LHS.
        safe_var = re.sub(r"[^A-Za-z0-9_]", "_", var)
        snippet = (
            f"{indent}{MARKER} grant BUYBACK_OPERATOR_ROLE to address(this) so test calls reach the gated path.\n"
            f"{indent}{{\n"
            f"{indent}    bytes32 _m10_role_{safe_var} = {var}.BUYBACK_OPERATOR_ROLE();\n"
            f"{indent}    vm.prank({multisig});\n"
            f"{indent}    {var}.grantRole(_m10_role_{safe_var}, address(this));\n"
            f"{indent}}}\n"
        )
        out = out[:nl] + snippet + out[nl:]

    path.write_text(out, encoding="utf-8")
    return True, len(deploys)


def main() -> None:
    files = sorted(TEST_ROOT.rglob("*.sol"))
    total_files, total_grants = 0, 0
    for f in files:
        ok, n = patch_file(f)
        if ok:
            total_files += 1
            total_grants += n
            print(f"  OK {f.relative_to(TEST_ROOT)}: {n} grant(s) injected")
    print(f"\nDone: {total_files} files patched, {total_grants} grant(s) injected.")


if __name__ == "__main__":
    main()
