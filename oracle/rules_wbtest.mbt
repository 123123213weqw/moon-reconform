///|
/// What a refusal says. Whatever is asked has to raise: a call that
/// returns has broken its rule just the same.
fn refusal(ask : () -> Unit raise) -> String {
  try {
    ask()
    "nothing was raised"
  } catch {
    error => words(error)
  }
}

///|
/// A refusal that says exactly this.
fn says(wanted : String, ask : () -> Unit raise) -> Unit raise {
  let got = refusal(ask)
  if got != wanted {
    fail("the refusal says \"" + got + "\" and should say \"" + wanted + "\"")
  }
}

///|
/// A refusal that ends in these words, wherever the document is named.
fn ends_with(wanted : String, ask : () -> Unit raise) -> Unit raise {
  let got = refusal(ask)
  if !got.has_suffix(wanted) {
    fail(
      "the refusal says \"" +
      got +
      "\" and should end with \"" +
      wanted +
      "\"",
    )
  }
}

///|
/// A refusal that says these words somewhere.
fn mentions(wanted : String, ask : () -> Unit raise) -> Unit raise {
  let got = refusal(ask)
  if !got.contains(wanted) {
    fail(
      "the refusal says \"" +
      got +
      "\" and should mention \"" +
      wanted +
      "\"",
    )
  }
}

///|
fn rerated_value(value : Json, token : String, rate : Double) -> Json {
  match value {
    Array(list) => Json::array(list.map(item => rerated_value(item, token, rate)))
    Object(fields) =>
      if fields.get("OTIO_SCHEMA") is Some(String("RationalTime.1")) {
        let out : Map[String, Json] = Map([])
        for key, item in fields {
          out[key] = item
        }
        out["rate"] = Json::number(rate, repr=token)
        Json::object(out)
      } else {
        let out : Map[String, Json] = Map([])
        for key, item in fields {
          out[key] = rerated_value(item, token, rate)
        }
        Json::object(out)
      }
    _ => value
  }
}

///|
/// The same document with every rate written as `token` says.
fn rerated(value : Json, token : String) -> Json raise {
  rerated_value(value, token, @string.parse_double(token))
}

///|
/// One annotation on the old track, one frame wide.
fn annotation(index : Int, at : Int64) -> Json {
  Json::object({
    "id": Json("a" + index.to_string()),
    "text": Json("审阅 " + index.to_string()),
    "start": frame(at),
  })
}

///|
/// `count` such annotations, each on the same frame.
fn annotations(count : Int, at : Int64) -> Array[Json] {
  let out = []
  for index = 0; index < count; index = index + 1 {
    out.push(annotation(index, at))
  }
  out
}

///|
/// The request that goes with them.
fn asked_for(
  notes : Array[Json],
  selections : Array[Json],
  rate~ : @tool.Rate = @tool.Rate::whole(24),
) -> Json {
  Json::object({
    "fps": Json::number(rate.value, repr=rate.token),
    "old_track": Json(0),
    "new_track": Json(0),
    "notes": Json::array(notes),
    "selections": Json::array(selections),
    "from_markers": Json(false),
  })
}

///|
/// The notes of a request, or its refusal.
fn notes_of(request : Json) -> Array[@tool.Note] raise {
  @tool.read_request(request).notes
}

///|
/// The first `count` of a list.
fn taken(list : Array[@tool.Note], count : Int) -> Array[@tool.Note] {
  let out = []
  for index = 0; index < count; index = index + 1 {
    out.push(list[index])
  }
  out
}

///|
/// One cut of footage four frames long, and the same cut as a timeline.
fn one_cut() -> (Json, @tool.Timeline) raise {
  let document = sequence(
    plain_track([footage_clip("file:///shoot/X.mov", 0L, 4L)]),
    None,
  )
  let cut = @tool.read_otio(document, track_index=0, fps=@tool.Rate::whole(24))
  (document, cut)
}

///|
/// The budgets bound one analysis, not a document. A thousand annotations
/// that each make the index look at a thousand placements overrun the
/// search budget while the report stays small; fifty that each meet two
/// thousand placements overrun the report budget while the search stays
/// small. One annotation fewer than the limit is accepted and right, and
/// at the limit the refusal names the limit.
test "the search budget is met at 999 annotations and stepped past at 1000" {
  let x = "file:///shoot/X.mov"
  // Frame 1000 of the footage is shown by the long clip and by the one
  // clip that starts there; the clips from there on are each looked at.
  let crowded = [footage_clip(x, 0L, 100000L)]
  for k = 0; k < 1999; k = k + 1 {
    crowded.push(footage_clip(x, (k + 1).to_int64(), 1L))
  }
  let flat = sequence(plain_track([footage_clip(x, 0L, 2000L)]), None)
  let scanned = sequence(plain_track(crowded), None)
  let before = @tool.read_otio(flat, track_index=0, fps=@tool.Rate::whole(24))
  let after = @tool.read_otio(scanned, track_index=0, fps=@tool.Rate::whole(24))
  let met = notes_of(asked_for(annotations(999, 1000L), []))
  let reports = @tool.plan(before, after, met)
  assert_eq(reports.length(), 999)
  for i, report in reports {
    // The frame is in two places, so each annotation is held for a choice.
    if report.pieces.length() != 1 ||
      report.pieces[0].candidates.length() != 2 ||
      report.pieces[0].kind != @tool.Ambiguous {
      fail("annotation " + met[i].id + ": " + shown(report.pieces))
    }
  }
  assert_eq(@tool.resolve(reports, []).held.length(), 999)
  let over = notes_of(asked_for(annotations(1000, 1000L), []))
  says(
    "candidate search budget exceeded",
    () => ignore(@tool.plan(before, after, over)),
  )
}

///|
test "the report budget is met at 49 annotations and stepped past at 50" {
  let x = "file:///shoot/X.mov"
  let crowded = []
  for k = 0; k < 2000; k = k + 1 {
    crowded.push(footage_clip(x, 0L, 1L))
  }
  let lone = sequence(plain_track([footage_clip(x, 0L, 100L)]), None)
  let repeated = sequence(plain_track(crowded), None)
  let before = @tool.read_otio(lone, track_index=0, fps=@tool.Rate::whole(24))
  let after = @tool.read_otio(repeated, track_index=0, fps=@tool.Rate::whole(24))
  // A piece with two thousand places costs two thousand and one.
  let met = notes_of(asked_for(annotations(49, 0L), []))
  let reports = @tool.plan(before, after, met)
  assert_eq(reports.length(), 49)
  for i, report in reports {
    if report.pieces.length() != 1 ||
      report.pieces[0].candidates.length() != 2000 {
      fail("annotation " + met[i].id + ": " + shown(report.pieces))
    }
  }
  let over = notes_of(asked_for(annotations(50, 0L), []))
  says(
    "report piece and candidate budget exceeded",
    () => ignore(@tool.plan(before, after, over)),
  )
}

///|
/// A piece without footage costs the report budget too: one, for itself.
test "a black piece costs the report budget one" {
  let children = []
  for k = 0; k < 20000; k = k + 1 {
    children.push(black(1L))
  }
  let dark = sequence(plain_track(children), None)
  let cut = @tool.read_otio(dark, track_index=0, fps=@tool.Rate::whole(24))
  // An annotation across the whole track is twenty thousand pieces, and
  // costs twenty thousand: five fit the budget exactly and six do not.
  let whole = []
  for i = 0; i < 6; i = i + 1 {
    whole.push(
      Json::object({
        "id": Json("w" + i.to_string()),
        "text": Json("审阅"),
        "start": frame(0L),
        "stop": frame(20000L),
      }),
    )
  }
  let six = notes_of(asked_for(whole, []))
  let five = @tool.plan(cut, cut, taken(six, 5))
  assert_eq(five.length(), 5)
  for report in five {
    assert_eq(report.pieces.length(), 20000)
    assert_eq(report.pieces[0].kind, @tool.GapPiece)
  }
  assert_eq(@tool.resolve(five, []).held.length(), 5)
  says(
    "report piece and candidate budget exceeded",
    () => ignore(@tool.plan(cut, cut, six)),
  )
}

///|
/// Ten thousand annotations are read, ten thousand and one are not; a
/// hundred thousand manual choices are read, one more is not; and a track
/// of 20,000 children is read, one more is not.
test "the counts are met exactly and stepped past" {
  let (_, cut) = one_cut()
  let full = notes_of(asked_for(annotations(10000, 0L), []))
  assert_eq(full.length(), 10000)
  let reports = @tool.plan(cut, cut, full)
  assert_eq(@tool.resolve(reports, []).transfers.length(), 10000)
  says(
    "too many annotations; limit is 10000",
    () => ignore(notes_of(asked_for(annotations(10001, 0L), []))),
  )
  // The plan keeps the limit on its own, for notes that did not come
  // through a request.
  let direct = full.copy()
  direct.push(@tool.Note::{
    id: "one more",
    text: "审阅",
    range: { start: 0L, stop: 1L },
    media: None,
    origin: None,
  })
  says(
    "too many annotations; limit is 10000",
    () => ignore(@tool.plan(cut, cut, direct)),
  )
  let chosen = []
  for i = 0; i < 100001; i = i + 1 {
    ignore(i)
    chosen.push(
      Json::object({
        "note_id": Json("a0"),
        "piece": Json(0),
        "clip": Json(0),
      }),
    )
  }
  says(
    "too many manual selections",
    () => ignore(notes_of(asked_for([annotation(0, 0L)], chosen))),
  )

  // A track of exactly 20,000 children is still a timeline: here, black.
  let x = "file:///shoot/X.mov"
  let children = []
  for k = 0; k < 20000; k = k + 1 {
    children.push(black(1L))
  }
  let edges = @tool.read_otio(
    sequence(plain_track(children), None),
    track_index=0,
    fps=@tool.Rate::whole(24),
  )
  assert_eq(edges.duration(), 20000L)
  let held = @tool.plan(
    edges,
    cut,
    notes_of(asked_for([annotation(0, 0L)], [])),
  )
  assert_eq(@tool.resolve(held, []).held, ["a0"])
  let plus_one = [black(1L)]
  for child in children {
    plus_one.push(child)
  }
  let too_many = sequence(plain_track(plus_one), None)
  says(
    "too many shots; limit is 20000",
    () => ignore(@tool.read_otio(too_many, track_index=0, fps=@tool.Rate::whole(24))),
  )
  // A clip counts as much as black.
  plus_one[0] = footage_clip(x, 0L, 1L)
  let with_clip = sequence(plain_track(plus_one), None)
  says(
    "too many shots; limit is 20000",
    () => ignore(@tool.read_otio(with_clip, track_index=0, fps=@tool.Rate::whole(24))),
  )
  // A timeline built from shots keeps the same count.
  let shots = []
  for k = 0; k < 20001; k = k + 1 {
    ignore(k)
    shots.push(@tool.Gap(1L))
  }
  says(
    "too many shots; limit is 20000",
    () => ignore(@tool.Timeline::from_shots(shots)),
  )
  let shots_kept : Array[@tool.Shot] = []
  for k = 0; k < 20000; k = k + 1 {
    ignore(k)
    shots_kept.push(@tool.Gap(1L))
  }
  assert_eq(@tool.Timeline::from_shots(shots_kept).duration(), 20000L)
}

///|
/// A frame rate may be other than a whole number, as 23.976 and 29.97 are,
/// as long as both cuts and the request are at it. Nothing converts between
/// rates, so frame numbers stay exact whatever the rate is. A cut at
/// another rate is refused by name, and a rate that is not a positive
/// number at all is a bad rate rather than a bad integer.
test "a rate other than a whole number is read, and another rate is refused" {
  let (document, _) = one_cut()
  for written in ["29.97", "23.976", "59.94", "29.97002997002997"] {
    let rate : @tool.Rate = {
      value: @string.parse_double(written),
      token: written,
    }
    let cut = rerated(document, written)
    let asked = asked_for([annotation(0, 0L)], [], rate~)
    assert_eq(@tool.read_request(asked).fps, rate)
    let at_rate = @tool.read_otio(cut, track_index=0, fps=rate)
    let reports = @tool.plan(
      at_rate,
      at_rate,
      notes_of(asked),
    )
    assert_eq(
      @tool.resolve(reports, []).transfers.map(t => t.placement),
      [@tool.Placement::{ clip: 0, range: { start: 0L, stop: 1L } }],
    )
    // The markers the tool writes are at the same rate, and read back at it.
    let written_cut = @tool.with_markers(
      cut,
      track_index=0,
      fps=rate,
      @tool.resolve(reports, []),
    )
    assert_eq(markers_on(track_of_document(written_cut, 0)).length(), 1)
    assert_eq(
      @tool.read_notes_from_markers(written_cut, track_index=0, fps=rate).length(),
      1,
    )
  }
  // The same number written another way is the same rate; a different
  // number is a different rate, however close.
  let own = rerated(document, "24")
  let as_decimal = @tool.read_otio(
    own,
    track_index=0,
    fps=@tool.Rate::{ value: 24.0, token: "24.0" },
  )
  assert_eq(as_decimal.duration(), 4L)
  mentions(
    "RationalTime rate 24 differs from the request's 25 fps.",
    () => ignore(@tool.read_otio(own, track_index=0, fps=@tool.Rate::whole(25))),
  )
  let near = rerated(document, "29.97002997002997")
  mentions(
    "RationalTime rate 29.97002997002997 differs from the request's 29.97 fps",
    () => ignore(@tool.read_otio(near, track_index=0, fps=@tool.Rate::{ value: 29.97, token: "29.97" })),
  )
  // A rate that is not a positive number is a bad rate.
  for written in ["-24", "0", "1000001"] {
    ends_with(
      ".rate: expected a positive frame rate",
      () => ignore(
        @tool.read_otio(
          rerated(document, written),
          track_index=0,
          fps=@tool.Rate::whole(24),
        ),
      ),
    )
  }
  // Something that is not a number at all is not a rate.
  let not_a_number = rerated(document, "24")
  let fields = match not_a_number {
    Object(outer) => outer
    _ => fail("the document is not an object")
  }
  fields["name"] = Json(not_a_number)
  ignore(not_a_number)
  // The request's rate is a number from 1 to 240, whole or not.
  for fps in [0, 241] {
    says(
      "fps must be between 1 and 240",
      () => ignore(
        @tool.read_request(
          Json::object({
            "fps": Json(fps),
            "old_track": Json(0),
            "new_track": Json(0),
            "notes": Json::array([]),
            "selections": Json::array([]),
            "from_markers": Json(false),
          }),
        ),
      ),
    )
  }
  ends_with(
    "fps must be between 1 and 240",
    () => ignore(@tool.read_request(asked_for([], [], rate=@tool.Rate::{ value: 0.5, token: "0.5" }))),
  )
  // A frame count is still an exact integer, at any rate.
  ends_with(
    "a0.start: expected a nonnegative exact integer",
    () => ignore(
      notes_of(
        asked_for(
          [
            Json::object({
              "id": Json("a0"),
              "text": Json("审阅"),
              "start": Json::number(1.5),
            }),
          ],
          [],
        ),
      ),
    ),
  )
  says(
    "request.old_track: exceeds index range",
    () =>
      ignore(
        notes_of(
          Json::object({
            "fps": Json(24),
            "old_track": frame(2147483648L),
            "new_track": Json(0),
            "notes": Json::array([]),
            "selections": Json::array([]),
            "from_markers": Json(false),
          }),
        ),
      ),
  )
  says(
    "track index is outside the stack",
    () => ignore(@tool.read_otio(document, track_index=3, fps=@tool.Rate::whole(24))),
  )
}

///|
/// An annotation is exported once. To export it again onto the track that
/// already holds it would put two markers under one name.
test "an annotation is not exported twice onto one track" {
  let (document, cut) = one_cut()
  let reports = @tool.plan(
    cut,
    cut,
    notes_of(asked_for([annotation(0, 0L)], [])),
  )
  let resolution = @tool.resolve(reports, [])
  assert_eq(resolution.transfers.length(), 1)
  let written = @tool.with_markers(
    document,
    track_index=0,
    fps=@tool.Rate::whole(24),
    resolution,
  )
  assert_eq(markers_on(track_of_document(written, 0)).length(), 1)
  says(
    "an exported marker already exists for a0",
    () => ignore(@tool.with_markers(written, track_index=0, fps=@tool.Rate::whole(24), resolution)),
  )
}

///|
/// A track does not have to list markers at all. Where nothing transfers
/// the cut is handed back as it came, without an empty list of markers
/// added; where something does, the list is made for it.
test "a track that lists no markers is left as it came when nothing transfers" {
  let (document, cut) = one_cut()
  let bare = copied(document)
  guard track_of_document(bare, 0) is Object(fields) else {
    fail("the track is not an object")
  }
  fields.remove("markers")
  // The footage is gone from the new cut, so the annotation is held.
  let gone = sequence(plain_track([black(4L)]), None)
  let empty = sequence(plain_track([black(4L)]), None)
  let reports = @tool.plan(cut, @tool.read_otio(gone, track_index=0, fps=@tool.Rate::whole(24)), notes_of(asked_for([annotation(0, 0L)], [])))
  let resolution = @tool.resolve(reports, [])
  assert_eq(resolution.transfers.length(), 0)
  let written = @tool.with_markers(gone, track_index=0, fps=@tool.Rate::whole(24), resolution)
  if written != gone {
    fail("nothing transfers and the cut is not handed back as it came")
  }
  assert_eq(
    exported(gone, 0, resolution, slots(empty, 0)),
    written,
  )
  // Where something transfers onto a track that lists no markers, the
  // list is made.
  let kept = @tool.plan(cut, cut, notes_of(asked_for([annotation(0, 0L)], [])))
  let made = @tool.with_markers(bare, track_index=0, fps=@tool.Rate::whole(24), @tool.resolve(kept, []))
  assert_eq(markers_on(track_of_document(made, 0)).length(), 1)
  assert_eq(exported(bare, 0, @tool.resolve(kept, []), slots(bare, 0)), made)
}
