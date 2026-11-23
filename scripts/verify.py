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


def request(before, after, rows, fps=24, choices=()):
    return dict(fps=fps, old_track=before, new_track=after,
                notes=[dict(id=key, text="审阅 " + key, start=start, **(
                    {} if stop is None else dict(stop=stop)
                )) for key, start, stop in rows], selections=list(choices))


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


def verify_report(before, after, notes, report):
    """Assert complete conservation and each ordered destination for every source frame."""
    old = frames(before, notes["old_track"])
    new = frames(after, notes["new_track"])
    assert (report["old_duration"], report["new_duration"]) == (len(old), len(new))
    destinations = defaultdict(list)
    for target_frame, (child, media, source) in enumerate(new):
        if media is not None:
            destinations[media, source].append((child, target_frame))
    choices = {(r["note_id"], r["piece"]): r["clip"] for r in notes["selections"]}
    expected_held, expected_transfers = [], []
    statuses = Counter()
    assert len(report["notes"]) == len(notes["notes"])
    for note, summary in zip(notes["notes"], report["notes"]):
        start = note["start"]
        stop = note.get("stop", start + 1)
        assert summary["id"] == note["id"] and summary["range"] == dict(start=start, stop=stop)
        cursor, proposed = start, []
        for piece_index, piece in enumerate(summary["pieces"]):
            at, end = piece["old"]["start"], piece["old"]["stop"]
            assert cursor == at and cursor < end <= stop, piece
            expected_children = set()
            for frame in range(at, end):
                child, media, source = old[frame]
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
            assert len(expected_children) == 1, "the report crossed an old edit boundary"
            assert all(c["range"]["stop"] - c["range"]["start"] == end - at
                       for c in piece["candidates"])
            cursor = end
            picked = choices.get((note["id"], piece_index))
            options = piece["candidates"]
            if len(options) == 1 or picked is not None:
                placement = options[0] if picked is None else next(p for p in options if p["clip"] == picked)
                proposed.append(dict(note_id=note["id"], piece=piece_index, placement=placement))
        assert cursor == stop
        if len(proposed) == len(summary["pieces"]):
            expected_transfers.extend(proposed)
        else:
            expected_held.append(note["id"])
    assert report["held"] == expected_held and report["transfers"] == expected_transfers
    return statuses


def verify_export(after, notes, report, output, otio=None):
    written = json.loads(output.read_text(encoding="utf-8"))
    selected = track(written, notes["new_track"])
    existing = track(after, notes["new_track"])["markers"]
    assert selected["markers"][:len(existing)] == existing
    transferred = selected["markers"][len(existing):]
    assert len(transferred) == len(report["transfers"])
    names = {n["id"]: n["text"] for n in notes["notes"]}
    for emitted, change in zip(transferred, report["transfers"]):
        placement = change["placement"]
        span = placement["range"]
        assert emitted["OTIO_SCHEMA"] == "Marker.2" and emitted["name"] == names[change["note_id"]]
        assert emitted["marked_range"] == time_range(
            span["start"], span["stop"] - span["start"], notes["fps"]
        )
        assert emitted["metadata"]["moon_reconform"] == dict(
            note_id=change["note_id"], piece=change["piece"], target_child=placement["clip"]
        )
    selected["markers"] = existing
    assert written == after, "the export altered timeline data outside the appended markers"
    if otio is not None:
        loaded = otio.adapters.read_from_file(str(output))
        loaded_markers = loaded.tracks[notes["new_track"]].markers
        assert len(loaded_markers) == len(existing) + len(transferred)
        for actual, raw in zip(loaded_markers[len(existing):], transferred):
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
    total = Counter()
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
    assert set(total) == {"ambiguous", "unique", "deleted", "gap"}
    return total


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
        print(f"40 seeded timelines, 480 notes: {dict(verify_generated(work))}")
        if args.live_fixture:
            print("ElFuente 60 fps metadata, 1430 to 1036 frames, "
                  f"3 transfers, 2 held: {dict(verify_real(work, opentimelineio))}")


if __name__ == "__main__":
    main()

