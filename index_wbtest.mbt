///|
/// The searches are made over values that only rise; that is what the
/// proved kernel is promised, so it is checked here where the promises are
/// made: a timeline's stops, and what each group of footage reaches.
fn rises(values : FixedArray[Int64]) -> Bool {
  for i = 0; i + 1 < values.length(); i = i + 1 {
    if values[i] >= values[i + 1] {
      return false
    }
  }
  true
}

///|
fn never_falls(values : FixedArray[Int64]) -> Bool {
  for i = 0; i + 1 < values.length(); i = i + 1 {
    if values[i] > values[i + 1] {
      return false
    }
  }
  true
}

///|
test "a timeline's stops only rise" {
  let shots = [
    Clip("file:///a.mov", { start: 5L, stop: 9L }),
    Gap(3L),
    Unplaceable(Offline, 1L),
    Clip("file:///b.mov", { start: 9007199254740736L, stop: 9007199254740991L }),
    Gap(2147483648L),
    Unplaceable(Transition, 12L),
    Clip("file:///a.mov", { start: 0L, stop: 1L }),
  ]
  let timeline = Timeline::from_shots(shots)
  assert_true(rises(timeline.stops))
  assert_eq(timeline.stops[timeline.stops.length() - 1], timeline.duration())
  // The first shot that stops after a frame is found where it lies, far
  // from the first or one past the last.
  assert_eq(timeline.first_shot(0L), 0)
  assert_eq(timeline.first_shot(3L), 0)
  assert_eq(timeline.first_shot(4L), 1)
  assert_eq(timeline.first_shot(7L), 2)
  assert_eq(timeline.first_shot(timeline.duration() - 1L), shots.length() - 1)
  assert_eq(timeline.first_shot(timeline.duration()), shots.length())
  assert_eq(timeline.first_shot(9007199254740991L), shots.length())
  let empty = Timeline::from_shots([])
  assert_eq(empty.stops.length(), 0)
  assert_eq(empty.first_shot(0L), 0)
}

///|
test "what each group of footage reaches never falls, and hides no stop" {
  // Shots of one footage, out of order in what they show, as a re-cut
  // leaves them: their stops on the footage rise and fall.
  let shots = [
    Clip("file:///a.mov", { start: 40L, stop: 50L }),
    Clip("file:///b.mov", { start: 0L, stop: 3L }),
    Clip("file:///a.mov", { start: 0L, stop: 9L }),
    Gap(1L),
    Clip("file:///a.mov", { start: 45L, stop: 46L }),
    Clip("file:///c.mov", { start: 8589934597L, stop: 8589934600L }),
  ]
  let index = index_sources(Timeline::from_shots(shots))
  assert_eq(index.length(), 3)
  let group = index.get("file:///a.mov").unwrap()
  assert_eq(group.shots.length(), 3)
  // Sorted by what they show: [0,9), [40,50), [45,46).
  assert_true(never_falls(group.reach))
  assert_eq(group.reach[0], 9L)
  assert_eq(group.reach[1], 50L)
  assert_eq(group.reach[2], 50L)
  // Frame 8 is shown by the second shot alone, frame 45 by the first and
  // the third, and frame 49 by the first alone.
  let found = group.overlapping({ start: 45L, stop: 46L }, Ref(1000))
  assert_eq(found.map(shot => shot.clip), [0, 4])
  assert_eq(
    group.overlapping({ start: 8L, stop: 9L }, Ref(1000)).map(shot => shot.clip),
    [2],
  )
  assert_eq(
    group.overlapping({ start: 49L, stop: 50L }, Ref(1000)).map(shot => shot.clip),
    [0],
  )
  // Nothing shows frame 60.
  assert_eq(group.overlapping({ start: 60L, stop: 61L }, Ref(1000)).length(), 0)
  // A gap before the group's footage: the search starts past nothing.
  assert_eq(group.overlapping({ start: 0L, stop: 1L }, Ref(1000)).length(), 1)
  let far = index.get("file:///c.mov").unwrap()
  assert_true(never_falls(far.reach))
  assert_eq(
    far
    .overlapping({ start: 8589934598L, stop: 8589934599L }, Ref(1000))
    .map(shot => shot.clip),
    [5],
  )
}
