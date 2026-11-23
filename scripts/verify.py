"""Verify the built Node CLI against an independent frame-by-frame oracle."""

import argparse
import copy
import hashlib
import json
import random
import subprocess
import tempfile
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


def invoke(mode, paths, error=None):
    proc = subprocess.run(["node", str(CLI), mode, *map(str, paths)], cwd=ROOT,
                          capture_output=True, encoding="utf-8", timeout=20)
    assert proc.stdout, (proc.returncode, proc.stderr)
    result = json.loads(proc.stdout)
    if error is None:
        assert proc.returncode == 0 and result["ok"], (result, proc.stderr)
    else:
        assert proc.returncode != 0 and result["ok"] is False and error in result["error"], result
    return result


def frames(document, index):
    """Enumerate source ownership directly, without reading any report intervals."""
    result = []
    for child, item in enumerate(track(document, index)["children"]):
        span = item["source_range"]
        if item["OTIO_SCHEMA"] == "Gap.1":
            result.extend([(child, None, None)] * int(span["duration"]["value"]))
            continue
        reference = (
            item["media_reference"] if item["OTIO_SCHEMA"] == "Clip.1"
            else item["media_references"][item["active_media_reference_key"]]
        )
        span = span or reference["available_range"]
        start = int(span["start_time"]["value"])
        stop = start + int(span["duration"]["value"])
        result.extend((child, reference["target_url"], n) for n in range(start, stop))
    return result


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


def verify_report(before, after, notes, report, imported=()):
    """Assert complete conservation and each ordered destination for every anchored frame."""
    old = frames(before, notes["old_track"])
    new = frames(after, notes["new_track"])
    assert (report["old_duration"], report["new_duration"]) == (len(old), len(new))
    destinations = defaultdict(list)
    for target_frame, (child, media, source) in enumerate(new):
        if media is not None:
            destinations[media, source].append((child, target_frame))
    choices = {(r["note_id"], r["piece"]): r["clip"] for r in notes["selections"]}
    expected_held, expected_transfers, expected_carry = [], [], []
    statuses = Counter()
    expected = [*notes["notes"], *imported]
    assert len(report["notes"]) == len(expected)
    for note, summary in zip(expected, report["notes"]):
        # A note is anchored to the old track by start and stop, or to
        # source footage by media and source. Either way it is a run of
        # frames to look up, one destination table per anchor.
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
        cursor, proposed = start, []
        for piece_index, piece in enumerate(summary["pieces"]):
            if anchored is None:
                span = piece["old"]
            else:
                span = piece["source"]
                assert piece["old"] is None, piece
            at, end = span["start"], span["stop"]
            assert cursor == at and cursor < end <= stop, piece
            expected_children = set()
            for frame in range(at, end):
                child, media, source = (old[frame] if anchored is None
                                        else (None, anchored, frame))
                expected_children.add(child)
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
                assert len(expected_children) == 1, "the report crossed an old edit boundary"
            assert all(c["range"]["stop"] - c["range"]["start"] == end - at
                       for c in piece["candidates"])
            cursor = end
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
    new = frames(after, notes["new_track"])
    for emitted, change in zip(transferred, report["transfers"]):
        placement = change["placement"]
        span = placement["range"]
        assert emitted["OTIO_SCHEMA"] == "Marker.2" and emitted["name"] == names[change["note_id"]]
        assert emitted["marked_range"] == time_range(
            span["start"], span["stop"] - span["start"], notes["fps"]
        )
        # The marker records the footage under its placement, enumerated
        # frame by frame here rather than taken from the report.
        under = new[span["start"]:span["stop"]]
        assert len(under) == span["stop"] - span["start"] > 0
        assert {child for child, _, _ in under} == {placement["clip"]}
        media, first = under[0][1], under[0][2]
        assert [source for _, _, source in under] == list(range(first, first + len(under)))
        assert emitted["metadata"]["moon_reconform"] == dict(
            note_id=change["note_id"], piece=change["piece"], target_child=placement["clip"],
            media=media, source=dict(start=first, stop=first + len(under))
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
    args = parser.parse_args()
    if args.demo is not None:
        args.demo.mkdir(parents=True, exist_ok=False)
        files(args.demo, *demo())
        print(args.demo)
        return
    subprocess.run(["moon", "build", "--target", "js"], check=True, cwd=ROOT)
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
        if args.live_fixture:
            print("ElFuente 60 fps metadata, 1430 to 1036 frames, "
                  f"3 transfers, 2 held: {dict(verify_real(work, opentimelineio))}")


if __name__ == "__main__":
    main()

