///|
fn j_obj(fields : Map[String, Json]) -> Json {
  Json::object(fields)
}

///|
fn j_empty() -> Json {
  Json::object(Map([]))
}

///|
fn j_rt(value : Int64, rate : Int32) -> Json {
  j_obj({
    "OTIO_SCHEMA": Json("RationalTime.1"),
    "value": Json::number(value.to_double(), repr=value.to_string()),
    "rate": Json::number(rate.to_double()),
  })
}

///|
fn j_range(start : Int64, duration : Int64, rate : Int32) -> Json {
  j_obj({
    "OTIO_SCHEMA": Json("TimeRange.1"),
    "start_time": j_rt(start, rate),
    "duration": j_rt(duration, rate),
  })
}

///|
fn j_clip(url : String, start : Int64, duration : Int64, rate : Int32) -> Json {
  j_obj({
    "OTIO_SCHEMA": Json("Clip.1"),
    "name": Json(url),
    "media_reference": j_obj({
      "OTIO_SCHEMA": Json("ExternalReference.1"),
      "name": Json(""),
      "metadata": j_empty(),
      "target_url": Json(url),
      "available_range": j_range(0L, 2000L, rate),
    }),
    "metadata": j_empty(),
    "source_range": j_range(start, duration, rate),
    "markers": Json::array([]),
    "effects": Json::array([]),
    "enabled": Json::boolean(true),
  })
}

///|
fn j_gap(duration : Int64, rate : Int32) -> Json {
  j_obj({
    "OTIO_SCHEMA": Json("Gap.1"),
    "name": Json(""),
    "metadata": j_empty(),
    "source_range": j_range(0L, duration, rate),
    "markers": Json::array([]),
    "effects": Json::array([]),
    "enabled": Json::boolean(true),
  })
}

///|
fn j_marker(
  name : String,
  start : Int64,
  duration : Int64,
  rate : Int32,
) -> Json {
  j_obj({
    "OTIO_SCHEMA": Json("Marker.2"),
    "name": Json(name),
    "comment": Json(""),
    "color": Json("GREEN"),
    "marked_range": j_range(start, duration, rate),
    "metadata": j_empty(),
  })
}

///|
/// The marker `apply` writes for one piece of an annotation: the same
/// marker, carrying its annotation and the footage it was placed on.
fn j_exported(
  marker : Json,
  note_id : String,
  piece : Int32,
  media : String,
  source : Span,
) -> Json raise ReconformError {
  let fields = object(marker, "marker").copy()
  fields["metadata"] = j_obj({
    "moon_reconform": j_obj({
      "note_id": Json(note_id),
      "piece": Json(piece),
      "target_child": Json(0),
      "media": Json(media),
      "source": j_obj({
        "start": frame_json(source.start),
        "stop": frame_json(source.stop),
      }),
    }),
  })
  Json::object(fields)
}

///|
fn j_track(children : Array[Json], markers : Array[Json]) -> Json {
  j_kind("Video", children, markers)
}

///|
fn j_kind(kind : String, children : Array[Json], markers : Array[Json]) -> Json {
  j_obj({
    "OTIO_SCHEMA": Json("Track.1"),
    "name": Json("V1"),
    "kind": Json(kind),
    "children": Json::array(children),
    "metadata": j_empty(),
    "source_range": Json::null(),
    "markers": Json::array(markers),
    "effects": Json::array([]),
    "enabled": Json::boolean(true),
  })
}

///|
fn j_timeline(track : Json) -> Json {
  j_obj({
    "OTIO_SCHEMA": Json("Timeline.1"),
    "name": Json("Review"),
    "metadata": j_empty(),
    "global_start_time": Json::null(),
    "tracks": j_obj({
      "OTIO_SCHEMA": Json("Stack.1"),
      "name": Json("tracks"),
      "metadata": j_empty(),
      "children": Json::array([track]),
      "markers": Json::array([]),
      "effects": Json::array([]),
    }),
  })
}

///|
fn j_markers(root : Json) -> Array[Json] raise ReconformError {
  let timeline = object(root, "timeline")
  let stack = object(required(timeline, "tracks", "timeline"), "tracks")
  let tracks = array(required(stack, "children", "tracks"), "tracks.children")
  let track = object(tracks[0], "selected track")
  match track.get("markers") {
    None => []
    Some(value) => array(value, "selected track.markers")
  }
}

///|
fn j_name(marker : Json) -> String raise ReconformError {
  field_string(object(marker, "marker"), "name", "marker")
}

///|
fn j_origin(marker : Json) -> Map[String, Json] raise ReconformError {
  let metadata = object(object(marker, "marker")["metadata"], "metadata")
  object(metadata["moon_reconform"], "moon_reconform")
}

///|
fn j_span(start : Int64, stop : Int64) -> Json {
  j_obj({ "start": frame_json(start), "stop": frame_json(stop) })
}

///|
test "exported markers read back by footage and supersede their copies" {
  let rate = 24
  let url = "file:///shoot/A.mov"
  let note : Note = {
    id: "n1",
    text: "check the cut-in",
    range: { start: 11L, stop: 13L, },
    media: None,
    origin: None,
  }

  // Round one: a note on A[11,13) of the old cut. The new cut opens with
  // A[10,14), so the note lands one frame into the first clip.
  let old_cut = j_timeline(
    j_track([j_clip(url, 0L, 20L, rate), j_gap(2L, rate)], []),
  )
  let new_cut = j_timeline(
    j_track(
      [j_clip(url, 10L, 4L, rate), j_gap(1L, rate), j_clip(url, 14L, 4L, rate)],
      [],
    ),
  )
  let applied = with_markers(
    new_cut,
    track_index=0,
    fps=rate,
    resolve(
      plan(
        read_otio(old_cut, track_index=0, fps=rate),
        read_otio(new_cut, track_index=0, fps=rate),
        [note],
      ),
      [],
    ),
  )
  // The marker records the footage it was placed on, one frame into the
  // clip rather than the clip's own first frame.
  let first = j_markers(applied)[0]
  assert_eq(j_origin(first)["media"].stringify(), Json(url).stringify())
  assert_eq(j_origin(first)["source"].stringify(), j_span(11L, 13L).stringify())
  let imported = read_notes_from_markers(applied, track_index=0, fps=rate)
  assert_eq(imported.length(), 1)
  assert_eq(imported[0].id, "n1#0")
  assert_eq(imported[0].text, "check the cut-in")
  assert_eq(imported[0].media, Some(url))
  assert_eq(imported[0].range.start, 11L)
  assert_eq(imported[0].range.stop, 13L)
  assert_eq(imported[0].origin, Some(("n1", 0)))

  // An editor's application conforms markers by timecode. In this cut the
  // marker has drifted onto the wrong shot. It still reads as the footage
  // it records, so the note follows A[11,13) rather than whatever now sits
  // under the marker.
  let conformed = j_timeline(
    j_track(
      [j_gap(5L, rate), j_clip(url, 14L, 4L, rate), j_clip(url, 10L, 4L, rate)],
      [
        j_exported(j_marker("check the cut-in", 5L, 3L, rate), "n1", 0, url, {
          start: 11L,
          stop: 13L,
        }),
      ],
    ),
  )
  let drifted = read_notes_from_markers(conformed, track_index=0, fps=rate)
  assert_eq(drifted.length(), 1)
  assert_eq(drifted[0].media, Some(url))
  assert_eq(drifted[0].range.start, 11L)
  assert_eq(drifted[0].range.stop, 13L)

  // Round two: the editor delivers a third cut that still carries a copy
  // of the marker at its old timecode, two frames early, next to a marker
  // of their own.
  let stale = j_exported(
    j_marker("check the cut-in", 0L, 2L, rate),
    "n1",
    0,
    url,
    { start: 11L, stop: 13L, },
  )
  let third_cut = j_timeline(
    j_track(
      [
        j_gap(1L, rate),
        j_clip(url, 10L, 4L, rate),
        j_gap(1L, rate),
        j_clip(url, 14L, 4L, rate),
      ],
      [j_marker("editor's own marker", 5L, 1L, rate), stale],
    ),
  )
  let second = resolve(
    plan(
      read_otio(conformed, track_index=0, fps=rate),
      read_otio(third_cut, track_index=0, fps=rate),
      drifted,
    ),
    [],
  )
  assert_eq(second.transfers.length(), 1)
  assert_eq(second.transfers[0].origin, Some(("n1", 0)))
  assert_eq(second.transfers[0].placement.clip, 1)
  assert_eq(second.transfers[0].placement.range.start, 2L)
  assert_eq(second.transfers[0].placement.range.stop, 4L)
  let reapplied = with_markers(third_cut, track_index=0, fps=rate, second)
  let markers = j_markers(reapplied)
  // The stale copy gives way to one placed on the footage, while the
  // editor's marker keeps its place at the front.
  assert_eq(markers.length(), 2)
  assert_eq(j_name(markers[0]), "editor's own marker")
  assert_eq(j_name(markers[1]), "check the cut-in")
  let placed = source_range(
    required(object(markers[1], "marker"), "marked_range", "marker"),
    rate,
    "marker",
  )
  assert_eq(placed.start, 2L)
  assert_eq(placed.stop, 4L)
  assert_eq(
    j_origin(markers[1])["source"].stringify(),
    j_span(11L, 13L).stringify(),
  )
  // The input is never edited: both of its markers are still there. The
  // second is the stale copy itself, compared whole, because the fresh
  // marker carries the same name and a count or a list of names would
  // pass for an export that swapped them.
  assert_eq(j_markers(third_cut).length(), 2)
  assert_eq(j_name(j_markers(third_cut)[0]), "editor's own marker")
  assert_eq(j_markers(third_cut)[1].stringify(), stale.stringify())

  // A held annotation supersedes nothing. When its footage is gone, the
  // copy the editor carried stays exactly where the editor put it, and the
  // annotation travels on by its footage instead.
  let trimmed = j_timeline(
    j_track([j_gap(1L, rate), j_clip(url, 14L, 4L, rate)], [stale]),
  )
  let reports = plan(
    read_otio(conformed, track_index=0, fps=rate),
    read_otio(trimmed, track_index=0, fps=rate),
    drifted,
  )
  let held = resolve(reports, [])
  assert_eq(held.held, ["n1#0"])
  let untouched = with_markers(trimmed, track_index=0, fps=rate, held)
  assert_eq(j_markers(untouched).length(), 1)
  assert_eq(j_name(j_markers(untouched)[0]), "check the cut-in")
  let travel = carried(reports, held)
  assert_eq(travel.length(), 1)
  assert_eq(travel[0].id, "n1#0#0")
  assert_eq(travel[0].media, Some(url))
  assert_eq(travel[0].range.start, 11L)
  assert_eq(travel[0].range.stop, 13L)
  assert_eq(travel[0].origin, None)
}

///|
test "only markers with an origin are read, and a malformed one is refused" {
  let rate = 24
  let url = "file:///shoot/A.mov"
  fn cut_with(markers : Array[Json]) -> Json {
    j_timeline(j_track([j_clip(url, 0L, 8L, rate)], markers))
  }
  fn with_origin(
    marker : Json,
    origin : Map[String, Json],
  ) -> Json raise ReconformError {
    let fields = object(marker, "marker").copy()
    fields["metadata"] = j_obj({ "moon_reconform": Json::object(origin) })
    Json::object(fields)
  }
  fn error_of(markers : Array[Json]) -> String {
    let outcome = Ok(
      read_notes_from_markers(cut_with(markers), track_index=0, fps=rate),
    ) catch {
      error => Err(error)
    }
    match outcome {
      Err(Invalid(message)) => message
      _ => "no error raised"
    }
  }
  let plain = j_marker("editor's own marker", 0L, 1L, rate)
  let footage = j_span(30L, 31L)
  let sound : Map[String, Json] = {
    "note_id": Json("n1"),
    "piece": Json(0),
    "media": Json(url),
    "source": footage,
  }

  // Without our metadata a marker belongs to someone else and is skipped.
  assert_eq(
    read_notes_from_markers(cut_with([]), track_index=0, fps=rate).length(),
    0,
  )
  assert_eq(
    read_notes_from_markers(cut_with([plain]), track_index=0, fps=rate).length(),
    0,
  )
  // Two pieces of one earlier annotation stay distinct annotations.
  let pieces = read_notes_from_markers(
    cut_with([
      j_exported(j_marker("whole range", 0L, 2L, rate), "whole", 0, url, {
        start: 30L,
        stop: 32L,
      }),
      j_exported(j_marker("whole range", 4L, 2L, rate), "whole", 1, url, {
        start: 32L,
        stop: 34L,
      }),
    ]),
    track_index=0,
    fps=rate,
  )
  assert_eq(pieces.map(note => note.id), ["whole#0", "whole#1"])
  assert_eq(pieces[1].range.start, 32L)
  assert_eq(pieces[1].range.stop, 34L)
  assert_eq(pieces[1].origin, Some(("whole", 1)))

  // A marker exported before 0.2.0 recorded no footage. It is refused by
  // name instead of being read by a timecode that may have moved.
  let legacy = with_origin(plain, {
    "note_id": Json("n1"),
    "piece": Json(0),
    "target_child": Json(0),
  })
  assert_eq(
    error_of([legacy]),
    "selected track marker 0: records no footage; export it again to record some",
  )
  // The same marker twice names both of its places.
  let twice = with_origin(plain, sound)
  assert_eq(
    error_of([twice, j_marker("editor's own marker", 1L, 1L, rate), twice]),
    "selected track marker 2: repeats the marker for n1#0 at position 0",
  )
  // Every part of the origin is checked, and the message names the marker.
  fn bad(origin : Map[String, Json]) -> String raise ReconformError {
    error_of([
      j_marker("editor's own marker", 0L, 1L, rate),
      with_origin(plain, origin),
    ])
  }
  assert_eq(
    bad({
      "note_id": Json(""),
      "piece": Json(0),
      "media": Json(url),
      "source": footage,
    }),
    "selected track marker 1: note_id is empty",
  )
  assert_eq(
    bad({
      "note_id": Json("n1"),
      "piece": Json::number(-1.0),
      "media": Json(url),
      "source": footage,
    }),
    "selected track marker 1.piece: expected a nonnegative exact integer",
  )
  assert_eq(
    bad({
      "note_id": Json("n1"),
      "piece": Json(0),
      "media": Json(""),
      "source": footage,
    }),
    "selected track marker 1: media is empty",
  )
  assert_eq(
    bad({ "note_id": Json("n1"), "piece": Json(0), "media": Json(url) }),
    "selected track marker 1: missing source",
  )
  assert_eq(
    bad({
      "note_id": Json("n1"),
      "piece": Json(0),
      "media": Json(url),
      "source": j_span(31L, 31L),
    }),
    "selected track marker 1.source: expected a nonempty nonnegative exact frame interval",
  )
  assert_eq(
    bad({
      "note_id": Json("n1"),
      "piece": Json(0),
      "media": Json(url),
      "source": j_obj({ "start": frame_json(30L), "stop": Json::number(31.5) }),
    }),
    "selected track marker 1.source.stop: expected a nonnegative exact integer",
  )
  let foreign = j_obj({
    "OTIO_SCHEMA": Json("Marker.9"),
    "name": Json("check"),
    "marked_range": j_range(0L, 3L, rate),
    "metadata": j_empty(),
  })
  assert_eq(
    error_of([with_origin(foreign, sound)]),
    "selected track marker 0: unsupported schema Marker.9",
  )
}

