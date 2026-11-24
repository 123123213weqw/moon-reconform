///|
test "an Audio track is a line of cuts like a Video track; other kinds are not" {
  let rate = 24
  let sound = "file:///shoot/A.wav"
  let old_cut = j_timeline(
    j_kind("Audio", [j_clip(sound, 40L, 8L, rate), j_gap(1L, rate)], []),
  )
  let new_cut = j_timeline(
    j_kind(
      "Audio",
      [j_clip(sound, 42L, 4L, rate), j_gap(2L, rate), j_clip(sound, 44L, 4L, rate)],
      [],
    ),
  )
  let before = read_otio(old_cut, track_index=0, fps=rate)
  let after = read_otio(new_cut, track_index=0, fps=rate)
  assert_eq(before.shot_count(), 2)
  let reports = plan(before, after, [
    {
      id: "line",
      text: "检查对白入点",
      range: { start: 2L, stop: 5L, },
      media: None,
      origin: None,
    },
  ])
  // A[42,45) is in the first new clip whole and in the third from 44, so
  // the note splits where the repeated footage begins.
  assert_eq(reports[0].pieces.length(), 2)
  assert_true(reports[0].pieces[0].kind is Unique)
  assert_true(reports[0].pieces[1].kind is Ambiguous)
  assert_eq(
    reports[0].pieces[1].candidates.map(p => (p.clip, p.range.start)),
    [(0, 2L), (2, 6L)],
  )
  let chosen = resolve(reports, [{ note_id: "line", piece: 1, clip: 2 }])
  assert_eq(
    chosen.transfers.map(t => (t.placement.clip, t.placement.range.start)),
    [(0, 0L), (2, 6L)],
  )
  // The markers land on the sound track and nowhere else.
  let written = with_markers(new_cut, track_index=0, fps=rate, chosen)
  assert_eq(j_markers(written).length(), 2)
  assert_eq(j_markers(new_cut).length(), 0)

  // A sequence keeps picture and sound apart: the second track is read
  // by its own index and holds its own shots.
  let picture = j_track([j_clip("file:///shoot/A.mov", 0L, 4L, rate)], [])
  let mixed = j_timeline(picture)
  let tracks = object(object(mixed, "timeline")["tracks"], "tracks")
  tracks["children"] = Json::array([picture, j_kind("Audio", [j_gap(3L, rate)], [])])
  assert_eq(read_otio(mixed, track_index=0, fps=rate).shot_count(), 1)
  assert_eq(read_otio(mixed, track_index=1, fps=rate).shot_count(), 1)
  assert_eq(read_otio(mixed, track_index=1, fps=rate).duration(), 3L)

  fn refusal(track : Json) -> String {
    let outcome = Ok(read_otio(j_timeline(track), track_index=0, fps=rate)) catch {
      error => Err(error)
    }
    match outcome {
      Err(Invalid(message)) => message
      _ => "no error raised"
    }
  }
  for kind in ["Transition", "video", "AUDIO", ""] {
    assert_eq(
      refusal(j_kind(kind, [j_gap(1L, rate)], [])),
      "selected track must be a Video or Audio track",
    )
  }

  // Whatever sits in the track's marker list is handed back unread, so it
  // has to be a marker. Every reader of the track says the same thing.
  let stray = j_kind("Audio", [j_clip(sound, 0L, 4L, rate)], [
    j_marker("fine", 0L, 1L, rate),
    Json::number(5.0),
  ])
  assert_eq(
    refusal(stray),
    "selected track marker 1: expected an object",
  )
  let listed = Ok(read_notes_from_markers(j_timeline(stray), track_index=0, fps=rate)) catch {
    error => Err(error)
  }
  assert_true(listed is Err(Invalid("selected track marker 1: expected an object")))
  let exported = Ok(
    with_markers(
      j_timeline(stray),
      track_index=0,
      fps=rate,
      resolve(
        plan(
          read_otio(j_timeline(stray), track_index=0, fps=rate),
          read_otio(j_timeline(stray), track_index=0, fps=rate),
          [],
        ),
        [],
      ),
    ),
  ) catch {
    error => Err(error)
  }
  assert_true(exported is Err(Invalid("selected track marker 1: expected an object")))
}

///|
fn j_note(id : String, text : String, start : Int64, stop : Int64) -> Note {
  { id, text, range: { start, stop, }, media: None, origin: None }
}

///|
fn j_media(url : String, first : Int64, length : Int64) -> Json {
  j_obj({
    "OTIO_SCHEMA": Json("ExternalReference.1"),
    "name": Json(""),
    "metadata": j_empty(),
    "target_url": Json(url),
    "available_range": j_range(first, length, 24),
  })
}

///|
/// One clip of `reference`. Without a source range it uses as much of its
/// media as there is.
fn j_take(reference : Json, source : Json?) -> Json {
  j_obj({
    "OTIO_SCHEMA": Json("Clip.1"),
    "name": Json("take"),
    "media_reference": reference,
    "metadata": j_empty(),
    "source_range": match source {
      Some(range) => range
      None => Json::null()
    },
    "markers": Json::array([]),
    "effects": Json::array([]),
    "enabled": Json::boolean(true),
  })
}

///|
fn j_message(document : Json) -> String {
  let outcome = Ok(read_otio(document, track_index=0, fps=24)) catch {
    error => Err(error)
  }
  match outcome {
    Err(Invalid(message)) => message
    Err(Limit(message)) => "limit: " + message
    _ => "no error raised"
  }
}

///|
test "a clip may use its media's range, and a name is matched byte for byte" {
  let rate = 24
  let url = "file:///shoot/A.mov"

  // A clip without a source range uses as much of its media as there is:
  // here A[30,34), of which the new cut keeps the first two frames.
  let whole = j_timeline(j_track([j_take(j_media(url, 30L, 4L), None)], []))
  let part = j_timeline(j_track([j_clip(url, 30L, 2L, rate)], []))
  let reports = plan(
    read_otio(whole, track_index=0, fps=rate),
    read_otio(part, track_index=0, fps=rate),
    [j_note("n", "whole take", 0L, 4L)],
  )
  assert_eq(reports[0].pieces.length(), 2)
  assert_eq(
    reports[0].pieces[0].candidates.map(p => (p.clip, p.range.start, p.range.stop)),
    [(0, 0L, 2L)],
  )
  assert_true(reports[0].pieces[0].source is Some({ start: 30L, stop: 32L, }))
  assert_true(reports[0].pieces[1].kind is Deleted)

  // A media key is matched byte for byte. The composed and the decomposed
  // spelling of one name are two media as far as this tool can tell.
  let composed = "file:///shoot/\u{e9}.mov"
  let decomposed = "file:///shoot/e\u{301}.mov"
  assert_eq(composed.length() == decomposed.length(), false)
  let here = j_timeline(j_track([j_clip(composed, 0L, 4L, rate)], []))
  let there = j_timeline(j_track([j_clip(decomposed, 0L, 4L, rate)], []))
  let split = plan(
    read_otio(here, track_index=0, fps=rate),
    read_otio(there, track_index=0, fps=rate),
    [j_note("n", "same file, two spellings", 0L, 4L)],
  )
  assert_true(split[0].pieces[0].kind is Deleted)
  let same = plan(
    read_otio(here, track_index=0, fps=rate),
    read_otio(here, track_index=0, fps=rate),
    [j_note("n", "one spelling", 0L, 4L)],
  )
  assert_true(same[0].pieces[0].kind is Unique)
}
