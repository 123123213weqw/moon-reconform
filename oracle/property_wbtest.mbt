///|
test "every review the generator makes is answered as the oracle says" {
  @quickcheck.check(
    (case : Case) => {
      let _ = verify(case)
      true
    },
    count=4000,
    max_size=12,
    max_shrinks=300,
    seed=1729,
    counterexample_context=case => render(case),
  )
}

///|
test "a cut compared with itself puts every annotation back where it was" {
  @quickcheck.check(
    (both : (Cut, Array[Mark])) => {
      let (cut, marks) = both
      self_mapped(cut, marks)
      true
    },
    count=2000,
    max_size=10,
    max_shrinks=300,
    seed=4104,
    counterexample_context=both => {
      let (cut, marks) = both
      render({ cuts: [cut], marks, picks: [], switches: 0 })
    },
  )
  // The same cut with its footage 256 frames below two to the
  // fifty-third: the tracks are as short, and every frame number that
  // leaves the tool is near the last one it can write.
  @quickcheck.check(
    (both : (Cut, Array[Mark])) => {
      let (cut, marks) = both
      self_mapped(cut, marks, far=far_away)
      true
    },
    count=2000,
    max_size=10,
    max_shrinks=300,
    seed=4105,
    counterexample_context=both => {
      let (cut, marks) = both
      render({ cuts: [cut], marks, picks: [], switches: 0 })
    },
  )
}

///|
fn judged_alike(token : String) -> Unit raise {
  if !agree(token) {
    fail(
      "the number " +
      token +
      " is judged " +
      @debug.to_string(judged(token)) +
      " and read " +
      @debug.to_string(read_as(token)),
    )
  }
}

///|
test "a frame count is read exactly as its digits say, or refused" {
  @quickcheck.check(
    (raw : Token) => {
      judged_alike(written(raw))
      true
    },
    count=3000,
    max_size=6,
    max_shrinks=200,
    seed=271828,
    counterexample_context=raw => written(raw),
  )
}

///|
test "the numbers on the edge of what a frame count can be" {
  // Each is a number JSON allows. The judge and the tool must agree on
  // every one of them.
  for token in [
    "0", "-0", "0.000", "0e999999999", "-0.0e-999999999", "1e0", "1E+2", "1.5e1",
    "1.50e1", "10.0e-1", "100e-2", "1000000000000000000000000000000e-30",
    "0.000000000e-10000000", "9007199254740991", "90071992547409910e-1",
    "45035996273704960e-1", "12345000.00000e-3", "0.1e1", "0.10e1",
    "1.000", "1e-400", "1e400", "1e309", "1e-1", "1.5", "-1", "-1e400",
    "1.0000000000000001", "9007199254740990.49", "9007199254740992",
    "9007199254740993", "1e16", "1e15", "9007199254740991.000",
    "9007199254740991.0000000000000000000", "0.050e2", "0.005e3", "250e-3",
    "25e-2", "0.25",
  ] {
    judged_alike(token)
  }
  // None of these is a number as JSON writes one. The reader at the
  // command line refuses them before the tool sees a frame count, and the
  // judge refuses them here.
  assert_eq(judged("9007199254740991"), Some(9007199254740991L))
  assert_eq(judged("90071992547409910e-1"), Some(9007199254740991L))
  assert_eq(judged("1e16"), None)
  assert_eq(judged("1e15"), Some(1000000000000000L))
  assert_eq(judged("1.5"), None)
  assert_eq(judged("-0.0"), Some(0L))
  assert_eq(judged("0.050e2"), Some(5L))
  assert_eq(judged("0.005e3"), Some(5L))
  assert_eq(judged("250e-3"), None)
  assert_eq(judged("25e-2"), None)
  // Not numbers at all, to the judge as to JSON.
  for token in ["007", "7.", ".7", "1e", "1e+", "--1", "1.5.5", "0x10"] {
    assert_eq(judged(token), None)
  }
}
