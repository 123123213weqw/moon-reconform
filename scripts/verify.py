"""Verify the built Node CLI against an independent frame-by-frame oracle."""

import argparse
import bisect
import copy
import hashlib
import json
import random
import subprocess
import tempfile
import time
from collections import Counter, defaultdict
from pathlib import Path
from urllib.error import URLError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "_build/js/debug/build/cmd/main/main.js"
PIN = "2cc61d92fb4c45dfc0ef8e80f4b5dd7c0005f25f"
SHA256 = "9a2e3b4841cc68e5043080ee76997919b4597158221363bc00bfd3d6155adaaf"
FIXTURE = (
    f"https://raw.githubusercontent.com/darbyjohnston/otio-oc-examples/{PIN}/"
    "ElFuente_4096x2160_60fps_10bit_420.otio"
)


def obj(schema, **fields):
    return {"OTIO_SCHEMA": schema, **fields}


def rt(value, rate):
    return obj("RationalTime.1", value=value, rate=rate)


def time_range(start, duration, fps):
    return obj("TimeRange.1", start_time=rt(start, fps), duration=rt(duration, fps))


def clip(key, start, duration, fps, legacy=False):
    reference = obj(
        "ExternalReference.1", name="", metadata={}, target_url=key,
        available_range=time_range(0, 2000, fps), available_image_bounds=None,
    )
    fields = dict(name=key, metadata={}, source_range=time_range(start, duration, fps),
                  markers=[], effects=[], enabled=True, color=None)
    if legacy:
        return obj("Clip.1", media_reference=reference, **fields)
    return obj("Clip.2", media_references={"original": reference},
               active_media_reference_key="original", **fields)


def gap(duration, fps):
    return obj("Gap.1", name="", metadata={}, source_range=time_range(0, duration, fps),
               markers=[], effects=[], enabled=True, color=None)


def marker(name, start, duration, fps):
    return obj("Marker.2", name=name, comment="", color="RED", metadata={},
               marked_range=time_range(start, duration, fps))


def make_track(children, markers=()):
    return obj("Track.1", name="V1", kind="Video", children=children, metadata={},
               source_range=None, markers=list(markers), effects=[], enabled=True, color=None)


def timeline(children, markers=()):
    tracks = obj("Stack.1", name="tracks", source_range=None, metadata={},
                 children=[make_track(children, markers)], markers=[], effects=[])
    return obj("Timeline.1", name="Review", metadata={}, global_start_time=None, tracks=tracks)


def track(document, index=0):
    return document["tracks"]["children"][index]


def request(before, after, rows, fps=24, choices=(), **extra):
    """Rows are (id, start, stop) old-track notes, or whole note dicts such
    as the carried ones, which pass through unchanged."""
    return dict(fps=fps, old_track=before, new_track=after,
                notes=[row if isinstance(row, dict) else dict(
                    id=row[0], text="审阅 " + row[0], start=row[1], **(
                        {} if row[2] is None else dict(stop=row[2])
                    )) for row in rows], selections=list(choices), **extra)


def write(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")


def files(directory, before, after, notes):
    paths = [directory / name for name in ("before.otio", "after.otio", "request.json")]
    for path, item in zip(paths, (before, after, notes)):
        write(path, item)
    return paths


def launch(*argv, timeout=20):
    proc = subprocess.run(["node", str(CLI), *map(str, argv)], cwd=ROOT,
                          capture_output=True, encoding="utf-8", timeout=timeout)
    assert not proc.stderr, proc.stderr
    return proc


def invoke(mode, paths, error=None, timeout=20):
    proc = launch(mode, *paths, timeout=timeout)
    assert proc.stdout, (proc.returncode, proc.stderr)
    result = json.loads(proc.stdout)
    if error is None:
        assert proc.returncode == 0 and result["ok"], (result, proc.stderr)
    else:
        assert proc.returncode != 0 and result["ok"] is False and error in result["error"], result
        # A refusal is for the person at the terminal: it names the document
        # and the problem, never a position in this tool's own source.
        assert "Failure(" not in result["error"] and ".mbt:" not in result["error"], result
    return result


def spans(document, index):
    """The selected track as intervals, read from the document alone:
    (child, track start, track stop, media, first source frame). No frame
    is enumerated, so a cut 2^51 frames long costs the same as one of 20."""
    result, at = [], 0
    for child, item in enumerate(track(document, index)["children"]):
        outer = item["source_range"]
        if item["OTIO_SCHEMA"] == "Gap.1":
            length = int(outer["duration"]["value"])
            result.append((child, at, at + length, None, None))
        else:
            reference = (
                item["media_reference"] if item["OTIO_SCHEMA"] == "Clip.1"
                else item["media_references"][item["active_media_reference_key"]]
            )
            inner = outer or reference["available_range"]
            first = int(inner["start_time"]["value"])
            length = int(inner["duration"]["value"])
            result.append((child, at, at + length, reference["target_url"], first))
        at += length
    return result


def frames(document, index):
    """Enumerate source ownership directly, without reading any report intervals."""
    result = []
    for child, at, end, media, first in spans(document, index):
        result.extend((child, media, None if first is None else first + n)
                      for n in range(end - at))
    return result


BUCKET = 256


def index_spans(new):
    """New placements grouped for lookup by media and, within a media, by
    bucket of 256 source frames, so that a run of footage meets a handful of
    intervals instead of the whole cut. A placement longer than a bucket is
    kept apart and always consulted."""
    groups = {"all": defaultdict(list), "long": defaultdict(list),
              "bucket": defaultdict(list)}
    for shot in new:
        child, at, end, media, first = shot
        if media is None:
            continue
        groups["all"][media].append(shot)
        length = end - at
        if length > BUCKET:
            groups["long"][media].append(shot)
            continue
        for bucket in {first // BUCKET, (first + length - 1) // BUCKET}:
            groups["bucket"][media, bucket].append(shot)
    return groups


def covering(index, media, source):
    """Every placement of `media` that can overlap a source range."""
    if source["stop"] - source["start"] > BUCKET:
        return index["all"][media]
    first, last = source["start"] // BUCKET, (source["stop"] - 1) // BUCKET
    found = [*index["long"][media], *index["bucket"][media, first]]
    if last != first:
        found += index["bucket"][media, last]
    return list(dict.fromkeys(found))


def planned(old, index, note):
    """The pieces an annotation must produce, by plain interval arithmetic:
    cut each run of footage wherever the set of new placements covering it
    changes. Nothing here sweeps endpoints or keeps a budget, and every
    number is a Python integer, so this holds where no walk could go."""
    media = note.get("media")
    runs = []
    if media is None:
        start = note["start"]
        stop = note.get("stop", start + 1)
        for _, at, end, key, first in old:
            lo, hi = max(start, at), min(stop, end)
            if lo < hi:
                runs.append((dict(start=lo, stop=hi), key,
                             None if first is None else
                             dict(start=first + lo - at, stop=first + hi - at)))
    else:
        start, stop = note["source"]["start"], note["source"]["stop"]
        runs.append((None, media, dict(start=start, stop=stop)))
    pieces = []
    for old_range, key, source in runs:
        if source is None:
            pieces.append(dict(old=old_range, media=None, source=None,
                               status="gap", candidates=[]))
            continue
        hits = []
        for child, at, end, _, first in covering(index, key, source):
            lo, hi = max(source["start"], first), min(source["stop"], first + end - at)
            if lo < hi:
                hits.append((child, at, first, lo, hi))
        cuts = sorted({source["start"], source["stop"],
                       *[lo for *_, lo, hi in hits], *[hi for *_, lo, hi in hits]})
        shift = 0 if old_range is None else old_range["start"] - source["start"]
        for x, y in zip(cuts, cuts[1:]):
            candidates = sorted(
                (dict(clip=child, range=dict(start=at + x - first, stop=at + y - first))
                 for child, at, first, lo, hi in hits if lo <= x and y <= hi),
                key=lambda placement: placement["clip"])
            pieces.append(dict(
                old=None if old_range is None else dict(start=x + shift, stop=y + shift),
                media=key, source=dict(start=x, stop=y),
                status="deleted" if not candidates else
                "unique" if len(candidates) == 1 else "ambiguous",
                candidates=candidates))
    return pieces


def origin_key(item):
    """The (note, piece) a marker was exported from, or None for anyone else's."""
    origin = (item.get("metadata") or {}).get("moon_reconform")
    if not isinstance(origin, dict) or not isinstance(origin.get("note_id"), str):
        return None
    piece = origin.get("piece")
    if isinstance(piece, bool) or not isinstance(piece, (int, float)) \
            or not 0 <= piece <= 2147483647 or piece != int(piece):
        return None
    return origin["note_id"], int(piece)


def imported_notes(document, index):
    """What `from_markers` adds: our markers on the old track, each as the
    footage its metadata records. Where the marker is drawn is not read."""
    notes = []
    for item in track(document, index)["markers"]:
        key = origin_key(item)
        if key is None:
            continue
        origin = item["metadata"]["moon_reconform"]
        notes.append(dict(id=f"{key[0]}#{key[1]}", text=item["name"], media=origin["media"],
                          source=origin["source"], origin=dict(note_id=key[0], piece=key[1])))
    return notes


def walk_frames(old, destinations, note, summary, statuses):
    """Ground truth by enumeration: every frame of every piece is looked up
    where it is, and the piece must say exactly what was found there."""
    anchored = note.get("media")
    for piece in summary["pieces"]:
        span = piece["old"] if anchored is None else piece["source"]
        if anchored is not None:
            assert piece["old"] is None, piece
        at, end = span["start"], span["stop"]
        children = set()
        for frame in range(at, end):
            child, media, source = (old[frame] if anchored is None
                                    else (None, anchored, frame))
            children.add(child)
            targets = destinations[media, source]
            statuses[piece["status"]] += 1
            if media is None:
                assert piece["status"] == "gap" and piece["source"] is None
            else:
                assert piece["source"]["start"] + frame - at == source
                assert piece["source"]["stop"] - piece["source"]["start"] == end - at
                assert piece["status"] == ("deleted" if not targets else
                                           "unique" if len(targets) == 1 else "ambiguous")
            assert piece["media"] == media
            assert [
                (c["clip"], c["range"]["start"] + frame - at) for c in piece["candidates"]
            ] == targets
        if anchored is None:
            assert len(children) == 1, "the report crossed an old edit boundary"
        assert all(c["range"]["stop"] - c["range"]["start"] == end - at
                   for c in piece["candidates"])


def verify_report(before, after, notes, report, imported=(), walk=True):
    """Assert every piece of every annotation two independent ways: against
    an interval plan always, and frame by frame when the cuts are short
    enough to enumerate. Held annotations, transfers and carry then follow
    from the pieces, whichever way they were checked."""
    old = spans(before, notes["old_track"])
    new = spans(after, notes["new_track"])
    index = index_spans(new)

    def length(shots):
        return sum(end - at for _, at, end, _, _ in shots)

    assert (report["old_duration"], report["new_duration"]) == (length(old), length(new))
    destinations = defaultdict(list)
    if walk:
        walked = frames(before, notes["old_track"])
        assert len(walked) == length(old)
        for target_frame, (child, media, source) in enumerate(frames(after, notes["new_track"])):
            if media is not None:
                destinations[media, source].append((child, target_frame))
    choices = {(r["note_id"], r["piece"]): r["clip"] for r in notes["selections"]}
    expected_held, expected_transfers, expected_carry = [], [], []
    statuses = Counter()
    expected = [*notes["notes"], *imported]
    assert len(report["notes"]) == len(expected)
    for note, summary in zip(expected, report["notes"]):
        # A note is anchored to the old track by start and stop, or to
        # source footage by media and source.
        anchored = note.get("media")
        if anchored is None:
            start = note["start"]
            stop = note.get("stop", start + 1)
        else:
            start, stop = note["source"]["start"], note["source"]["stop"]
        assert summary["id"] == note["id"] and summary["text"] == note["text"]
        assert summary["media"] == anchored
        assert summary["range"] == dict(start=start, stop=stop)
        assert summary["origin"] == note.get("origin")
        assert summary["pieces"] == planned(old, index, note), note["id"]
        cursor, proposed = start, []
        for piece_index, piece in enumerate(summary["pieces"]):
            if not walk:
                statuses[piece["status"]] += 1
            span = piece["old"] if anchored is None else piece["source"]
            assert cursor == span["start"] and cursor < span["stop"] <= stop, piece
            cursor = span["stop"]
            picked = choices.get((note["id"], piece_index))
            options = piece["candidates"]
            if len(options) == 1 or picked is not None:
                placement = options[0] if picked is None else next(p for p in options if p["clip"] == picked)
                proposed.append(dict(note_id=note["id"], piece=piece_index, placement=placement,
                                     origin=note.get("origin")))
        assert cursor == stop
        if len(proposed) == len(summary["pieces"]):
            expected_transfers.extend(proposed)
        else:
            expected_held.append(note["id"])
            # What a held note leaves behind is its footage: one source note
            # per piece that has any, named after the note and the piece.
            for piece_index, piece in enumerate(summary["pieces"]):
                if piece["media"] is not None:
                    expected_carry.append(dict(
                        id=f'{note["id"]}#{piece_index}', text=note["text"],
                        media=piece["media"], source=piece["source"]))
        if walk:
            walk_frames(walked, destinations, note, summary, statuses)
    assert report["held"] == expected_held and report["transfers"] == expected_transfers
    assert report["carry"] == expected_carry
    return statuses


def verify_export(after, notes, report, output, otio=None, imported=()):
    written = json.loads(output.read_text(encoding="utf-8"))
    selected = track(written, notes["new_track"])
    existing = track(after, notes["new_track"])["markers"]
    # An annotation read back from a marker replaces, once it transfers, the
    # copy an editor already conformed into the new cut. All else is kept.
    superseded = {(t["origin"]["note_id"], t["origin"]["piece"]) for t in report["transfers"]
                  if t["origin"] is not None}
    kept = [m for m in existing if origin_key(m) not in superseded]
    assert selected["markers"][:len(kept)] == kept
    transferred = selected["markers"][len(kept):]
    assert len(transferred) == len(report["transfers"])
    names = {n["id"]: n["text"] for n in [*notes["notes"], *imported]}
    new = spans(after, notes["new_track"])
    for emitted, change in zip(transferred, report["transfers"]):
        placement = change["placement"]
        span = placement["range"]
        assert emitted["OTIO_SCHEMA"] == "Marker.2" and emitted["name"] == names[change["note_id"]]
        assert emitted["marked_range"] == time_range(
            span["start"], span["stop"] - span["start"], notes["fps"]
        )
        # The marker records the footage under its placement. That is read
        # from the new cut's own intervals, never from the report, and
        # works for a cut too long to enumerate.
        under = [shot for shot in new if shot[1] <= span["start"] and span["stop"] <= shot[2]]
        assert len(under) == 1 and under[0][0] == placement["clip"] and under[0][3] is not None
        media, first = under[0][3], under[0][4] + span["start"] - under[0][1]
        assert emitted["metadata"]["moon_reconform"] == dict(
            note_id=change["note_id"], piece=change["piece"], target_child=placement["clip"],
            media=media, source=dict(start=first, stop=first + span["stop"] - span["start"])
        )
    selected["markers"] = kept
    expected = copy.deepcopy(after)
    track(expected, notes["new_track"])["markers"] = kept
    assert written == expected, "the export altered timeline data outside the markers"
    if otio is not None:
        loaded = otio.adapters.read_from_file(str(output))
        loaded_markers = loaded.tracks[notes["new_track"]].markers
        assert len(loaded_markers) == len(kept) + len(transferred)
        for actual, raw in zip(loaded_markers[len(kept):], transferred):
            assert actual.name == raw["name"]
            assert actual.marked_range.start_time.value == raw["marked_range"]["start_time"]["value"]
            assert actual.marked_range.duration.value == raw["marked_range"]["duration"]["value"]
            # The official library hands back the footage the marker records,
            # which is what a later round reads it by.
            origin, written_origin = actual.metadata["moon_reconform"], raw["metadata"]["moon_reconform"]
            assert dict(origin) == written_origin, (dict(origin), written_origin)
        # Markers kept from the input, the editor's and the held copies
        # alike, come back as they went in.
        for actual, raw in zip(loaded_markers[:len(kept)], kept):
            assert actual.name == raw["name"] and dict(actual.metadata) == raw.get("metadata", {})


def demo():
    a, b, c = ("file:///shoot/" + name + ".mov" for name in ("A", "B", "C"))
    before = timeline([clip(a, 10, 10, 24, legacy=True), clip(b, 100, 4, 24),
                       gap(2, 24), clip(c, 1, 4, 24)])
    after = timeline([clip(b, 100, 4, 24), clip(a, 12, 3, 24), gap(2, 24),
                      clip(a, 14, 4, 24), clip(c, 2, 3, 24)], [marker("Keep this marker", 5, 1, 24)])
    after["metadata"] = {"preserve": ["unknown metadata", {"opaque": True}]}
    after["tracks"]["children"].insert(0, make_track([]))
    after["tracks"]["children"][0]["kind"] = "Audio"
    notes = request(0, 1, [
        ("entire-old", 0, 20), ("repeat-choice", 4, None), ("old-gap", 14, 16),
        ("cut-frame", 10, None), ("split-across-new-cuts", 3, 6),
    ], choices=[dict(note_id="repeat-choice", piece=0, clip=3),
                dict(note_id="split-across-new-cuts", piece=1, clip=1)])
    return before, after, notes


def verify_demo(directory, otio):
    before, after, notes = demo()
    paths = files(directory, before, after, notes)
    output = directory / "confirmed.otio"
    first = invoke("plan", paths)
    assert invoke("plan", paths) == first
    status = verify_report(before, after, notes, first)
    assert set(status) == {"ambiguous", "unique", "deleted", "gap"}
    assert first["held"] == ["entire-old", "old-gap"]
    assert len(first["transfers"]) == 5
    assert invoke("apply", [*paths, output]) == first
    verify_export(after, notes, first, output, otio)
    contents = output.read_bytes()
    invoke("apply", [*paths, output], "EEXIST")
    assert output.read_bytes() == contents
    invoke("apply", [paths[0], output, paths[2], directory / "duplicate.otio"], "already exists")
    assert not (directory / "duplicate.otio").exists()
    legacy_text = paths[1].read_text(encoding="utf-8").replace(
        '"opaque": true', '"opaque": 1.00000000000000000099'
    )
    paths[1].write_text(legacy_text, encoding="utf-8")
    precise_output = directory / "precise.otio"
    invoke("apply", [*paths, precise_output])
    assert "1.00000000000000000099" in precise_output.read_text(encoding="utf-8")
    write(paths[1], after)
    bad_after = copy.deepcopy(after)
    track(bad_after, 1)["children"][1]["effects"] = [obj("LinearTimeWarp.1")]
    write(paths[1], bad_after)
    invoke("plan", paths, "effects and retiming")
    write(paths[1], after)
    attack = paths[0].read_text(encoding="utf-8").replace('"value": 10', '"value": 10.0000000000000000001', 1)
    paths[0].write_text(attack, encoding="utf-8")
    invoke("plan", paths, "expected a nonnegative exact integer")
    write(paths[0], before)
    bad_choice = copy.deepcopy(notes)
    bad_choice["selections"][0]["clip"] = 2
    write(paths[2], bad_choice)
    invoke("plan", paths, "not a candidate")
    write(paths[2], notes)
    # A misspelled key is refused at each level instead of narrowing the request.
    misspelled = copy.deepcopy(notes)
    misspelled["selectons"] = []
    write(paths[2], misspelled)
    invoke("plan", paths, "request: unknown field selectons")
    narrowed = copy.deepcopy(notes)
    narrowed["notes"][0]["end"] = narrowed["notes"][0].pop("stop")
    write(paths[2], narrowed)
    invoke("plan", paths, "annotation entire-old: unknown field end")
    write(paths[2], notes)
    return status


def verify_generated(directory):
    rng = random.Random(301827)
    # A second stream keeps the timelines and the 480 notes the published
    # sample, whatever the source-anchored notes draw.
    footage = random.Random(71903)
    total, sourced = Counter(), Counter()
    for _ in range(40):
        seqs = [
            [clip(rng.choice(["a", "b", "c", "d"]), rng.randrange(12), rng.randrange(1, 11), 24)
             if rng.random() < 0.8 else gap(rng.randrange(1, 5), 24) for _ in range(rng.randrange(3, 10))]
            for _ in range(2)
        ]
        before, after = (timeline(seq) for seq in seqs)
        duration = len(frames(before, 0))
        positions = [rng.randrange(duration) for _ in range(12)]
        notes = request(0, 0, [(str(i), start, rng.randrange(start + 1, duration + 1))
                               for i, start in enumerate(positions)])
        report = invoke("plan", files(directory, before, after, notes))
        total.update(verify_report(before, after, notes, report))
        # Source-anchored notes on the same pair of cuts: footage that may
        # be gone, present once, or repeated.
        rows = []
        for i in range(4):
            key, start = footage.choice(["a", "b", "c", "d", "zz"]), footage.randrange(14)
            rows.append(dict(id=f"s{i}", text="源素材 " + key, media=key,
                             source=dict(start=start, stop=footage.randrange(start + 1, 15))))
        anchored = request(0, 0, rows)
        sourced.update(
            verify_report(before, after, anchored, invoke("plan", files(directory, before, after, anchored))))
    assert set(total) == {"ambiguous", "unique", "deleted", "gap"}
    assert set(sourced) == {"ambiguous", "unique", "deleted"}
    return total, sourced


def verify_sources(directory, otio):
    """Held notes travel to the next cut by footage, with no old-track position."""
    before, after, notes = demo()
    first = invoke("plan", files(directory, before, after, notes))
    verify_report(before, after, notes, first)
    # "old-gap" sat on black and has no footage, so nothing carries it;
    # every held piece of "entire-old" that has footage is restated once.
    assert [note["id"] for note in first["carry"]] == [
        f"entire-old#{i}" for i in (0, 1, 2, 3, 4, 5, 7, 8)]
    second = request(0, 1, first["carry"],
                     choices=[dict(note_id="entire-old#2", piece=0, clip=3)])
    paths = files(directory, before, after, second)
    report = invoke("plan", paths)
    status = verify_report(before, after, second, report)
    # Against the same cut the footage is where it was: what was deleted
    # stays held, the rest lands, and the ambiguous piece needs its choice.
    assert report["held"] == ["entire-old#0", "entire-old#4", "entire-old#7"]
    assert len(report["transfers"]) == 5
    assert [note["id"] for note in report["carry"]] == [
        "entire-old#0#0", "entire-old#4#0", "entire-old#7#0"]
    output = directory / "carried.otio"
    invoke("apply", [*paths, output])
    verify_export(after, second, report, output, otio)
    # Each anchor stands alone, and the request is still read strictly.
    mixed = copy.deepcopy(second)
    mixed["notes"][0]["start"] = 0
    write(paths[2], mixed)
    invoke("plan", paths, "media and source cannot combine with start and stop")
    orphan = copy.deepcopy(second)
    del orphan["notes"][0]["media"]
    write(paths[2], orphan)
    invoke("plan", paths, "source requires media")
    typo = copy.deepcopy(second)
    typo["notes"][0]["source"]["end"] = typo["notes"][0]["source"].pop("stop")
    write(paths[2], typo)
    invoke("plan", paths, "entire-old#0.source: unknown field end")
    empty = copy.deepcopy(second)
    empty["notes"][0]["media"] = ""
    write(paths[2], empty)
    invoke("plan", paths, "media is empty")
    return status


def verify_rounds(directory, otio):
    """Three review rounds across cuts that carry markers conformed by timecode."""
    before, after, notes = demo()
    marked = directory / "round-one.otio"
    first = invoke("apply", [*files(directory, before, after, notes), marked])
    verify_report(before, after, notes, first)
    ours = [m for m in track(json.loads(marked.read_text(encoding="utf-8")), 1)["markers"]
            if origin_key(m) is not None]
    assert len(ours) == 5
    by_note = {origin_key(m): m for m in ours}

    # Round two. Cut three was conformed by timecode from the application's
    # copy of cut two, so every marker of ours now sits wherever its old
    # timecode landed, which for three of them is other footage or black.
    a, b = "file:///shoot/A.mov", "file:///shoot/B.mov"
    third = timeline(
        [clip(a, 12, 2, 24), gap(1, 24), clip(b, 100, 4, 24),
         clip(a, 15, 2, 24), clip(a, 15, 2, 24), clip(a, 10, 2, 24)],
        [by_note["split-across-new-cuts", 2], marker("Keep this marker", 5, 1, 24),
         by_note["cut-frame", 0], by_note["split-across-new-cuts", 0],
         by_note["repeat-choice", 0], by_note["split-across-new-cuts", 1]])
    second = request(1, 0, [("round-two", 4, 6), ("round-two-gap", 7, 9), *first["carry"]],
                     from_markers=True)
    paths = files(directory, None, third, second)
    paths[0].write_bytes(marked.read_bytes())
    document = json.loads(marked.read_text(encoding="utf-8"))
    report = invoke("plan", paths)
    status = verify_report(document, third, second, report, imported_notes(document, 1))
    # By hand: of the five read-back annotations only two still have their
    # footage in cut three, and each lands on it.
    assert [(t["note_id"], t["placement"]["clip"], t["placement"]["range"]["start"])
            for t in report["transfers"] if t["origin"] is not None] == [
                ("cut-frame#0", 2, 3), ("split-across-new-cuts#0", 0, 1)]
    assert report["held"] == [
        "round-two-gap", "entire-old#2", "entire-old#3", "entire-old#4", "entire-old#7",
        "entire-old#8", "repeat-choice#0", "split-across-new-cuts#1", "split-across-new-cuts#2"]
    assert len(report["transfers"]) == 6
    output = directory / "round-two.otio"
    assert invoke("apply", [*paths, output]) == report
    verify_export(third, second, report, output, otio, imported_notes(document, 1))
    written = json.loads(output.read_text(encoding="utf-8"))
    # The two transferred copies are gone; the editor's marker and the
    # copies of the three held annotations keep their order and place.
    assert [m["name"] for m in track(written)["markers"][:4]] == [
        "审阅 split-across-new-cuts", "Keep this marker", "审阅 repeat-choice",
        "审阅 split-across-new-cuts"]
    assert [m["marked_range"] for m in track(written)["markers"][:4]] == [
        by_note["split-across-new-cuts", 2]["marked_range"],
        marker("Keep this marker", 5, 1, 24)["marked_range"],
        by_note["repeat-choice", 0]["marked_range"],
        by_note["split-across-new-cuts", 1]["marked_range"]]
    # Where a marker is drawn is not what it is read as: pile every marker
    # of the old cut onto one frame and the plan does not change.
    drifted = copy.deepcopy(document)
    for item in track(drifted, 1)["markers"]:
        if origin_key(item) is not None:
            item["marked_range"] = time_range(0, 1, 24)
    write(paths[0], drifted)
    assert invoke("plan", paths) == report
    write(paths[0], document)
    invoke("apply", [*paths, output], "EEXIST")

    # Round three. The editor restores the very first cut; the application
    # hands it over with all ten markers conformed by timecode. Every
    # annotation, carried or read back, now finds its footage again.
    conformed = copy.deepcopy(written)
    track(conformed)["children"] = track(before)["children"]
    restored = copy.deepcopy(before)
    track(restored)["markers"] = copy.deepcopy(track(conformed)["markers"])
    last = request(0, 0, report["carry"], from_markers=True)
    paths = files(directory, conformed, restored, last)
    final = invoke("plan", paths)
    status.update(verify_report(conformed, restored, last, final, imported_notes(conformed, 0)))
    assert final["held"] == [] and final["carry"] == []
    # Every piece here is a single one, so the annotation names its transfer.
    # A marker read back appends the piece to the id of the annotation that
    # exported it, so an annotation that keeps travelling is named by its
    # path: "entire-old#0#0" is piece 0 of "entire-old#0".
    assert all(t["piece"] == 0 for t in final["transfers"]) and len(final["transfers"]) == 18
    placed = {t["note_id"]: (t["placement"]["clip"], t["placement"]["range"]["start"])
              for t in final["transfers"]}
    assert placed == {
        "entire-old#2#0": (0, 4), "entire-old#3#0": (0, 5), "entire-old#3#1": (0, 7),
        "entire-old#4#0": (0, 8), "entire-old#7#0": (3, 16), "entire-old#8#0": (3, 17),
        "repeat-choice#0#0": (0, 4), "split-across-new-cuts#1#0": (0, 4),
        "split-across-new-cuts#2#0": (0, 5), "repeat-choice#0": (0, 4),
        "split-across-new-cuts#1": (0, 4), "split-across-new-cuts#2": (0, 5), "round-two#0": (0, 2),
        "entire-old#0#0": (0, 0), "entire-old#1#0": (0, 2), "entire-old#5#0": (1, 10),
        "cut-frame#0#0": (1, 10), "split-across-new-cuts#0#0": (0, 3)}
    output = directory / "round-three.otio"
    assert invoke("apply", [*paths, output]) == final
    verify_export(restored, last, final, output, otio, imported_notes(conformed, 0))
    assert len(track(json.loads(output.read_text(encoding="utf-8")))["markers"]) == 19

    # Safeguards. The flag is a boolean; a marker is read once; a marker
    # that records no footage is refused rather than read by timecode; and
    # restating a read-back annotation under an id already in use, or by
    # hand against a cut that still carries its copy, is refused too.
    paths = files(directory, document, third, second)
    write(paths[0], document)
    for bad, error in [
        (dict(second, from_markers="yes"), "request.from_markers: expected a boolean"),
        (dict(second, notes=[*second["notes"], dict(
            id="cut-frame#0", text="twice", media=b, source=dict(start=100, stop=101))]),
         "annotation id is empty or repeated: cut-frame#0"),
        (request(1, 0, [("cut-frame", 0, 1)]), "an exported marker already exists for cut-frame"),
    ]:
        write(paths[2], bad)
        if "already exists" in error:
            invoke("apply", [*paths, directory / "no.otio"], error)
            assert not (directory / "no.otio").exists()
        else:
            invoke("plan", paths, error)
    twice = copy.deepcopy(document)
    track(twice, 1)["markers"].append(copy.deepcopy(by_note["cut-frame", 0]))
    legacy = copy.deepcopy(document)
    for item in track(legacy, 1)["markers"]:
        if origin_key(item) == ("cut-frame", 0):
            del item["metadata"]["moon_reconform"]["media"], item["metadata"]["moon_reconform"]["source"]
    for bad, error in [(twice, "repeats the marker for cut-frame#0 at position 2"),
                       (legacy, "selected track marker 2: records no footage")]:
        write(paths[0], bad)
        write(paths[2], second)
        invoke("plan", paths, error)
    write(paths[0], document)
    return status


def verify_beyond_enumeration(directory, otio):
    """Frame counts no walk could enumerate: footage near 2^53 and cuts 2^51
    frames long, planned by the interval oracle alone and pinned by hand."""
    a, b = "file:///shoot/A.mov", "file:///shoot/B.mov"
    top, half, quarter = 2 ** 53 - 1, 2 ** 51, 2 ** 50
    before = timeline([gap(half + 3, 24), clip(a, 2 ** 52 + 7, 20, 24), gap(5, 24),
                       clip(b, top - 39, 20, 24)])
    after = timeline([clip(b, top - 39, 4, 24), clip(a, 2 ** 52 + 12, 3, 24),
                      gap(quarter, 24), clip(a, 2 ** 52 + 14, 4, 24)])
    notes = request(0, 0, [
        ("head", half + 8, half + 11), ("tail", half + 46, half + 48), ("last", half + 47, None),
        ("black", half + 24, half + 26), ("across", half + 21, half + 30),
        dict(id="far", text="源素材 A", media=a, source=dict(start=2 ** 52 + 16, stop=2 ** 52 + 18)),
        ("whole", 0, half + 48),
    ], choices=[dict(note_id="head", piece=1, clip=3)])
    paths = files(directory, before, after, notes)
    report = invoke("plan", paths)
    status = verify_report(before, after, notes, report, walk=False)
    assert set(status) == {"ambiguous", "unique", "deleted", "gap"}
    assert (report["old_duration"], report["new_duration"]) == (half + 48, quarter + 11)
    placed = {(t["note_id"], t["piece"]): (t["placement"]["clip"], t["placement"]["range"])
              for t in report["transfers"]}
    # By hand. The new cut runs B[0,4), A[4,7), 2^50 frames of black, then
    # A again from 2^50 + 7. The head note is A[2^52+12, 2^52+15): its first
    # two frames sit once, its last frame is the one the new cut repeats,
    # and the choice takes the second copy. The far note is A[16,18), which
    # only the second copy has.
    assert placed == {
        ("head", 0): (1, dict(start=4, stop=6)),
        ("head", 1): (3, dict(start=quarter + 7, stop=quarter + 8)),
        ("far", 0): (3, dict(start=quarter + 9, stop=quarter + 11)),
    }
    assert report["held"] == ["tail", "last", "black", "across", "whole"]
    # By hand: the held notes leave one note per piece that has footage.
    # "across" crosses A, black and B; "whole" has nine pieces, and its two
    # on black, 0 and 6, leave nothing.
    assert report["carry"] == [
        dict(id="tail#0", text="审阅 tail", media=b, source=dict(start=top - 21, stop=top - 19)),
        dict(id="last#0", text="审阅 last", media=b, source=dict(start=top - 20, stop=top - 19)),
        dict(id="across#0", text="审阅 across", media=a,
             source=dict(start=2 ** 52 + 25, stop=2 ** 52 + 27)),
        dict(id="across#2", text="审阅 across", media=b,
             source=dict(start=top - 39, stop=top - 37)),
        dict(id="whole#1", text="审阅 whole", media=a,
             source=dict(start=2 ** 52 + 7, stop=2 ** 52 + 12)),
        dict(id="whole#2", text="审阅 whole", media=a,
             source=dict(start=2 ** 52 + 12, stop=2 ** 52 + 14)),
        dict(id="whole#3", text="审阅 whole", media=a,
             source=dict(start=2 ** 52 + 14, stop=2 ** 52 + 15)),
        dict(id="whole#4", text="审阅 whole", media=a,
             source=dict(start=2 ** 52 + 15, stop=2 ** 52 + 18)),
        dict(id="whole#5", text="审阅 whole", media=a,
             source=dict(start=2 ** 52 + 18, stop=2 ** 52 + 27)),
        dict(id="whole#7", text="审阅 whole", media=b,
             source=dict(start=top - 39, stop=top - 35)),
        dict(id="whole#8", text="审阅 whole", media=b,
             source=dict(start=top - 35, stop=top - 19)),
    ]
    assert len(report["notes"][-1]["pieces"]) == 9
    output = directory / "far.otio"
    assert invoke("apply", [*paths, output]) == report
    verify_export(after, notes, report, output, otio)
    written = track(json.loads(output.read_text(encoding="utf-8")))["markers"]
    assert [m["marked_range"]["start_time"]["value"] for m in written] == [
        4, quarter + 7, quarter + 9]
    assert written[1]["metadata"]["moon_reconform"]["source"] == dict(
        start=2 ** 52 + 14, stop=2 ** 52 + 15)
    # The last representable frame is a position like any other. A cut of
    # exactly 2^53 - 1 frames ends with A[top - 3, top), and compared with
    # itself every frame lands on itself, the last one included.
    edge = timeline([gap(top - 3, 24), clip(a, top - 3, 3, 24)])
    edge_notes = request(0, 0, [("last-but-one", top - 2, None), ("last", top - 1, None)])
    edge_report = invoke("plan", files(directory, edge, edge, edge_notes))
    verify_report(edge, edge, edge_notes, edge_report, walk=False)
    assert edge_report["old_duration"] == top and edge_report["held"] == []
    assert [t["placement"] for t in edge_report["transfers"]] == [
        dict(clip=1, range=dict(start=top - 2, stop=top - 1)),
        dict(clip=1, range=dict(start=top - 1, stop=top))]
    # A frame further cannot even be named: its stop would pass 2^53 - 1.
    off_end = request(0, 0, [("past-the-end", top, None)])
    invoke("plan", files(directory, edge, edge, off_end), "timeline exceeds exact frame range")
    # One step past it, in any notation, is refused rather than rounded.
    for document, error in [
        (timeline([clip(a, top - 5, 6, 24)]), "timeline exceeds exact frame range"),
        (timeline([gap(top, 24), gap(1, 24)]), "timeline exceeds exact frame range"),
        (timeline([clip(a, 2 ** 53, 1, 24)]), "expected a nonnegative exact integer"),
    ]:
        invoke("plan", files(directory, document, after, notes), error)
    # The refusal loop reused these paths; put the real old cut back.
    write(paths[0], before)
    beyond = request(0, 0, [("over", half + 48, half + 49)])
    write(paths[2], beyond)
    invoke("plan", paths, "annotation over extends beyond the old timeline")
    text = paths[0].read_text(encoding="utf-8")
    attack = text.replace(f'"value": {top - 39}', f'"value": {top - 39}.0000000000000000001', 1)
    assert attack != text
    write(paths[2], notes)
    paths[0].write_text(attack, encoding="utf-8")
    invoke("plan", paths, "expected a nonnegative exact integer")
    # The same number in exponent notation reads as the same frame.
    exponent = text.replace(f'"value": {top - 39}', f'"value": {top - 39}e0', 1)
    assert exponent != text
    paths[0].write_text(exponent, encoding="utf-8")
    assert invoke("plan", paths) == report
    return status


def verify_command(directory):
    """The command's own failures: a wrong invocation, an input that cannot
    be read, an output that cannot be written. Each answers with a status
    whose whole message is checked, and nothing is written on a refusal."""
    before, after, notes = demo()
    paths = files(directory, before, after, notes)
    usage = ("usage: plan old.otio new.otio request.json\n"
             "       apply old.otio new.otio request.json output.otio")
    unreadable = "cannot read a regular UTF-8 input file of at most 16 MB: "
    checked = []

    def refused(argv, message):
        proc = launch(*argv)
        assert proc.returncode == 1, (argv, proc.returncode)
        assert json.loads(proc.stdout) == {"ok": False, "error": message}, proc.stdout
        checked.append(message.split(":")[0])

    for argv in ([], ["plan", *paths[:2]], ["frobnicate", *paths], ["Plan", *paths],
                 ["plan", *paths, directory / "surplus.otio"]):
        refused(argv, usage)
    for flag in ("--help", "-h"):
        proc = launch(flag)
        assert proc.returncode == 0 and proc.stdout == usage + "\n", proc.stdout
    baseline = invoke("plan", paths)
    good = paths[0].read_bytes()

    # Input that cannot be read as a document names the file and the rule.
    for name in ("missing.otio", ""):
        path = directory / name
        refused(["plan", path, *paths[1:]], unreadable + str(path))
    paths[0].write_bytes(b"\xff\xfe")
    refused(["plan", *paths], unreadable + str(paths[0]))
    # An empty file reads fine and fails to parse; the parser names it.
    paths[0].write_bytes(b"")
    refused(["plan", *paths], f"{paths[0]}: unexpected end")
    # A document that reads but does not parse is refused by the parser,
    # and the message still names the file first.
    paths[0].write_bytes(good[:-1])
    proc = launch("plan", *paths)
    assert proc.returncode == 1
    error = json.loads(proc.stdout)["error"]
    assert error.startswith(f"{paths[0]}: ") and ".mbt:" not in error, error
    checked.append("unreadable input")

    # A byte-order mark is read, a repeated key is refused by name, and the
    # size limit is exact: 16,000,000 bytes are read and one more is not.
    paths[0].write_bytes(b"\xef\xbb\xbf" + good)
    assert invoke("plan", paths) == baseline
    twice = good.replace(b'"name": "Review"', b'"name": "Review", "name": "Other"', 1)
    assert twice != good
    paths[0].write_bytes(twice)
    refused(["plan", *paths], f"{paths[0]}: duplicate key: name")
    fat = copy.deepcopy(before)
    fat["pad"] = ""
    room = 16_000_000 - len(json.dumps(fat, ensure_ascii=False).encode())
    fat["pad"] = "p" * room
    assert paths[0].write_bytes(json.dumps(fat, ensure_ascii=False).encode()) == 16_000_000
    assert invoke("plan", paths) == baseline
    with paths[0].open("ab") as handle:
        handle.write(b" ")
    refused(["plan", *paths], unreadable + str(paths[0]))
    checked += ["byte-order mark", "size limit"]

    # Outputs: a directory that does not exist, a directory that does, and
    # an input offered as its own result. The last never loses the input.
    paths[0].write_bytes(good)
    report = invoke("plan", paths)
    nowhere = directory / "no-such-dir" / "out.otio"
    refused(["apply", *paths, nowhere], f"cannot create OTIO output (ENOENT): {nowhere}")
    folder = directory / "a-folder"
    folder.mkdir()
    refused(["apply", *paths, folder], f"cannot create OTIO output (EEXIST): {folder}")
    refused(["apply", paths[0], paths[1], paths[2], paths[1]],
            f"cannot create OTIO output (EEXIST): {paths[1]}")
    assert paths[1].read_bytes() == json.dumps(after, ensure_ascii=False).encode()
    assert not nowhere.exists() and list(folder.iterdir()) == []
    output = directory / "command.otio"
    assert invoke("apply", [*paths, output]) == report
    checked.append("outputs")
    return len(checked)


def verify_budgets(directory):
    """The budgets and the counts the README states, met exactly and stepped
    past: one annotation fewer than the limit is accepted and right, and at
    the limit the refusal names the limit. Cheap enough to run anywhere."""
    x = "file:///shoot/X.mov"

    # The budgets bound one analysis, not one document. A thousand
    # annotations that each make the index look at a thousand placements
    # overrun the search budget while the report stays small; fifty that
    # each meet two thousand placements overrun the report budget while
    # the search stays small.
    scanned = timeline([clip(x, 0, 100000, 24), *[clip(x, k + 1, 1, 24) for k in range(1999)]])
    flat = timeline([clip(x, 0, 2000, 24)])
    for count, error in ((999, None), (1000, "candidate search budget exceeded")):
        many = request(0, 0, [(f"s{i}", 1000, None) for i in range(count)])
        paths = files(directory, flat, scanned, many)
        if error is None:
            found = invoke("plan", paths, timeout=600)
            verify_report(flat, scanned, many, found)
            assert found["held"] == [note["id"] for note in many["notes"]]
        else:
            invoke("plan", paths, error, timeout=600)
    crowded = timeline([clip(x, 0, 1, 24)] * 2000)
    lone = timeline([clip(x, 0, 100, 24)])
    for count, error in ((49, None), (50, "report piece and candidate budget exceeded")):
        fifty = request(0, 0, [(f"r{i}", 0, None) for i in range(count)])
        paths = files(directory, lone, crowded, fifty)
        if error is None:
            found = invoke("plan", paths, timeout=600)
            verify_report(lone, crowded, fifty, found)
            assert len(found["notes"][0]["pieces"][0]["candidates"]) == 2000
        else:
            invoke("plan", paths, error, timeout=600)

    # The counts: ten thousand annotations are read, ten thousand and one
    # are not; a hundred thousand manual choices are read, one more is not;
    # and a track of 20,000 children is read, one more is not.
    one = timeline([clip(x, 0, 4, 24)])
    single = request(0, 0, [("n", 0, None)])
    for bad in (timeline([gap(1, 24)] * 20001),
                timeline([clip(x, 0, 1, 24)] + [gap(1, 24)] * 20000)):
        invoke("plan", files(directory, bad, one, single), "too many shots; limit is 20000")
    # A track of exactly 20,000 children is still a timeline: here, black.
    edges = invoke("plan", files(directory, timeline([gap(1, 24)] * 20000), one, single))
    assert edges["held"] == ["n"] and edges["old_duration"] == 20000
    full = request(0, 0, [(f"n{i}", 0, None) for i in range(10000)])
    full_report = invoke("plan", files(directory, one, one, full), timeout=600)
    verify_report(one, one, full, full_report)
    assert len(full_report["transfers"]) == 10000
    over = request(0, 0, [(f"n{i}", 0, None) for i in range(10001)])
    invoke("plan", files(directory, one, one, over), "too many annotations; limit is 10000")
    chosen = request(0, 0, [("n", 0, None)],
                     choices=[dict(note_id="n", piece=0, clip=i) for i in range(100001)])
    invoke("plan", files(directory, one, one, chosen), "too many manual selections")

    # The frame rate is an integer from 1 to 240, and the document has to
    # agree with it.
    for fps in (0, 241):
        invoke("plan", files(directory, one, one, request(0, 0, [("n", 0, None)], fps=fps)),
               "fps must be between 1 and 240")
    for fps in (1, 240):
        cut = timeline([clip(x, 0, 4, fps)])
        report = invoke("plan", files(directory, cut, cut, request(0, 0, [("n", 0, None)], fps=fps)))
        assert report["transfers"][0]["placement"] == dict(clip=0, range=dict(start=0, stop=1))
    invoke("plan", files(directory, one, one, request(0, 0, [("n", 0, None)], fps=25)),
           "RationalTime rate differs from the requested integer fps")

    # A track index is an Int32 that has to exist.
    far = request(2 ** 31, 0, [("n", 0, None)])
    invoke("plan", files(directory, one, one, far), "request.old_track: exceeds index range")
    far = request(0, 3, [("n", 0, None)])
    invoke("plan", files(directory, one, one, far), "track index is outside the stack")
    return dict(search="999 accepted, 1000 refused", report="49 accepted, 50 refused",
                children="20,000 read, 20,001 refused",
                annotations="10,000 accepted, 10,001 refused", choices="100,001 refused")


def verify_edge(directory):
    """The edge itself: 20,000 children on each side and 10,000 annotations,
    the most one request may hold. The new cut is the old one played back in
    reverse, so child i is child 19999 - i and every frame has exactly one
    home. Returns what the edge cost."""
    media = [f"file:///shoot/{name}.mov" for name in "abcd"]

    def running(lengths):
        total = [0]
        for length in lengths:
            total.append(total[-1] + length)
        return total

    lengths = [2 + i % 3 for i in range(20000)]
    children = [clip(media[i % 4], i, lengths[i], 24) for i in range(20000)]
    before, after = timeline(children), timeline(children[::-1])
    old_starts, new_starts = running(lengths), running(lengths[::-1])
    notes = request(0, 0, [(str(i), i * 6, None) for i in range(10000)])
    assert notes["notes"][-1]["start"] < old_starts[-1] < 60000
    paths = files(directory, before, after, notes)
    largest = max(path.stat().st_size for path in paths)
    assert largest <= 16_000_000, "the largest request the limits allow must still be readable"
    began = time.perf_counter()
    report = invoke("plan", paths, timeout=600)
    seconds = time.perf_counter() - began
    status = verify_report(before, after, notes, report)
    assert report["held"] == [] and report["carry"] == [] and len(report["transfers"]) == 10000
    assert set(status) == {"unique"}
    # In closed form, for all ten thousand: the frame's child in the old
    # cut is found by bisection and its place in the new cut by the mirror.
    for note, transfer in zip(notes["notes"], report["transfers"]):
        frame = note["start"]
        i = bisect.bisect_right(old_starts, frame) - 1
        home = 19999 - i
        at = new_starts[home] + frame - old_starts[i]
        assert transfer["note_id"] == note["id"] and transfer["placement"] == dict(
            clip=home, range=dict(start=at, stop=at + 1)), note["id"]
    assert seconds < 300, seconds

    return dict(seconds=round(seconds, 2), largest_input_mb=round(largest / 1e6, 2), **status)


def fetch_fixture():
    source = Request(FIXTURE, headers={"User-Agent": "MoonReConform-verification/0.1"})
    for attempt in range(3):
        try:
            with urlopen(source, timeout=10) as response:
                data = response.read(16_000_001)
        except (OSError, URLError):
            if attempt == 2:
                raise
        else:
            assert hashlib.sha256(data).hexdigest() == SHA256, "pinned ElFuente fixture hash mismatch"
            return data


def verify_real(directory, otio):
    data = fetch_fixture()
    before = json.loads(data)
    source_clips = track(before)["children"]
    assert len(source_clips) == 5 and len(frames(before, 0)) == 1430
    after = copy.deepcopy(before)
    revised = track(after)
    old = track(after)["children"]
    second = copy.deepcopy(old[0])
    second["source_range"] = time_range(30, 150, 60)
    repeat = copy.deepcopy(old[0])
    repeat["source_range"] = time_range(90, 25, 60)
    trimmed = copy.deepcopy(old[3])
    trimmed["source_range"] = time_range(10, 262, 60)
    revised["children"] = [old[2], second, gap(5, 60), repeat, old[4], trimmed]
    revised["markers"] = [marker("Existing review on new timeline", 0, 1, 60)]
    notes = request(0, 0, [
        ("boxing-repeat", 95, None), ("boxing-clean", 44, None),
        ("old-cut", 254, None), ("across-trim", 850, 870), ("last-frame", 1429, None),
    ], fps=60, choices=[dict(note_id="boxing-repeat", piece=0, clip=3)])
    paths = files(directory, before, after, notes)
    paths[0].write_bytes(data)
    out = directory / "real-verified.otio"
    report = invoke("apply", [*paths, out])
    status = verify_report(before, after, notes, report)
    verify_export(after, notes, report, out, otio)
    assert report["held"] == ["old-cut", "across-trim"]
    assert len(report["transfers"]) == 3 and report["new_duration"] == 1036
    return status


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live-fixture", action="store_true", help="fetch and verify the pinned ElFuente OTIO")
    parser.add_argument("--official-otio", action="store_true", help="also open exports via Python OpenTimelineIO")
    parser.add_argument("--demo", type=Path, help="write standalone local demo inputs and exit")
    parser.add_argument("--release", action="store_true",
                        help="verify the release build of the command instead of the debug one")
    args = parser.parse_args()
    global CLI
    if args.release:
        CLI = ROOT / "_build/js/release/build/cmd/main/main.js"
    if args.demo is not None:
        args.demo.mkdir(parents=True, exist_ok=False)
        files(args.demo, *demo())
        print(args.demo)
        return
    subprocess.run(["moon", "build", "--target", "js", *(["--release"] if args.release else [])],
                   check=True, cwd=ROOT)
    if args.official_otio:
        import opentimelineio
    else:
        opentimelineio = None
    parent = ROOT / "_build"
    with tempfile.TemporaryDirectory(prefix="reconform-", dir=parent) as work:
        work = Path(work)
        print(f"Demo differential oracle, safeguards and OTIO export: {dict(verify_demo(work, opentimelineio))}")
        total, sourced = verify_generated(work)
        print(f"40 seeded timelines, 480 notes: {dict(total)}")
        print(f"160 source-anchored notes on the same cuts: {dict(sourced)}")
        print("Carried held notes, source-anchor safeguards and OTIO export: "
              f"{dict(verify_sources(work, opentimelineio))}")
        print("Three review rounds, read-back markers, superseded copies and safeguards: "
              f"{dict(verify_rounds(work, opentimelineio))}")
        print("Frame counts beyond enumeration, 2^51-frame cuts and footage near 2^53: "
              f"{dict(verify_beyond_enumeration(work, opentimelineio))} (pieces)")
        print("The command's own failures, each message checked whole: "
              f"{verify_command(work)} groups")
        print("Budgets and counts, one step short accepted and one step past refused: "
              f"{verify_budgets(work)}")
        print("20,000 children and 10,000 annotations at the edge: "
              f"{verify_edge(work)}")
        if args.live_fixture:
            print("ElFuente 60 fps metadata, 1430 to 1036 frames, "
                  f"3 transfers, 2 held: {dict(verify_real(work, opentimelineio))}")


if __name__ == "__main__":
    main()

