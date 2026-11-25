///|
test "the intersection is where two ranges share frames" {
  assert_eq(@spans.intersection(0L, 5L, 3L, 9L), Some((3L, 5L)))
  assert_eq(@spans.intersection(3L, 9L, 0L, 5L), Some((3L, 5L)))
  assert_eq(@spans.intersection(0L, 3L, 3L, 9L), None)
  assert_eq(@spans.intersection(4L, 9L, 0L, 4L), None)
  assert_eq(@spans.intersection(4L, 9L, 6L, 7L), Some((6L, 7L)))
  assert_eq(@spans.intersection(4L, 9L, 0L, 100L), Some((4L, 9L)))
}

///|
test "the first place from which a value is above the bound" {
  let given = [5L, 3L, 9L, 2L, 9L, 1L]
  let stops : FixedArray[Int64] = FixedArray::makei(given.length(), i => given[i])
  let wanted = [5L, 5L, 9L, 9L, 9L, 9L]
  let reach = FixedArray::makei(wanted.length(), i => wanted[i])
  assert_eq(@spans.running_max(stops, 0L), reach)
  assert_eq(@spans.running_max(stops, 7L)[1], 7L)
  for bound = 0L; bound <= 10L; bound = bound + 1L {
    assert_eq(@spans.first_high(stops, 0L, bound), @spans.first_above(reach, bound))
  }
  assert_eq(@spans.first_high(stops, 0L, 0L), 0)
  assert_eq(@spans.first_high(stops, 0L, 5L), 2)
  assert_eq(@spans.first_high(stops, 0L, 9L), 6)
  let none : FixedArray[Int64] = FixedArray::make(0, 0L)
  assert_eq(@spans.first_high(none, 0L, 3L), 0)
  assert_eq(@spans.running_max(none, 7L).length(), 0)
}

///|
test "the sum of two counts, where it can be named" {
  assert_eq(@spans.summed(2L, 3L), Some(5L))
  assert_eq(@spans.summed(0L, 0L), Some(0L))
  assert_eq(@spans.summed(9007199254740990L, 1L), Some(9007199254740991L))
  assert_eq(@spans.summed(9007199254740991L, 1L), None)
  assert_eq(@spans.summed(9007199254740991L, 9007199254740991L), None)
  assert_eq(@spans.summed(-1L, 3L), None)
  assert_eq(@spans.summed(3L, -1L), None)
}
