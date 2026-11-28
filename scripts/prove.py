"""Prove the kernel and the core, then make sure the proofs have teeth.

`moon prove` says that the code meets its contracts. It says nothing about
whether the contracts say what they should: a contract weak enough is met by
anything. So every contract is broken on purpose, in a private copy, and the
prover has to refuse each one. A break that still proves is a rule nobody
stated.

The Why3 toolchain and the solvers have to be installed already; `moon prove`
finds them through its own configuration or the one `--why3-config` names.

    python scripts/prove.py
    python scripts/prove.py --why3-config .github/why3.conf
"""

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# The kernel carries the contracts with teeth; the core carries the ones
# that need no array in logic, which is as far as the frontend goes today.
PACKAGES = ["spans", "."]

# Each break is one rule of a package, stated wrongly in the way a careful
# reviewer would worry about.
BREAKS = [
    ("the search stops one place early",
     "spans", "spans.mbt", "if values[mid] <= bound {", "if values[mid] < bound {"),
    ("the running maximum forgets where it starts",
     "spans", "spans.mbt", "for i = 0, top = from; i < values.length(); {",
     "for i = 0, top = 0L; i < values.length(); {"),
    ("the running maximum lags one place behind",
     "spans", "spans.mbt", "    out[i] = next\n", "    out[i] = top\n"),
    ("an intersection may be empty",
     "spans", "spans.mbt", "  if start < stop {\n    Some((start, stop))",
     "  if start <= stop {\n    Some((start, stop))"),
    ("the search is made over the values themselves",
     "spans", "spans.mbt", "first_above(running_max(values, from), bound)",
     "first_above(values, bound)"),
    ("a sum may pass the last frame",
     "spans", "spans.mbt", "a > 9007199254740991L - b",
     "a > 9007199254740992L - b"),
    ("a range that ends first may still share a frame",
     "spans", "spans.mbtp", "  proof_require: a_stop <= b_start,\n",
     "  proof_require: b_start <= a_stop,\n"),
    ("a search may stop where the values do not rise",
     "spans", "spans.mbtp",
     "  proof_require: rising(values),\n  proof_require: within(k, values.length()),",
     "  proof_require: within(k, values.length()),"),
    ("the running maximum need not be the largest so far",
     "spans", "spans.mbtp", "      largest_upto(values, from, i, result[i]))",
     "      largest_upto(values, from, 0, result[i]))"),
    ("a laid-out row starts one frame in",
     "spans", "spans.mbt", "for i = 0, cursor = 0L, bad = n; i < n; {",
     "for i = 0, cursor = 1L, bad = n; i < n; {"),
    ("a stop is its own length and not the end of the row",
     "spans", "spans.mbt", "        stops[i] = stop\n",
     "        stops[i] = lengths[i]\n"),
    ("a row that stopped goes on as if it were whole",
     "spans", "spans.mbt", "      None => continue i + 1, cursor, i\n",
     "      None => continue i + 1, cursor, bad\n"),
    ("a row that stopped says it stopped one place later",
     "spans", "spans.mbt", "      None => continue i + 1, cursor, i\n",
     "      None => continue i + 1, cursor, i + 1\n"),
    ("a sum past the last frame is still named",
     "spans", "spans.mbt", "  if a < 0L || b < 0L || a > 9007199254740991L - b {\n    None",
     "  if a < 0L || b < 0L {\n    None"),
    ("a span is one frame longer than its stops",
     ".", "model.mbt", "  self.stop - self.start\n}",
     "  self.stop - self.start + 1L\n}"),
    ("the core's sum may pass the last frame",
     ".", "model.mbt", "  @spans.summed(a, b)\n",
     "  @spans.summed(a, b + 1L)\n"),
    ("the core's intersection may be empty",
     ".", "timeline.mbt", "    Some((start, stop)) => Some({ start, stop, })",
     "    Some((start, stop)) => Some({ start, stop: start, })"),
    ("the core's intersection reaches past both ranges",
     ".", "timeline.mbt", "    Some((start, stop)) => Some({ start, stop, })",
     "    Some((start, stop)) => Some({ start, stop: stop + 1L, })"),
    ("the duration is one frame longer",
     ".", "timeline.mbt", "  self.length_frames\n}", "  self.length_frames + 1L\n}"),
]


def prove(where: Path, config: str | None, package: str) -> tuple[bool, str]:
    """Run the prover on one package; say whether it proved and what it said."""
    command = ["moon", "prove", package]
    if config:
        command += ["--why3-config", config]
    done = subprocess.run(command, cwd=where, capture_output=True, encoding="utf-8")
    said = re.sub(r"\x1b\[[0-9;]*m", "", done.stdout + done.stderr)
    proved = done.returncode == 0 and "packages proved" in said and "0 of" not in said
    return proved, said


def summary(said: str) -> str:
    for line in said.splitlines():
        if "goals proved" in line or "Failed:" in line:
            return line.strip()
    return said.strip().splitlines()[-1] if said.strip() else "nothing was said"


def module_of(scratch: Path) -> None:
    """A module of the scratch tree's own, so that nothing outside is built
    or proved."""
    module = (ROOT / "moon.mod").read_text(encoding="utf-8")
    head = module.split("import {")[0]
    (scratch / "moon.mod").write_text(head, encoding="utf-8")


def fill(scratch: Path, package: str) -> None:
    """The package to prove, and what it is built on, in a scratch directory."""
    shutil.copytree(
        ROOT / "spans",
        scratch / "spans",
        ignore=shutil.ignore_patterns("_build"),
    )
    if package == "spans":
        return
    (scratch / "moon.pkg").write_text(
        (ROOT / "moon.pkg").read_text(encoding="utf-8"), encoding="utf-8"
    )
    (scratch / "core.mbtp").write_text(
        (ROOT / "core.mbtp").read_text(encoding="utf-8"), encoding="utf-8"
    )
    for source in ROOT.glob("*.mbt"):
        if source.name.endswith("_wbtest.mbt"):
            continue
        shutil.copy(source, scratch / source.name)
    module_of(scratch)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--why3-config", default=None,
                        help="a Why3 configuration to prove with")
    args = parser.parse_args()
    # An absolute path, since the breaks are proved in a directory of their own.
    config = str(Path(args.why3_config).resolve()) if args.why3_config else None
    for package in PACKAGES:
        proved, said = prove(ROOT, config, package)
        name = "spans" if package == "spans" else "the core"
        print(f"{name}: {'proved' if proved else 'NOT proved'}, {summary(said)}")
        if not proved:
            print(said)
            return 1
    refused = 0
    for name, package, path, old, new in BREAKS:
        with tempfile.TemporaryDirectory(prefix="reconform-prove-") as scratch:
            scratch = Path(scratch)
            fill(scratch, package)
            source = (scratch / "spans" / path) if package == "spans" else scratch / path
            text = source.read_text(encoding="utf-8")
            if text.count(old) != 1:
                print(f"  cannot break {name!r}: the text is not there once")
                return 1
            source.write_text(text.replace(old, new), encoding="utf-8")
            held, _ = prove(scratch, config, package)
        if held:
            print(f"  NOT refused: {name}")
        else:
            refused += 1
            print(f"  refused:    {name}")
    print(f"{len(BREAKS)} breaks of the proved rules, {refused} refused")
    return 0 if refused == len(BREAKS) else 1


if __name__ == "__main__":
    sys.exit(main())
