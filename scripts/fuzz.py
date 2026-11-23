"""Fuzz the built command with mutated documents and hostile raw input.

A tool that refuses is safe; a tool that answers is only as good as its
answer. So every mutation of a valid request is held to two standards. The
command must answer with a status, exit code 0 or 1 and one JSON object,
never a crash or a stack trace. And whenever the mutation still describes
a real pair of cuts, the answer has to satisfy the oracle in verify.py,
exports included, so a mutation that survives is a test of the answer and
not only of the refusal.

    python scripts/fuzz.py --count 600 --seed 1

A failing trial writes its documents under _build/fuzz and the script exits
with 1. The count and the seed fix the trials, so a failure replays.
"""

import argparse
import copy
import json
import multiprocessing
import os
import random
import subprocess
import sys
import time
from collections import Counter
from pathlib import Path

import verify as v

FLOOR = v.ROOT / "_build" / "fuzz"
LIMIT = 2 ** 53 - 1
WALKABLE = 20000
NUMBERS = {"value", "start", "stop", "fps", "old_track", "new_track", "piece", "clip"}
MEDIA = ["file:///shoot/A.mov", "file:///shoot/B.mov", "file:///shoot/C.mov", "a", "",
         "file:///shoot/A.mov ", "file:///shoot/b.mov"]
SCHEMAS = ["Clip.1", "Clip.2", "Gap.1", "Transition.1", "Marker.2", "Track.1"]
LISTS = ("children", "markers", "notes", "selections")
ORIGIN = {"moon_reconform": {"note_id": "cut-frame", "piece": 0, "media": "file:///shoot/B.mov",
                             "source": {"start": 100, "stop": 101}}}
DOCS = list(v.demo())  # the old cut, the new cut and the request, unmutated

# Documents that are not documents at all. Each is offered as the old cut
# and as the request, and each may only be answered with a status.
RAW = [
    ("empty", b""), ("byte-order mark alone", b"\xef\xbb\xbf"), ("invalid UTF-8", b"\xff\xfe\xfd"),
    ("null", b"null"), ("array", b"[]"), ("number", b"24"), ("string", b'"Review"'),
    ("NaN", b'{"a": NaN}'), ("Infinity", b'{"a": Infinity}'), ("-Infinity", b'{"a": -Infinity}'),
    ("1e400", b'{"a": 1e400}'), ("1e-999999999999", b'{"a": 1e-999999999999}'),
    ("negative zero", b'{"a": -0}'), ("trailing dot", b'{"a": 1.}'), ("leading dot", b'{"a": .5}'),
    ("plus sign", b'{"a": +1}'), ("leading zero", b'{"a": 01}'), ("hexadecimal", b'{"a": 0x10}'),
    ("bare exponent", b'{"a": 1e}'), ("trailing comma", b'{"a": 1,}'), ("single quotes", b"{'a': 1}"),
    ("comment", b'{"a": 1 /* c */}'), ("control character", b'{"a": "\x01"}'),
    ("lone surrogate", b'{"a": "\\ud800"}'), ("bad escape", b'{"a": "\\q"}'),
    ("duplicate key", b'{"a": 1, "a": 2}'),
    ("30-digit integer", b'{"a": 123456789012345678901234567890}'),
    ("whitespace", b" \n\t"),
    ("200,000 nested arrays", b"[" * 200000 + b"]" * 200000),
    ("200,000 nested objects", b'{"a":' * 200000 + b"1" + b"}" * 200000),
    ("1,000,000 ones", b"[" + b"1," * 1000000 + b"1]"),
    ("200,000 keys", ("{" + ",".join(f'"k{i}":{i}' for i in range(200000)) + "}").encode()),
    ("5 MB key", ("{" + json.dumps("s" * 5000000) + ":1}").encode()),
]


def leaves(value, path=()):
    """Every node of a JSON document with the path to it."""
    yield path, value
    if isinstance(value, dict):
        for key, item in value.items():
            yield from leaves(item, path + (key,))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            yield from leaves(item, path + (index,))


def at(document, path):
    for step in path:
        document = document[step]
    return document


def replace(document, path, value):
    """A copy of the document with the node at `path` set to `value`."""
    document = copy.deepcopy(document)
    at(document, path[:-1])[path[-1]] = value
    return document


def renumber(document, rng):
    """Move one frame count or index: a nudge, a jump, or a value at the
    edge of what a frame can be."""
    spots = [path for path, item in leaves(document)
             if isinstance(item, int) and not isinstance(item, bool)
             and path and path[-1] in NUMBERS]
    if not spots:
        return document
    path = rng.choice(spots)
    old = at(document, path)
    roll = rng.random()
    if roll < 0.6:
        new = old + rng.choice([-2, -1, 1, 2])
    elif roll < 0.8:
        new = rng.choice([0, 1, 3, 4, 7, 10, 12, 14, 16, 19, 20, 21])
    elif roll < 0.95:
        new = max(0, old) + rng.choice([2 ** 20, 2 ** 40, 2 ** 51])
    else:
        new = rng.choice([LIMIT, LIMIT - 1, LIMIT + 1, 2 ** 31, 2 ** 31 - 1, -1])
    return replace(document, path, new)


def reword(document, rng):
    """Change one string: a schema, a track kind, a media key or a name."""
    spots = [path for path, item in leaves(document) if isinstance(item, str)]
    if not spots:
        return document
    path = rng.choice(spots)
    old = at(document, path)
    by_field = {
        "OTIO_SCHEMA": SCHEMAS,
        "kind": ["Audio", "Video", "Transition", "video"],
        "target_url": MEDIA,
        "active_media_reference_key": ["original", "", "missing", "a b"],
    }
    new = rng.choice(by_field.get(path[-1], ["", "审阅 意见", "x" * 5000, "a#0", "entire-old#0",
                                              old + "#0", "😀", "\u0000", old]))
    return replace(document, path, new)


def reshuffle(document, rng):
    """Delete, repeat, move or bring in a child, a marker, an annotation or
    a selection."""
    spots = [path for path, item in leaves(document)
             if isinstance(item, list) and path and path[-1] in LISTS]
    if not spots:
        return document
    document = copy.deepcopy(document)
    path = rng.choice(spots)
    items = at(document, path)
    operation = rng.choice(["delete", "repeat", "swap", "reverse", "rotate", "bring", "shuffle"])
    if not items and operation != "bring":
        return document
    if operation == "delete":
        del items[rng.randrange(len(items))]
    elif operation == "repeat":
        items.insert(rng.randrange(len(items) + 1), copy.deepcopy(rng.choice(items)))
    elif operation == "swap" and len(items) > 1:
        i, j = rng.sample(range(len(items)), 2)
        items[i], items[j] = items[j], items[i]
    elif operation == "reverse":
        items.reverse()
    elif operation == "rotate":
        cut = rng.randrange(len(items))
        items[:] = items[cut:] + items[:cut]
    elif operation == "shuffle":
        rng.shuffle(items)
    else:
        # Something of its own kind, so that the list still reads as one.
        donors = [item for _, item in leaves(rng.choice(DOCS))
                  if isinstance(item, dict) and (
                      (path[-1] in ("notes", "selections") and set(item) <= {
                          "id", "text", "start", "stop", "media", "source",
                          "note_id", "piece", "clip"} and ("id" in item) == (path[-1] == "notes"))
                      or (path[-1] in ("children", "markers") and "OTIO_SCHEMA" in item
                          and ("children" not in item) == ("marked_range" in item or path[-1] == "children")
                          and (path[-1] == "children") == ("source_range" in item)))]
        if donors:
            items.insert(rng.randrange(len(items) + 1), copy.deepcopy(rng.choice(donors)))
    return document


def rekey(document, rng):
    """Take a key away from an object, or give it one it did not have."""
    spots = [path for path, item in leaves(document) if isinstance(item, dict) and path]
    if not spots:
        return document
    document = copy.deepcopy(document)
    node = at(document, rng.choice(spots))
    if node and rng.random() < 0.5:
        node.pop(rng.choice(list(node)))
    else:
        node[rng.choice(["extra", "source", "media", "from_markers", "metadata",
                         "enabled", "effects", "source_range"])] = rng.choice(
            [None, 1, 0, "x", [], {}, True, False, ORIGIN])
    return document


def retime(document, rng):
    """Edit one clip of a timeline the way an editor would, keeping it a
    clip: trim it, slip it, split it, swap it with its neighbour, turn it
    into black, or let it run longer."""
    tracks = [path for path, item in leaves(document)
              if isinstance(item, dict) and item.get("OTIO_SCHEMA") == "Track.1"]
    if not tracks:
        return document
    document = copy.deepcopy(document)
    children = at(document, rng.choice(tracks)).get("children")
    if not isinstance(children, list) or not children:
        return document
    i = rng.randrange(len(children))
    child = children[i]
    span = child.get("source_range") if isinstance(child, dict) else None
    if not isinstance(span, dict):
        return document
    times = (span.get("start_time"), span.get("duration"))
    if not all(isinstance(t, dict) and isinstance(t.get("value"), int) for t in times):
        return document
    start, length = times[0]["value"], times[1]["value"]
    if child["OTIO_SCHEMA"] == "Gap.1":
        span["duration"]["value"] = max(1, length + rng.choice([-2, -1, 1, 2]))
        return document
    edit = rng.choice(["trim-head", "trim-tail", "slip", "split", "swap", "black", "longer"])
    if edit == "trim-head" and length > 1:
        span["start_time"]["value"], span["duration"]["value"] = start + 1, length - 1
    elif edit == "trim-tail" and length > 1:
        span["duration"]["value"] = length - 1
    elif edit == "slip":
        span["start_time"]["value"] = max(0, start + rng.choice([-2, -1, 1, 2, 7, 100]))
    elif edit == "split" and length > 1:
        cut = rng.randrange(1, length)
        right = copy.deepcopy(child)
        span["duration"]["value"] = cut
        right["source_range"]["start_time"]["value"] = start + cut
        right["source_range"]["duration"]["value"] = length - cut
        children.insert(i + 1, right)
    elif edit == "swap" and len(children) > 1:
        j = (i + 1) % len(children)
        children[i], children[j] = children[j], children[i]
    elif edit == "black":
        children[i] = v.gap(length, span["duration"]["rate"])
    elif edit == "longer":
        span["duration"]["value"] = length + rng.choice([1, 2, 5])
    return document


MUTATIONS = {"renumber": renumber, "reword": reword, "reshuffle": reshuffle,
             "rekey": rekey, "retime": retime}
WEIGHTS = [4, 2, 3, 1, 6]


def status(proc):
    """The command's answer, or an assertion naming how the contract broke."""
    assert not proc.stderr, proc.stderr[:400]
    assert proc.returncode in (0, 1), proc.returncode
    result = json.loads(proc.stdout)
    assert isinstance(result, dict) and isinstance(result.get("ok"), bool), proc.stdout[:400]
    return result


def walkable(documents):
    """Can the oracle enumerate these cuts, or must it plan by intervals?"""
    request = documents[2]
    return all(
        sum(end - at for _, at, end, _, _ in v.spans(document, request[key])) <= WALKABLE
        for document, key in ((documents[0], "old_track"), (documents[1], "new_track"))
    )


def attempt(seed):
    """One seeded mutation: a verdict and the detail that explains it. A
    failure keeps its documents, so it can be replayed without the fuzzer."""
    rng = random.Random(seed)
    documents = [copy.deepcopy(document) for document in DOCS]
    names = list(MUTATIONS)
    for _ in range(rng.choice([1, 1, 2, 3])):
        which = rng.choices(names, WEIGHTS)[0]
        # One draw for the document: the mutation has to land on the
        # document it was made from, or a timeline turns up as a request.
        source = rng.randrange(3)
        documents[source] = MUTATIONS[which](documents[source], rng)
    try:
        return check(seed, documents)
    except Exception:
        FLOOR.mkdir(parents=True, exist_ok=True)
        for name, document in zip(("old", "new", "request"), documents):
            (FLOOR / f"failed-{seed}-{name}.json").write_text(
                json.dumps(document, ensure_ascii=False, indent=1), encoding="utf-8")
        raise


def check(seed, documents):
    tag = f"{os.getpid()}-{seed}"
    paths = [FLOOR / f"{tag}-{i}.json" for i in range(3)]
    for path, document in zip(paths, documents):
        v.write(path, document)
    output = FLOOR / f"{tag}.otio"
    try:
        answer = status(v.launch("plan", *paths, timeout=60))
        if answer["ok"] is False:
            return seed, "refused", answer["error"]
        request = documents[2]
        imported = (v.imported_notes(documents[0], request["old_track"])
                    if request.get("from_markers") is True else ())
        if not walkable(documents):
            v.verify_report(documents[0], documents[1], request, answer, imported, walk=False)
            verdict = "accepted, planned by intervals"
        else:
            v.verify_report(documents[0], documents[1], request, answer, imported)
            verdict = "accepted and verified"
        if answer["transfers"]:
            written = status(v.launch("apply", *paths, output, timeout=60))
            assert written["ok"], written
            assert written == answer
            v.verify_export(documents[1], request, answer, output, None, imported)
        return seed, verdict, ""
    finally:
        for path in paths:
            path.unlink(missing_ok=True)
        output.unlink(missing_ok=True)


def trial(seed):
    try:
        return attempt(seed)
    except subprocess.TimeoutExpired:
        return seed, "no answer within a minute", ""
    except Exception as error:  # a wrong answer is a failure; so is a broken probe
        return seed, "FAILED", f"{type(error).__name__}: {error}"[:600]


def raw_documents():
    """Documents that are not documents: the contract and nothing more."""
    old, new, request = (json.dumps(document, ensure_ascii=False).encode() for document in DOCS)
    tally = Counter()
    paths = [FLOOR / f"raw-{os.getpid()}-{i}" for i in range(3)]
    for name, data in RAW:
        for role, documents in (("as the old cut", (data, new, request)),
                                ("as the request", (old, new, data))):
            for path, raw in zip(paths, documents):
                path.write_bytes(raw)
            answer = status(v.launch("plan", *paths))
            tally["refused" if answer["ok"] is False else "accepted"] += 1
            if answer["ok"] is False:
                assert "Failure(" not in answer["error"], answer
    for path in paths:
        path.unlink(missing_ok=True)
    return 2 * len(RAW), tally


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--count", type=int, default=600, help="mutations to try")
    parser.add_argument("--seed", type=int, default=1, help="first seed; trials are seeds seed..seed+count-1")
    parser.add_argument("--workers", type=int, default=min(8, os.cpu_count() or 1))
    parser.add_argument("--release", action="store_true", help="fuzz the release build of the command")
    args = parser.parse_args()
    if args.release:
        v.CLI = v.ROOT / "_build/js/release/build/cmd/main/main.js"
    subprocess.run(["moon", "build", "--target", "js", *(["--release"] if args.release else [])],
                   check=True, cwd=v.ROOT)
    FLOOR.mkdir(parents=True, exist_ok=True)
    began = time.perf_counter()
    try:
        documents, raw = raw_documents()
    except (AssertionError, subprocess.TimeoutExpired) as error:
        print(f"!! a hostile document broke the contract: {error!r}"[:600], file=sys.stderr)
        return 1
    tally, reasons = Counter(), Counter()
    failures = []
    with multiprocessing.Pool(args.workers) as pool:
        for seed, verdict, detail in pool.imap_unordered(trial, range(args.seed, args.seed + args.count),
                                                         chunksize=8):
            tally[verdict] += 1
            if verdict in ("FAILED", "no answer within a minute"):
                failures.append((seed, detail))
                print(f"!! seed {seed}: {verdict}: {detail}", file=sys.stderr, flush=True)
            elif verdict == "refused":
                reasons[detail.split(": ")[-1][:72]] += 1
    print(f"{documents} hostile documents as old cut and as request: {dict(raw)}")
    print(f"{args.count} mutations from seed {args.seed}, {args.workers} workers, "
          f"{time.perf_counter() - began:.1f}s: {dict(tally)}")
    for reason, count in reasons.most_common(6):
        print(f"  {count:5d} refused: {reason}")
    for seed, _ in failures:
        print(f"  documents of seed {seed} are under {FLOOR / f'failed-{seed}-*.json'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
