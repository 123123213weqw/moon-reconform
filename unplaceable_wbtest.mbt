///|
/// A clip whose media has no location of its own, here `schema`.
fn j_offline(schema : String, start : Int64, duration : Int64) -> Json {
  j_obj({
    "OTIO_SCHEMA": Json("Clip.1"),
    "name": Json("no media of its own"),
    "media_reference": j_obj({
      "OTIO_SCHEMA": Json(schema),
      "name": Json(""),
      "metadata": j_empty(),
    }),
    "metadata": j_empty(),
    "source_range": j_range(start, duration, Rate::whole(24)),
    "markers": Json::array([]),
    "effects": Json::array([]),
    "enabled": Json::boolean(true),
  })
}

///|
fn j_transition(entering : Int64, leaving : Int64) -> Json {
  j_obj({
    "OTIO_SCHEMA": Json("Transition.1"),
    "name": Json("dissolve"),
    "metadata": j_empty(),
    "transition_type": Json("SMPTE_Dissolve"),
    "parameters": j_empty(),
    "in_offset": j_rt(entering, Rate::whole(24)),
    "out_offset": j_rt(leaving, Rate::whole(24)),
    "enabled": Json::boolean(true),
    "effects": Json::array([]),
  })
}

///|
/// A sequence nested into the track as one clip, as long as it says.
fn j_nested(duration : Int64) -> Json {
  j_obj({
    "OTIO_SCHEMA": Json("Stack.1"),
    "name": Json("sub-sequence"),
    "metadata": j_empty(),
    "source_range": j_range(0L, duration, Rate::whole(24)),
    "children": Json::array([]),
    "markers": Json::array([]),
    "effects": Json::array([]),
    "enabled": Json::boolean(true),
  })
}

///|
fn j_children(document : Json) -> Array[Json] raise ReconformError {
  let tracks = array(j_at(document, ["tracks", "children"]), "tracks")
  array(
    required(object(tracks[0], "track"), "children", "track"),
    "track.children",
  )
}

///|
/// A copy of the document whose first track child has `key` set to `value`.
fn j_child_with(document : Json, key : String, value : Json) -> Json raise ReconformError {
  let fields = object(j_children(document)[0], "child").copy()
  fields[key] = value
  let children = j_children(document).copy()
  children[0] = Json::object(fields)
  let rebuilt = j_timeline(j_track(children, []))
  rebuilt
}

///|
fn j_at(node : Json, keys : Array[String]) -> Json raise ReconformError {
  let mut here = node
  for key in keys {
    here = required(object(here, "node"), key, "node")
  }
  here
}

///|
fn j_kinds(report : NoteReport) -> Array[String] {
  report.pieces.map(piece =>
    match piece.kind {
      Unique => "unique"
      Ambiguous => "ambiguous"
      Deleted => "deleted"
      GapPiece => "gap"
      OfflinePiece => "offline"
      TransitionPiece => "transition"
      NestedPiece => "nested"
    })
}

///|
test "children that hold no footage are reported where they are, not refused" {
  let rate = Rate::whole(24)
  let url = "file:///shoot/A.mov"
  // Four frames of A, then a clip whose media is missing, a transition of
  // two frames into the next clip and three out of the last, four frames
  // of a nested sequence, two of black, and four frames of A again.
  let old_cut = j_timeline(
    j_track(
      [
        j_clip(url, 0L, 4L, rate),
        j_offline("MissingReference.1", 40L, 4L),
        j_transition(2L, 3L),
        j_nested(4L),
        j_gap(2L, rate),
        j_clip(url, 10L, 4L, rate),
      ],
      [],
    ),
  )
  let new_cut = j_timeline(
    j_track(
      [
        j_gap(1L, rate),
        j_clip(url, 0L, 4L, rate),
        j_offline("GeneratorReference.1", 0L, 2L),
        j_transition(1L, 1L),
        j_nested(3L),
        j_clip(url, 10L, 4L, rate),
      ],
      [],
    ),
  )
  let before = read_otio(old_cut, track_index=0, fps=rate)
  let after = read_otio(new_cut, track_index=0, fps=rate)
  assert_eq(before.duration(), 23L)
  assert_eq(after.duration(), 16L)
  let reports = plan(before, after, [
    j_note("footage", "on A", 0, 4),
    j_note("across", "A, missing media, a transition", 2, 13),
    j_note("nested", "inside the sub-sequence", 13, 17),
    j_note("last", "A again", 19, 23),
  ])
  assert_eq(j_kinds(reports[0]), ["unique"])
  assert_eq(
    reports[1].pieces.map(piece => (piece.old.unwrap().start, piece.old.unwrap().stop)),
    [(2L, 4L), (4L, 8L), (8L, 13L)],
  )
  assert_eq(j_kinds(reports[1]), ["unique", "offline", "transition"])
  for i, piece in reports[1].pieces {
    if i == 0 {
      continue
    }
    assert_true(piece.media is None && piece.source is None)
    assert_eq(piece.candidates.length(), 0)
  }
  assert_eq(j_kinds(reports[2]), ["nested"])
  assert_eq(j_kinds(reports[3]), ["unique"])
  // The footage on either side of the stretch lands; the annotation that
  // crosses it is held whole, and carries only the footage it has.
  let resolution = resolve(reports, [])
  assert_eq(resolution.held, ["across", "nested"])
  assert_eq(resolution.transfers.map(t => t.note_id), ["footage", "last"])
  assert_eq(
    resolution.transfers.map(t => (t.placement.clip, t.placement.range.start)),
    [(1, 1L), (5, 12L)],
  )
  let travel = carried(reports, resolution)
  assert_eq(travel.map(note => (note.id, note.range.start, note.range.stop)), [
    ("across#0", 2L, 4L),
  ])
  // In the new cut such children take up time and are never a target:
  // A[10,12) is missing there and lands nowhere, though the nested
  // sequence runs over those frames.
  let missing = plan(
    before,
    after,
    [j_note("gone", "A[10,12)", 0, 1)],
  )
  assert_eq(j_kinds(missing[0]), ["unique"])

  // The report names each kind, and the export hands those children back.
  let shown = report_json(before, after, reports, resolution).stringify()
  for status in ["offline", "transition", "nested"] {
    assert_true(shown.contains("\"status\":\"" + status + "\""))
  }
  let written = with_markers(new_cut, track_index=0, fps=rate, resolution)
  assert_eq(
    Json::array(j_children(written)).stringify(),
    Json::array(j_children(new_cut)).stringify(),
  )
  assert_eq(j_markers(written).length(), 2)

  // What cannot be laid out is still refused, and by name.
  fn without(child : Json, key : String) -> String raise ReconformError {
    j_message(j_child_with(j_timeline(j_track([child], [])), key, Json::null()))
  }
  assert_eq(
    without(j_offline("MissingReference.1", 0L, 4L), "source_range"),
    "track child 0: a clip with no media of its own (MissingReference.1) has to say how long it is with a source_range",
  )
  assert_eq(
    j_message(j_timeline(j_track([j_transition(0L, 0L)], []))),
    "track child 0: a transition has to last at least one frame",
  )
  let muted = j_timeline(j_track([j_transition(1L, 1L)], []))
  assert_eq(
    j_message(j_child_with(muted, "enabled", Json::boolean(false))),
    "track child 0: expected an enabled OTIO item",
  )
  assert_eq(
    without(j_nested(4L), "source_range"),
    "track child 0: a nested sequence has to say how long it is with a source_range",
  )
  let empty = Ok(Timeline::from_shots([Unplaceable(Offline, 0L)])) catch {
    error => Err(error)
  }
  assert_true(empty is Err(Invalid(_)))
}
