"""Replace every `<engine>.executeOffer(<listingId>)` call site with the
M-10 commit-reveal sequence:

    {
        bytes32 _salt_X = keccak256(abi.encode("m10-test-salt", uint256(N)));
        bytes32 _commit_X = keccak256(abi.encode(<listingId>, type(uint256).max, _salt_X));
        <engine>.commitBuyback(_commit_X);
        vm.roll(block.number + <engine>.MIN_REVEAL_DELAY_BLOCKS());
        <engine>.revealAndExecute(<listingId>, type(uint256).max, _salt_X);
    }

Why this works:
- `type(uint256).max` is the most permissive maxPrice — any listing
  passes the M-10 cap-check. Tests that needed a tighter price would
  not have been exercising executeOffer's permissionless behavior
  pre-fix, so this is a safe maximum for legacy regression.
- The unique suffix `_X` (file index + occurrence index) avoids local
  variable collisions when multiple call sites share a function body.
- Wrapping in `{ ... }` braces creates a fresh local scope so the
  helper variables don't leak.
- `vm.roll` advances the block counter past the M-10 minimum delay.
  Calls that previously prank'ed before `executeOffer` keep that
  prank — the same prank applies to BOTH `commitBuyback` and
  `revealAndExecute` because they're in the same scope.

Caveat: tests that explicitly set up a NON-prank caller for
executeOffer (relying on permissionlessness) need the multisigOwner
or test contract itself to hold BUYBACK_OPERATOR_ROLE — which it does
in every setUp I checked, because the multisigOwner is granted both
DAR and BUYBACK_OPERATOR_ROLE in `initialize`. The patcher does NOT
inject `vm.prank` if the call site lacks one — that case continues to
rely on the test contract's role, which is consistent with pre-fix
behavior."""

import re
from pathlib import Path

TEST_ROOT = Path(r"C:\Users\AGUSTIN\AppData\Local\Temp\fix-m10\test")

# Match: `<indent><engine>.executeOffer(<arg>);` on a single line.
# Capture the leading whitespace, the engine identifier, and the arg.
CALL_RE = re.compile(
    r"^(?P<indent>\s*)(?P<engine>[A-Za-z_][A-Za-z0-9_.]*)\.executeOffer\s*\((?P<arg>[^)]*)\)\s*;",
    re.MULTILINE,
)


def patch_file(path: Path, file_idx: int) -> tuple[bool, int]:
    src = path.read_text(encoding="utf-8")
    if "[Fix M-10 patch]" in src:
        return False, 0

    matches = list(CALL_RE.finditer(src))
    if not matches:
        return False, 0

    # Walk backwards so offsets stay valid.
    out = src
    occ = len(matches)
    for m in reversed(matches):
        occ -= 1
        indent = m.group("indent")
        engine = m.group("engine")
        arg = m.group("arg").strip()
        suffix = f"{file_idx}_{occ}"
        replacement = (
            f"{indent}// [Fix M-10 patch] executeOffer was removed; route through commit-reveal.\n"
            f"{indent}{{\n"
            f"{indent}    bytes32 _m10_salt_{suffix} = keccak256(abi.encode(\"m10-test-salt\", uint256({occ})));\n"
            f"{indent}    bytes32 _m10_commit_{suffix} = keccak256(abi.encode({arg}, type(uint256).max, _m10_salt_{suffix}));\n"
            f"{indent}    {engine}.commitBuyback(_m10_commit_{suffix});\n"
            f"{indent}    vm.roll(block.number + {engine}.MIN_REVEAL_DELAY_BLOCKS());\n"
            f"{indent}    {engine}.revealAndExecute({arg}, type(uint256).max, _m10_salt_{suffix});\n"
            f"{indent}}}"
        )
        out = out[:m.start()] + replacement + out[m.end():]

    path.write_text(out, encoding="utf-8")
    return True, len(matches)


def main() -> None:
    files = sorted(TEST_ROOT.rglob("*.sol"))
    total_files = 0
    total_calls = 0
    for idx, f in enumerate(files):
        ok, n = patch_file(f, idx)
        if ok:
            total_files += 1
            total_calls += n
            print(f"  OK {f.relative_to(TEST_ROOT)}: {n} call(s) patched")
    print(f"\nDone: {total_files} files patched, {total_calls} executeOffer call(s) replaced.")


if __name__ == "__main__":
    main()
