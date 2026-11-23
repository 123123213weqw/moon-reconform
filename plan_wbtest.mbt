///|
test "partition preserves range and boundary ownership across gaps, trims and repeats" {
  let before = Timeline::from_shots([
    Clip("A", { start: 10L, stop: 20L, }),
    Clip("B", { start: 100L, stop: 104L, }),
    Gap(2L),
    Clip("C", { start: 1L, stop: 5L, }),
  ])
  let after = Timeline::from_shots([
    Clip("B", { start: 100L, stop: 104L, }),
    Clip("A", { start: 12L, stop: 15L, }),
    Gap(2L),
    Clip("A", { start: 14L, stop: 18L, }),
    Clip("C", { start: 2L, stop: 5L, }),
  ])
  let reports = plan(before, after, [
    {
      id: "whole",
      text: "whole range",
      range: { start: 0L, stop: 20L, },
      media: None,
      origin: None,
    },
    {
      id: "repeat",
      text: "pick",
      range: { start: 4L, stop: 5L, },
      media: None,
      origin: None,
    },
    {
      id: "cut",
      text: "old shot B",
      range: { start: 10L, stop: 11L, },
      media: None,
      origin: None,
    },
  ])
  let pieces = reports[0].pieces
  assert_eq(
    pieces.map(piece => {
      match piece.old {
        Some(span) => span.start
        None => -1L
      }
    }),
    [0L, 2L, 4L, 5L, 8L, 10L, 14L, 16L, 17L],
  )
  assert_eq(
    pieces.map(piece => {
      match piece.old {
        Some(span) => span.stop
        None => -1L
      }
    }),
    [2L, 4L, 5L, 8L, 10L, 14L, 16L, 17L, 20L],
  )
  assert_true(pieces[0].kind is Deleted)
  assert_true(pieces[1].kind is Unique)
  assert_true(pieces[2].kind is Ambiguous)
  assert_true(pieces[6].kind is GapPiece)
  assert_eq(pieces[2].candidates.map(p => p.range.start), [6L, 9L])
  assert_eq(pieces[3].candidates.map(p => p.range.start), [10L])
  let open = resolve(reports, [])
  assert_eq(open.held, ["whole", "repeat"])
  assert_eq(open.transfers[0].placement.range.start, 0L)
  let confirmed = resolve(reports, [{ note_id: "repeat", piece: 0, clip: 3, }])
  assert_eq(confirmed.held, ["whole"])
  assert_eq(confirmed.transfers.map(t => t.placement.range.start), [9L, 0L])
  let invalid = Ok(
    resolve(reports, [{ note_id: "repeat", piece: 0, clip: 2, }]),
  ) catch {
    error => Err(error)
  }
  assert_true(invalid is Err(Invalid(_)))
}

///|
test "large exact frames need only one interval and overflowing sums fail" {
  let before = Timeline::from_shots([
    Clip("A", { start: 0L, stop: max_frames, }),
  ])
  let after = Timeline::from_shots([
    Clip("A", { start: max_frames - 10L, stop: max_frames, }),
  ])
  let report = plan(before, after, [
    {
      id: "last",
      text: "",
      range: { start: max_frames - 1L, stop: max_frames, },
      media: None,
      origin: None,
    },
  ])
  assert_eq(report[0].pieces[0].candidates[0].range.start, 9L)
  assert_eq(report[0].pieces[0].candidates[0].range.stop, 10L)
  let excessive = Ok(Timeline::from_shots([Gap(max_frames), Gap(1L)])) catch {
    error => Err(error)
  }
  assert_true(excessive is Err(Limit(_)))
  let duplicate = Ok(plan(before, after, [report[0].note, report[0].note])) catch {
    error => Err(error)
  }
  assert_true(duplicate is Err(Invalid(_)))
  // A frame is printed with every digit. A double happens to hold these
  // exactly, but the printed text is what a later request reads back.
  assert_eq(frame_json(max_frames).stringify(), "9007199254740991")
  assert_eq(frame_json(4503599627370496L + 7L).stringify(), "4503599627370503")
}

///|
test "numeric token integrality rejects binary64 rounding and underflow" {
  assert_true(integral_token("9007199254740991.00000", is_zero=false))
  assert_true(integral_token("12345000.00000e-3", is_zero=false))
  assert_true(integral_token("0.000000000e-10000000", is_zero=true))
  assert_false(integral_token("1.0000000000000001", is_zero=false))
  assert_false(integral_token("9007199254740990.49", is_zero=false))
  assert_false(integral_token("1e-100000000", is_zero=true))
}

///|
test "source-anchored annotations resolve against the new cut alone" {
  // The old cut is one unrelated shot: a source-anchored annotation reads
  // nothing from it, which is what lets a held annotation outlive the cut
  // it was written on.
  let before = Timeline::from_shots([Clip("B", { start: 100L, stop: 104L, })])
  let after = Timeline::from_shots([
    Clip("B", { start: 100L, stop: 104L, }),
    Clip("A", { start: 12L, stop: 15L, }),
    Gap(2L),
    Clip("A", { start: 14L, stop: 18L, }),
    Clip("C", { start: 2L, stop: 5L, }),
  ])
  let reports = plan(before, after, [
    {
      id: "gone",
      text: "",
      range: { start: 30L, stop: 33L, },
      media: Some("A"),
      origin: None,
    },
    {
      id: "once",
      text: "",
      range: { start: 16L, stop: 18L, },
      media: Some("A"),
      origin: None,
    },
    {
      id: "twice",
      text: "",
      range: { start: 14L, stop: 16L, },
      media: Some("A"),
      origin: None,
    },
    {
      id: "unknown",
      text: "",
      range: { start: 0L, stop: 2L, },
      media: Some("Z"),
      origin: None,
    },
  ])
  // Footage that left the cut is deleted, and never had an old-track range.
  assert_eq(reports[0].pieces.length(), 1)
  assert_true(reports[0].pieces[0].kind is Deleted)
  assert_true(reports[0].pieces[0].old is None)
  guard reports[0].pieces[0].source is Some(source) else {
    abort("source missing")
  }
  assert_eq(source.start, 30L)
  assert_eq(source.stop, 33L)
  // A[16,18) sits once in the new cut, inside its fourth child.
  assert_true(reports[1].pieces[0].kind is Unique)
  assert_eq(reports[1].pieces[0].candidates[0].clip, 3)
  assert_eq(reports[1].pieces[0].candidates[0].range.start, 11L)
  // A[14,16) sits in two children. The shared frame range is ambiguous and
  // the rest is unique, so the annotation splits at 15.
  assert_eq(reports[2].pieces.length(), 2)
  assert_true(reports[2].pieces[0].kind is Ambiguous)
  assert_eq(reports[2].pieces[0].candidates.map(p => p.range.start), [6L, 9L])
  assert_true(reports[2].pieces[1].kind is Unique)
  assert_true(reports[3].pieces[0].kind is Deleted)
  let resolution = resolve(reports, [{ note_id: "twice", piece: 0, clip: 3, }])
  assert_eq(resolution.held, ["gone", "unknown"])
  assert_eq(resolution.transfers.map(t => t.placement.range.start), [
    11L, 9L, 10L,
  ])
  // An empty media key names footage that cannot exist in any cut.
  let empty = Ok(
    plan(before, after, [
      {
        id: "e",
        text: "",
        range: { start: 0L, stop: 1L, },
        media: Some(""),
        origin: None,
      },
    ]),
  ) catch {
    error => Err(error)
  }
  assert_true(empty is Err(Invalid(_)))
}

///|
fn same_kind(left : PieceKind, right : PieceKind) -> Bool {
  match (left, right) {
    (Unique, Unique) => true
    (Ambiguous, Ambiguous) => true
    (Deleted, Deleted) => true
    (GapPiece, GapPiece) => true
    _ => false
  }
}

///|
test "carried restates held annotations by source and re-plans identically" {
  let before = Timeline::from_shots([
    Clip("A", { start: 10L, stop: 20L, }),
    Clip("B", { start: 100L, stop: 104L, }),
    Gap(2L),
    Clip("C", { start: 1L, stop: 5L, }),
  ])
  let after = Timeline::from_shots([
    Clip("B", { start: 100L, stop: 104L, }),
    Clip("A", { start: 12L, stop: 15L, }),
    Gap(2L),
    Clip("A", { start: 14L, stop: 18L, }),
    Clip("C", { start: 2L, stop: 5L, }),
  ])
  let reports = plan(before, after, [
    {
      id: "whole",
      text: "whole range",
      range: { start: 0L, stop: 20L, },
      media: None,
      origin: None,
    },
    {
      id: "repeat",
      text: "pick",
      range: { start: 4L, stop: 5L, },
      media: None,
      origin: None,
    },
  ])
  let notes = carried(reports, resolve(reports, []))
  // Eight held pieces of "whole" have footage and "repeat" has one. The
  // piece on old-track black has no footage, so no annotation carries it.
  assert_eq(notes.length(), 9)
  assert_eq(notes.map(note => note.id), [
    "whole#0", "whole#1", "whole#2", "whole#3", "whole#4", "whole#5", "whole#7",
    "whole#8", "repeat#0",
  ])
  assert_eq(notes[0].media, Some("A"))
  assert_eq(notes[0].range.start, 10L)
  assert_eq(notes[0].range.stop, 12L)
  assert_eq(notes[0].text, "whole range")
  // Planned against the same new cut, with no old cut at all, each carried
  // piece lands exactly where the held annotation's piece did.
  let expected : Array[Piece] = []
  for i in [0, 1, 2, 3, 4, 5, 7, 8] {
    expected.push(reports[0].pieces[i])
  }
  expected.push(reports[1].pieces[0])
  let again = plan(Timeline::from_shots([]), after, notes)
  assert_eq(again.length(), expected.length())
  for i, piece in expected {
    let replanned = again[i].pieces
    assert_eq(replanned.length(), 1)
    assert_true(same_kind(replanned[0].kind, piece.kind))
    assert_eq(
      replanned[0].candidates.map(p => (p.clip, p.range.start, p.range.stop)),
      piece.candidates.map(p => (p.clip, p.range.start, p.range.stop)),
    )
    assert_true(replanned[0].old is None)
  }
  // A carried piece that is held again carries on with a second suffix.
  let once_more = carried(again, resolve(again, []))
  assert_eq(once_more[0].id, "whole#0#0")
}
