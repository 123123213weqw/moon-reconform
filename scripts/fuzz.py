"""Fuzz the built command three ways, each judged by something exact.

Mutated documents. A tool that refuses is safe; a tool that answers is only
as good as its answer. Every mutation of a valid request is held to two
standards. The command must answer with a status, exit code 0 or 1 and one
JSON object, never a crash or a stack trace. And whenever the mutation still
describes a real pair of cuts, the answer has to satisfy the oracle in
verify.py, exports included.

Frame-count tokens. A number in an OTIO document may be written many ways,
and the reader has to accept exactly those that denote a whole number of
frames a double holds exactly. Random tokens are judged against Python's
exact decimals.

Aligned pairs. Random cuts almost never put two boundaries on the same
frame, which is where an interval tool is easiest to get wrong. These cuts
draw footage starts and lengths from one small grid, so clip edges,
annotation edges and repeated footage meet constantly. Every ambiguous piece
is then resolved by a random valid choice, and the markers are read back
against a third cut.

    python scripts/fuzz.py --count 600 --tokens 400 --pairs 300 --seed 1

A failing trial keeps its documents under _build/fuzz and the script exits
with 1. Counts and the seed fix the trials, so a failure replays.
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
from decimal import Decimal, InvalidOperation
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


TOP = 2 ** 53 - 1


def token(rng):
    """A JSON number as some exporter or other might write it: so many
    digits, perhaps a fraction padded with zeroes, perhaps an exponent."""
    text = ("-" if rng.random() < 0.08 else "") + (
        "".join(rng.choice("0123456789") for _ in range(rng.choice([1, 1, 2, 3, 5, 9, 15, 16, 17, 20]))
         ).lstrip("0") or "0")
    if rng.random() < 0.6:
        fraction = "".join(rng.choice("0123456789")
                           for _ in range(rng.choice([1, 1, 2, 3, 10, 17, 20])))
        if rng.random() < 0.3:
            fraction = fraction.rstrip("0123456789") + "0" * rng.randrange(0, 18)
        text += "." + (fraction or "0")
    if rng.random() < 0.5:
        exponent = rng.choice([0, 1, 2, 3, 5, 10, 15, 17, 20, -1, -2, -3, -5, -10, -17, -20,
                               308, 309, 400, -308, -400, 999999999, -999999999])
        text += rng.choice("eE") + ("+" if rng.random() < 0.5 else "") * (exponent >= 0) + (
            "-" if exponent < 0 else "") + str(abs(exponent))
    return text


def expected(text):
    """What the reader must do with a frame-count token, by exact decimals:
    accept it only if its exact value is a whole number of frames that a
    double holds exactly, and then report exactly that number."""
    try:
        value = Decimal(text)
        exact = Decimal(float(value)) == value
    except (InvalidOperation, OverflowError, ValueError):
        return None
    if value != value.to_integral_value() or not 0 <= value <= TOP or not exact:
        return None
    return int(value) if value < TOP else "edge"


def token_trial(index):
    """Put one token where a clip's footage begins and read the number back."""
    try:
        text = token(random.Random(index))
        cut = json.dumps(v.timeline([v.clip("file:///shoot/A.mov", 777, 1, 24)])).replace(
            '"value": 777', f'"value": {text}', 1)
        paths = [FLOOR / f"token-{os.getpid()}-{index}-{i}" for i in range(3)]
        paths[0].write_text(cut)
        paths[1].write_text(cut)
        paths[2].write_text(json.dumps(v.request(0, 0, [("n", 0, None)])))
        answer = status(v.launch("plan", *paths))
        for path in paths:
            path.unlink(missing_ok=True)
        want = expected(text)
        if want == "edge":  # the last frame a token can name cannot start a clip
            problem = None if answer["ok"] is False and "exact frame range" in answer["error"] else str(answer)[:200]
            return index, text, "refused", problem
        if want is None:
            return index, text, "refused", None if answer["ok"] is False else "accepted: " + str(answer)[:200]
        if answer["ok"] is False:
            return index, text, "accepted", answer["error"]
        got = answer["notes"][0]["pieces"][0]["source"]["start"]
        return index, text, "accepted", None if got == want else f"read back {got}, expected {want}"
    except Exception as error:
        return index, "?", "FAILED", f"{type(error).__name__}: {error}"[:400]


MEDIA = [f"file:///shoot/{name}.mov" for name in "ABCD"]
STARTS = [0, 2, 4, 6, 8, 10]
LENGTHS = [1, 2, 3, 4, 5, 6, 8, 10]


NO_MEDIA = ["MissingReference.1", "GeneratorReference.1", "ImageSequenceReference.1"]


def aligned_cut(rng):
    """A cut whose boundaries are made to coincide: footage starts and
    lengths come from one small grid. Among the clips sit the children an
    export really has, a clip whose media has no location of its own, a
    transition and a sequence nested as a clip, all on the same grid."""
    children = []
    for _ in range(rng.randrange(0, 7)):
        start, length = rng.choice(STARTS), rng.choice(LENGTHS)
        roll = rng.random()
        if roll < 0.15:
            children.append(v.gap(rng.choice([1, 2, 4]), 24))
        elif roll < 0.23:
            media = (None if rng.random() < 0.2 else
                     v.obj(rng.choice(NO_MEDIA), name="", metadata={}))
            children.append(dict(v.clip(MEDIA[0], start, length, 24, legacy=True),
                                 media_reference=media))
        elif roll < 0.31:
            entering = rng.choice([0, 1, 2])
            leaving = rng.choice([1, 2]) if entering == 0 else rng.choice([0, 1, 2])
            children.append(v.obj("Transition.1", name="dissolve", metadata={},
                                  transition_type="SMPTE_Dissolve", parameters={},
                                  in_offset=v.rt(entering, 24), out_offset=v.rt(leaving, 24)))
        elif roll < 0.38:
            children.append(v.obj("Stack.1", name="sub", metadata={},
                                  source_range=v.time_range(0, length, 24),
                                  children=[], markers=[], effects=[], enabled=True))
        else:
            children.append(v.clip(rng.choice(MEDIA), start, length, 24, legacy=rng.random() < 0.3))
    return children


def choose(rng, notes, summaries):
    """A random valid choice for every ambiguous piece."""
    return [dict(note_id=note["id"], piece=piece,
                 clip=rng.choice(summary["pieces"][piece]["candidates"])["clip"])
            for note, summary in zip(notes, summaries)
            for piece in range(len(summary["pieces"]))
            if len(summary["pieces"][piece]["candidates"]) > 1]


def plan_and_check(rng, tag, before, after, notes, imported=()):
    """Plan, resolve every ambiguity at random, and check both answers."""
    paths = [FLOOR / f"{tag}-{i}" for i in range(3)]
    for path, document in zip(paths, (before, after, notes)):
        v.write(path, document)
    first = v.invoke("plan", paths)
    v.verify_report(before, after, notes, first, imported)
    choices = choose(rng, [*notes["notes"], *imported], first["notes"])
    if not choices:
        return first, notes, paths
    decided = dict(notes, selections=choices)
    v.write(paths[2], decided)
    report = v.invoke("plan", paths)
    v.verify_report(before, after, decided, report, imported)
    return report, decided, paths


def pair_attempt(seed):
    rng = random.Random(seed)
    kind = rng.choice(["Video", "Audio"])
    old_side, new_side, last_side = aligned_cut(rng), aligned_cut(rng), aligned_cut(rng)
    before, after, third = (v.timeline(side, kind=kind) for side in (old_side, new_side, last_side))
    if rng.random() < 0.4:  # a sequence: a second track of the other kind
        other = "Audio" if kind == "Video" else "Video"
        for cut in (before, after, third):
            cut["tracks"]["children"].append(v.make_track(aligned_cut(rng), kind=other))
    old_track, new_track, last_track = (rng.randrange(len(cut["tracks"]["children"]))
                                        for cut in (before, after, third))
    total = sum(end - at for _, at, end, _, _ in v.spans(before, old_track))
    # Annotation edges are drawn to the cut's own edges: on them, one short
    # of them and one past them. Some are anchored to footage instead.
    edges = {0, total}
    for _, at, end, _, _ in v.spans(before, old_track):
        edges |= {at - 1, at, at + 1, end - 1, end, end + 1}
    rows = []
    for i in range(rng.randrange(0, 9)):
        if total and rng.random() < 0.7:
            start = (rng.choice(sorted(e for e in edges if 0 <= e < total))
                     if rng.random() < 0.85 else rng.randrange(total))
            stop = min(total, start + rng.choice([1, 1, 2, 3, rng.randrange(1, 12)]))
            rows.append((f"n{i}", start, None if stop == start + 1 and rng.random() < 0.3 else stop))
        else:
            start = rng.randrange(0, 11)
            rows.append(dict(id=f"s{i}", text=f"源素材 {i}", media=rng.choice(MEDIA + ["zz"]),
                             source=dict(start=start, stop=rng.randrange(start + 1, 14))))
    report, notes, paths = plan_and_check(rng, f"pair-{os.getpid()}-{seed}",
                                          before, after, v.request(old_track, new_track, rows))
    tally = Counter(pairs=1, notes=len(notes["notes"]), transfers=len(report["transfers"]),
                    held=len(report["held"]), chosen=len(notes["selections"]))
    written = after
    if report["transfers"]:
        written_json = FLOOR / f"pair-{os.getpid()}-{seed}.otio"
        assert v.invoke("apply", [*paths, written_json]) == report
        v.verify_export(after, notes, report, written_json, None)
        written = json.loads(written_json.read_text(encoding="utf-8"))
        tally["exported"] += 1
    if v.track(written, new_track)["markers"]:
        # Round two: a third cut carrying the markers wherever the editor's
        # application put them, read back by the footage they record.
        carried = v.track(written, new_track)["markers"]
        v.track(third, last_track)["markers"] = carried + (
            [v.marker("editor", rng.randrange(0, 6), 1, 24)] if rng.random() < 0.5 else [])
        imported = v.imported_notes(written, new_track)
        again = v.request(new_track, last_track, report["carry"], from_markers=True)
        second, decided, more = plan_and_check(rng, f"again-{os.getpid()}-{seed}",
                                               written, third, again, imported)
        tally["second rounds"] += 1
        tally["transfers"] += len(second["transfers"])
        if second["transfers"]:
            final = FLOOR / f"again-{os.getpid()}-{seed}.otio"
            v.invoke("apply", [*more, final])
            v.verify_export(third, decided, second, final, None, imported)
            final.unlink(missing_ok=True)
            tally["exported"] += 1
        for path in more:
            path.unlink(missing_ok=True)
    for path in paths:
        path.unlink(missing_ok=True)
    (FLOOR / f"pair-{os.getpid()}-{seed}.otio").unlink(missing_ok=True)
    return tally


def pair_trial(seed):
    try:
        return seed, "ok", pair_attempt(seed)
    except Exception as error:
        return seed, "FAILED", f"{type(error).__name__}: {error}"[:500]


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
    parser.add_argument("--tokens", type=int, default=400, help="frame-count tokens to judge by exact decimals")
    parser.add_argument("--pairs", type=int, default=300, help="pairs of cuts with coinciding boundaries to plan")
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

    if args.tokens:
        tally, bad = Counter(), 0
        with multiprocessing.Pool(args.workers) as pool:
            for index, text, verdict, problem in pool.imap_unordered(
                    token_trial, range(args.seed, args.seed + args.tokens), chunksize=16):
                tally[verdict] += 1
                if problem:
                    bad += 1
                    print(f"!! token {text} (seed {index}): {verdict}: {problem}",
                          file=sys.stderr, flush=True)
        print(f"{args.tokens} frame-count tokens from seed {args.seed} against exact decimals: "
              f"{dict(tally)}; {bad} wrong")
        failures += [("token", None)] * bad

    if args.pairs:
        tally, bad = Counter(), 0
        with multiprocessing.Pool(args.workers) as pool:
            for seed, verdict, detail in pool.imap_unordered(
                    pair_trial, range(args.seed, args.seed + args.pairs), chunksize=8):
                if verdict == "FAILED":
                    bad += 1
                    print(f"!! pair seed {seed}: {detail}", file=sys.stderr, flush=True)
                else:
                    tally.update(detail)
        print(f"{args.pairs} pairs of cuts with coinciding boundaries from seed {args.seed}: "
              f"{dict(tally)}; {bad} failed")
        failures += [("pair", None)] * bad
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
