"""Inject known faults into the sources, one at a time, and require the tests to notice.

A suite that passes shows only that the code runs. Each fault below breaks a
rule the tool promises, in the way a careful reviewer would worry about, and
every one of them has to make the unit tests or the oracle in verify.py fail.
A fault that slips through is a rule nobody is checking.

Each fault is applied to a private copy of the tree, built there, and judged
by `moon test` and by the oracle's quick passes. The working tree itself is
never touched. The script refuses to start on a tree that already carries
one of the faults.

    python scripts/mutate.py
    python scripts/mutate.py --only 3 7 12 --workers 1
"""

import argparse
import multiprocessing
import os
import shutil
import subprocess
import sys
import tempfile
import time
from collections import Counter, namedtuple
from pathlib import Path

import verify as v

# A fault is one rule broken, as one or more edits. Where the code states
# a limit twice, on purpose, breaking it once changes nothing, so the fault
# carries every edit the rule needs.
Edit = namedtuple("Edit", "file old new")


class Fault(namedtuple("Fault", "name edits")):
    """One rule broken, as the edits that break it."""

    def __new__(cls, name, *edits):
        return super().__new__(cls, name, edits)


PLAN, INDEX, TIMELINE = "plan.mbt", "index.mbt", "timeline.mbt"
RESOLVE, REQUEST, EXPORT, MARKERS = "resolve.mbt", "request.mbt", "export.mbt", "markers.mbt"
OTIO, MAIN, MODEL = "otio.mbt", "cmd/main/main.mbt", "model.mbt"

FAULTS = [
    # The plan: pieces, candidates, budgets.
    Fault("a source piece claims an old-track range",
          Edit(PLAN, "      None => None\n",
               "      None => Some({ start: from, stop: to, })\n")),
    Fault("the sweep closes a piece one frame late",
          Edit(PLAN, "endpoints.push({ frame: overlap.stop, entering: false, shot, })",
               "endpoints.push({ frame: overlap.stop + 1L, entering: false, shot, })")),
    Fault("candidates are ordered by the wrong clip",
          Edit(PLAN, "candidates.sort_by((a, b) => a.clip.compare(b.clip))",
               "candidates.sort_by((a, b) => b.clip.compare(a.clip))")),
    Fault("a frame report costs no budget",
          Edit(PLAN, "    report_budget.val -= 1 + active.length()\n", "\n")),
    Fault("a repeated annotation id is accepted",
          Edit(PLAN, "if note.id.length() == 0 || ids.contains(note.id) {",
               "if note.id.length() == 0 {")),
    Fault("the search budget is doubled", Edit(PLAN, "Ref(1000000)", "Ref(2000000)")),
    Fault("the report budget is doubled", Edit(PLAN, "Ref(100000)", "Ref(200000)")),
    Fault("a placement's track position goes through 32 bits",
          Edit(PLAN, "let start = shot.timeline.start + (from - source_span(shot).start)",
               "let start = shot.timeline.start.to_int().to_int64() + (from - source_span(shot).start)")),
    Fault("a track of any kind is read as cuts",
          Edit(OTIO, 'if kind != "Video" && kind != "Audio" {',
               'if kind != "Video" && kind != "Audio" && kind.length() < 0 {')),
    Fault("anything is kept where a marker should be",
          Edit(OTIO, "        guard marker is Object(_) else {",
               "        guard marker is Object(_) || marker is Number(_) else {")),
    Fault("a frame rate that is not a whole number is called a bad integer",
          Edit(OTIO, "if n > 0.0 && n < 1000000.0 && n != n.floor() =>", "if n < 0.0 =>")),
    Fault("a transition is taken to last its entering offset only",
          Edit(OTIO, "let length = add_frames(entering, leaving)", "let length = entering")),
    Fault("a transition of no length is read",
          Edit(OTIO, "if length == 0L {", "if length < 0L {")),
    Fault("a clip without a source range is refused",
          Edit(OTIO, '            Null =>\n              required(reference, "available_range", context + ".media_reference")\n            range => range\n',
               '            Null => Json::null()\n            range => range\n')),
    Fault("an exact token is called fractional",
          Edit(OTIO, "  shift + trailing_zeroes >= fractional\n", "  shift + trailing_zeroes > fractional\n")),
    Fault("an inexact token is called exact",
          Edit(OTIO, "  shift + trailing_zeroes >= fractional\n", "  shift + trailing_zeroes >= 0\n")),
    Fault("a clip without footage is reported as black",
          Edit(MODEL, "Some(Offline) => OfflinePiece", "Some(Offline) => GapPiece")),
    Fault("a transition is reported as black",
          Edit(MODEL, "Some(Transition) => TransitionPiece", "Some(Transition) => GapPiece")),
    Fault("a nested sequence is reported as black",
          Edit(MODEL, "Some(Nested) => NestedPiece", "Some(Nested) => GapPiece")),
    # The index and the timeline.
    Fault("a shot with one frame inside is not a candidate",
          Edit(INDEX, "    if span.stop > target.start {", "    if span.stop - 1 > target.start {")),
    Fault("a one-frame overlap is not an overlap",
          Edit(TIMELINE, "  if start < stop {\n", "  if start + 1 < stop {\n")),
    Fault("the shot limit is one past",
          Edit(OTIO, "if children.length() > 20000 {", "if children.length() > 20001 {"),
          Edit(TIMELINE, "if shots.length() > 20000 {", "if shots.length() > 20001 {")),
    # Resolution and carry.
    Fault("an annotation transfers with a piece still unresolved",
          Edit(RESOLVE, "if proposed.length() == report.pieces.length() {",
               "if proposed.length() > 0 {")),
    Fault("carry drops deleted pieces",
          Edit(RESOLVE, "if piece.media is Some(key) && piece.source is Some(source) {",
               "if piece.media is Some(key) && piece.source is Some(source) &&\n"
               "          !(piece.kind is Deleted) {")),
    Fault("a transfer loses the marker it came from",
          Edit(RESOLVE, "          origin: note.origin,\n", "          origin: None,\n")),
    # The request.
    Fault("an unknown request field is skipped",
          Edit(REQUEST, "    if !allowed.contains(key) {",
               "    if !allowed.contains(key) && key.length() < 0 {")),
    Fault("the annotation limit is one past",
          Edit(REQUEST, "if input.length() > 10000 {", "if input.length() > 10001 {"),
          Edit(PLAN, "if notes.length() > 10000 {", "if notes.length() > 10001 {")),
    Fault("a frame is reported through 32 bits",
          Edit(REQUEST, "repr=frame.to_string())", "repr=frame.to_int().to_string())")),
    # The export.
    Fault("a stale copy is kept beside the fresh marker",
          Edit(EXPORT, "superseded.contains(key) {", "superseded.length() < 0 {")),
    Fault("a marker records the wrong footage",
          Edit(EXPORT, "let offset = placement.range.start - shot.timeline.start", "let offset = 0L")),
    Fault("an exported marker already on the track is not refused",
          Edit(EXPORT, "    if seen.contains(key) {", "    if seen.contains(key) && false {")),
    Fault("a number too large for a double is written back as Inf",
          Edit(EXPORT, "Some(token) if n.is_inf() =>", "Some(token) if n.is_nan() =>")),
    Fault("the export edits its input",
          Edit(EXPORT, "let track = otio_track(root, track_index).copy()",
               "let track = otio_track(root, track_index)")),
    # Reading markers back.
    Fault("a marker is read by its timecode",
          Edit(MARKERS, '        range.checked(context + ".source")\n',
               '        range.checked(context + ".source")\n'
               '        let range = source_range(required(fields, "marked_range", context), fps, '
               'context + ".marked_range")\n')),
    Fault("a marker without recorded footage is read anyway",
          Edit(MARKERS, 'guard origin.get("media") is Some(media_value) else {',
               'guard origin.get("target_child") is Some(media_value) else {')),
    Fault("a repeated marker is read twice",
          Edit(MARKERS, "        if seen.get(key) is Some(first) {",
               "        if seen.get(key) is Some(first) && seen.length() < 0 {")),
    Fault("a read-back annotation forgets its marker",
          Edit(MARKERS, "          origin: Some(key),\n", "          origin: None,\n")),
    # The command.
    Fault("the old cut's markers are ignored",
          Edit(MAIN, "if request.from_markers {", "if request.from_markers && false {")),
    Fault("the usage drifts", Edit(MAIN, "raise Arguments(usage)", 'raise Arguments(usage + " ")')),
    Fault("the input rule drifts",
          Edit(MAIN, 'input file of at most 16 MB: "', 'input file of at most 16MB: "')),
    Fault("the input size limit is loosened",
          Edit(MAIN, "stats.size > 16_000_000", "stats.size > 17_000_000")),
    Fault("an output failure is raised the old way", Edit(MAIN, "raise Output(error)", "fail(error)")),
    Fault("the help flag is ignored", Edit(MAIN, 'args[2] == "--help"', 'args[2] == "-help"')),
]


def run(*command, cwd):
    return subprocess.run(command, cwd=cwd, capture_output=True, text=True).returncode


def build(tree):
    """Build the command in a tree; says why on failure."""
    proc = subprocess.run(["moon", "build", "--target", "js"], cwd=tree,
                          capture_output=True, text=True)
    return "" if proc.returncode == 0 else (proc.stdout + proc.stderr).strip()[-600:]


def apply(fault, tree):
    """Write a fault into the tree and return the text each file had, so
    that putting it back never depends on finding the fault again."""
    originals = {}
    for edit in fault.edits:
        text = originals.setdefault(edit.file, (tree / edit.file).read_text(encoding="utf-8"))
        assert text.count(edit.old) == 1, (edit.file, fault.name, text.count(edit.old))
        (tree / edit.file).write_text(text.replace(edit.old, edit.new), encoding="utf-8")
    return originals


def judge(fault, tree):
    """Apply one fault in a private copy of the tree and report who noticed."""
    originals = apply(fault, tree)
    try:
        why = build(tree)
        if why:
            return fault, "does not compile", False, False, why
        tests = run("moon", "test", "--target", "js", "--deny-warn", cwd=tree) != 0
        oracle = run(sys.executable, "scripts/verify.py", "--quick", cwd=tree) != 0
        return fault, "missed" if not (tests or oracle) else "caught", tests, oracle, ""
    finally:
        for file, text in originals.items():
            (tree / file).write_text(text, encoding="utf-8")


def worker(job):
    """A private copy of the tree for a share of the faults."""
    numbers = job
    tree = Path(tempfile.mkdtemp(prefix="mutate-", dir=v.ROOT / "_build"))
    try:
        shutil.copytree(v.ROOT, tree, dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns("_build", ".mooncakes", ".git", "__pycache__"))
        os.symlink(v.ROOT / ".mooncakes", tree / ".mooncakes")
        (tree / "_build").mkdir()
        return [dict(number=number, **dict(zip(("fault", "verdict", "tests", "oracle", "why"),
                                                 judge(FAULTS[number - 1], tree))))
                for number in numbers]
    finally:
        shutil.rmtree(tree, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--only", type=int, nargs="+", metavar="N", help="judge these faults only")
    parser.add_argument("--workers", type=int, default=min(4, os.cpu_count() or 1),
                        help="private copies of the tree to judge faults in at once")
    args = parser.parse_args()
    numbers = args.only or list(range(1, len(FAULTS) + 1))
    for number in numbers:
        fault = FAULTS[number - 1]
        for edit in fault.edits:
            count = (v.ROOT / edit.file).read_text(encoding="utf-8").count(edit.old)
            if count != 1:
                print(f"fault {number} ({fault.name}) matches {count} places in {edit.file}: "
                      f"the tree already carries it or the source moved on. "
                      f"Restore the tree, or update the fault.", file=sys.stderr)
                return 2
    # The private copies share the root's dependencies and build from
    # scratch, so the root has to have fetched them and to build itself.
    (v.ROOT / "_build").mkdir(exist_ok=True)
    why = build(v.ROOT)
    if why or not (v.ROOT / ".mooncakes").is_dir():
        print(f"the tree does not build, so its faults cannot be judged:\n{why}",
              file=sys.stderr)
        return 2
    began = time.perf_counter()
    shares = [numbers[i::args.workers] for i in range(args.workers)]
    with multiprocessing.Pool(args.workers) as pool:
        found = [result for results in pool.map(worker, [share for share in shares if share])
                 for result in results]
    found.sort(key=lambda result: result["number"])
    tally = Counter()
    for result in found:
        fault, verdict = result["fault"], result["verdict"]
        tally[verdict] += 1
        if verdict == "caught":
            by = ("caught by both" if result["tests"] and result["oracle"] else
                  "caught by the unit tests alone" if result["tests"] else
                  "caught by the oracle alone")
            tally[by] += 1
            note = by
        else:
            note = verdict.upper()
            if result.get("why"):
                note += "\n" + result["why"]
        print(f"{result['number']:3d}  {fault.name:<56} {note}", flush=True)
    print(f"{len(found)} faults in {time.perf_counter() - began:.0f}s: "
          f"{tally['caught by both']} caught by both, "
          f"{tally['caught by the oracle alone']} by the oracle alone, "
          f"{tally['caught by the unit tests alone']} by the unit tests alone, "
          f"{tally['missed']} missed, {tally['does not compile']} did not compile")
    return 1 if tally["missed"] or tally["does not compile"] or len(found) != len(numbers) else 0


if __name__ == "__main__":
    sys.exit(main())
