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
    { id: "whole", text: "whole range", range: { start: 0L, stop: 20L, }, },
    { id: "repeat", text: "pick", range: { start: 4L, stop: 5L, }, },
    { id: "cut", text: "old shot B", range: { start: 10L, stop: 11L, }, },
  ])
  let pieces = reports[0].pieces
  assert_eq(pieces.map(piece => piece.old.start), [
    0L, 2L, 4L, 5L, 8L, 10L, 14L, 16L, 17L,
  ])
  assert_eq(pieces.map(piece => piece.old.stop), [
    2L, 4L, 5L, 8L, 10L, 14L, 16L, 17L, 20L,
  ])
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
