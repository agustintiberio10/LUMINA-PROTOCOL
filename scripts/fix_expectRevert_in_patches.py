"""When the previous patch script wrapped `executeOffer(X)` calls in a
commit-reveal block, any `vm.expectRevert(...)` line that immediately
preceded the call now applies to the FIRST call inside the block — which
is `commitBuyback`, NOT the intended `revealAndExecute`.

This second-pass script:
1. Finds every `vm.expectRevert(...)` line that directly precedes a
   `// [Fix M-10 patch]` block (allowing whitespace + comments between).
2. Moves it to the line right BEFORE `<engine>.revealAndExecute(...)`
   inside the block.

Idempotent — looks for a marker comment `// [M-10 expectRevert moved]`
to avoid double-moves."""

import re
from pathlib import Path

TEST_ROOT = Path(r"C:\Users\AGUSTIN\AppData\Local\Temp\fix-m10\test")

# The marker indicating the patcher already ran.
MARKER = "// [M-10 expectRevert moved]"


def fix_file(path: Path) -> tuple[bool, int]:
    src = path.read_text(encoding="utf-8")
    if MARKER in src:
        return False, 0

    lines = src.split("\n")
    out_lines: list[str] = []
    n_fixed = 0
    i = 0
    while i < len(lines):
        line = lines[i]
        # Look for `vm.expectRevert(...)` at any indent.
        m = re.match(r"^(\s*)vm\.expectRevert\b.*;\s*$", line)
        if not m:
            out_lines.append(line)
            i += 1
            continue
        # Look ahead a few lines for `// [Fix M-10 patch]`.
        # Skip blank lines + comments.
        j = i + 1
        found_patch = False
        while j < len(lines) and j < i + 5:
            jline = lines[j]
            stripped = jline.strip()
            if stripped == "":
                j += 1
                continue
            if "[Fix M-10 patch]" in stripped:
                found_patch = True
                break
            # Any other content — abort the look-ahead.
            break
        if not found_patch:
            out_lines.append(line)
            i += 1
            continue

        # We have an expectRevert line followed by an M-10 patch block.
        # Strategy:
        #   - Drop the original expectRevert line.
        #   - Append the rest up to the `revealAndExecute` line UNCHANGED.
        #   - Insert the expectRevert RIGHT BEFORE the revealAndExecute line.
        expect_line = line.rstrip()
        # Append lines from i+1 onward until we hit the revealAndExecute line.
        i += 1  # skip expectRevert
        while i < len(lines):
            kline = lines[i]
            if "revealAndExecute(" in kline:
                # Insert the expectRevert line above with the SAME indent
                # as the revealAndExecute line.
                indent_match = re.match(r"^(\s*)", kline)
                indent = indent_match.group(1) if indent_match else ""
                # Re-indent expect_line to match the target line.
                expect_stripped = expect_line.lstrip()
                out_lines.append(f"{indent}{MARKER}")
                out_lines.append(f"{indent}{expect_stripped}")
                out_lines.append(kline)
                i += 1
                n_fixed += 1
                break
            else:
                out_lines.append(kline)
                i += 1
        else:
            # Didn't find revealAndExecute — restore the original expectRevert.
            out_lines.append(expect_line)

    new_src = "\n".join(out_lines)
    if new_src == src:
        return False, 0

    path.write_text(new_src, encoding="utf-8")
    return True, n_fixed


def main() -> None:
    files = sorted(TEST_ROOT.rglob("*.sol"))
    total_files = 0
    total_fixes = 0
    for f in files:
        ok, n = fix_file(f)
        if ok:
            total_files += 1
            total_fixes += n
            print(f"  OK {f.relative_to(TEST_ROOT)}: {n} expectRevert(s) moved")
    print(f"\nDone: {total_files} files patched, {total_fixes} expectRevert(s) moved.")


if __name__ == "__main__":
    main()
