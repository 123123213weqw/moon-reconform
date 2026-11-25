///|
/// A drawn list of values, and the small numbers a search over it needs.
#derive(Eq, Debug)
pub(all) struct Draw {
  values : Array[Int32]
  from : Int32
  bound : Int32
  a : Int32
  b : Int32
  c : Int32
  d : Int32
}

///|
impl @quickcheck.Arbitrary for Draw with fn arbitrary(_size, r0) {
  // One to eight values between -2 and 5, so that repeats and falls are
  // common; the rest lies on as small a grid.
  let count = draw(8, r0) + 1
  let values = []
  for index = 0; index < count; index = index + 1 {
    values.push(draw(8, r0) - 2)
  }
  {
    values,
    from: draw(8, r0) - 2,
    bound: draw(8, r0) - 2,
    a: draw(8, r0),
    b: draw(8, r0),
    c: draw(16, r0),
    d: draw(8, r0),
  }
}

///|
/// No call names this implementation: it is what lets `check` shrink a
/// draw that fails, so the compiler cannot see it used.
#warnings("-unused_value")
impl @quickcheck.Shrink for Draw with fn shrink(self) -> Iter[Draw] {
  [| |]
}

///|
fn fixed(values : Array[Int32]) -> FixedArray[Int64] {
  FixedArray::makei(values.length(), i => values[i].to_int64())
}

///|
/// The largest of `from` and of the values up to a place, by looking at
/// every one of them.
fn largest_so_far(values : FixedArray[Int64], from : Int64, upto : Int) -> Int64 {
  let mut best = from
  for k = 0; k <= upto; k = k + 1 {
    if values[k] > best {
      best = values[k]
    }
  }
  best
}

///|
fn shown_values(values : FixedArray[Int64]) -> String {
  let parts = []
  for i = 0; i < values.length(); i = i + 1 {
    parts.push(values[i].to_string())
  }
  parts.join(",")
}

///|
/// The proved kernel against plain enumeration. A proof is only as good as
/// its reading of the rule, so the rule is restated here the slow way.
test "the running maximum is the largest so far at every place, and never falls" {
  @quickcheck.check(
    (draw : Draw) => {
      let values = fixed(draw.values)
      let from = draw.from.to_int64()
      let reach = @spans.running_max(values, from)
      if reach.length() != values.length() {
        fail("the running maximum is not as long as the values")
      }
      for i = 0; i < values.length(); i = i + 1 {
        let wanted = largest_so_far(values, from, i)
        if reach[i] != wanted {
          fail(
            "at place " +
            i.to_string() +
            " the running maximum is " +
            reach[i].to_string() +
            " and looking at every value gives " +
            wanted.to_string() +
            " for " +
            shown_values(values) +
            " from " +
            from.to_string(),
          )
        }
        if i > 0 && reach[i - 1] > reach[i] {
          fail("the running maximum falls at place " + i.to_string())
        }
      }
      true
    },
    count=3000,
    max_size=8,
    seed=1414,
    counterexample_context=draw => {
      shown_values(fixed(draw.values)) + " from " + draw.from.to_string()
    },
  )
}

///|
test "the search begins exactly where something first reaches past the bound" {
  @quickcheck.check(
    (draw : Draw) => {
      let values = fixed(draw.values)
      let from = draw.from.to_int64()
      let bound = draw.bound.to_int64()
      let mut wanted = values.length()
      for i = 0; i < values.length(); i = i + 1 {
        if largest_so_far(values, from, i) > bound {
          wanted = i
          break
        }
      }
      let found = @spans.first_high(values, from, bound)
      if found != wanted {
        fail(
          "the search begins at " +
          found.to_string() +
          " and looking at every value gives " +
          wanted.to_string() +
          " for " +
          shown_values(values) +
          " from " +
          from.to_string() +
          " past " +
          bound.to_string(),
        )
      }
      if @spans.first_above(@spans.running_max(values, from), bound) != wanted {
        fail("the search over the running maximum begins elsewhere")
      }
      true
    },
    count=3000,
    max_size=8,
    seed=1732,
    counterexample_context=draw => {
      shown_values(fixed(draw.values)) +
      " from " +
      draw.from.to_string() +
      " past " +
      draw.bound.to_string()
    },
  )
}

///|
test "the intersection is where two ranges share frames" {
  @quickcheck.check(
    (draw : Draw) => {
      // Two ranges on a small grid, each holding at least one frame.
      let a_start = (draw.a & 7).to_int64()
      let a_stop = a_start + 1L + (draw.b & 7).to_int64()
      let b_start = (draw.c & 15).to_int64()
      let b_stop = b_start + 1L + (draw.d & 7).to_int64()
      let mut shared = 0
      for frame = 0L; frame < 24L; frame = frame + 1L {
        let in_a = a_start <= frame && frame < a_stop
        let in_b = b_start <= frame && frame < b_stop
        if in_a && in_b {
          shared += 1
        }
      }
      let wanted = if shared == 0 {
        None
      } else {
        Some((
          if a_start > b_start { a_start } else { b_start },
          if a_stop < b_stop { a_stop } else { b_stop },
        ))
      }
      let found = @spans.intersection(a_start, a_stop, b_start, b_stop)
      if found != wanted {
        fail(
          "[" +
          a_start.to_string() +
          "," +
          a_stop.to_string() +
          ") and [" +
          b_start.to_string() +
          "," +
          b_stop.to_string() +
          " share " +
          shared.to_string() +
          " frames: the kernel says " +
          @debug.to_string(found),
        )
      }
      true
    },
    count=3000,
    max_size=8,
    seed=2237,
    counterexample_context=draw => {
      let a_start = (draw.a & 7).to_int64()
      let a_stop = a_start + 1L + (draw.b & 7).to_int64()
      let b_start = (draw.c & 15).to_int64()
      let b_stop = b_start + 1L + (draw.d & 7).to_int64()
      "[" +
      a_start.to_string() +
      "," +
      a_stop.to_string() +
      ") and [" +
      b_start.to_string() +
      "," +
      b_stop.to_string() +
      ")"
    },
  )
}

///|
test "a sum is named exactly while it can be" {
  let edges = [
    (0L, 0L),
    (9007199254740991L, 0L),
    (9007199254740990L, 1L),
    (9007199254740991L, 1L),
    (4503599627370496L, 4503599627370495L),
    (4503599627370496L, 4503599627370496L),
    (2147483648L, 2147483648L),
    (8589934592L, 0L),
    (-1L, 0L),
    (0L, -1L),
    (9007199254740991L, 9007199254740991L),
  ]
  for pair in edges {
    let (a, b) = pair
    let wanted = if a < 0L || b < 0L || a > 9007199254740991L - b {
      None
    } else {
      Some(a + b)
    }
    assert_eq(@spans.summed(a, b), wanted)
    assert_eq(@spans.last, 9007199254740991L)
  }
  @quickcheck.check(
    (draw : Draw) => {
      let a = draw.from.to_int64()
      let b = draw.bound.to_int64()
      let wanted = if a < 0L || b < 0L { None } else { Some(a + b) }
      if @spans.summed(a, b) != wanted {
        fail(
          "the sum of " +
          a.to_string() +
          " and " +
          b.to_string() +
          " is " +
          @debug.to_string(@spans.summed(a, b)),
        )
      }
      true
    },
    count=1000,
    max_size=8,
    seed=2649,
    counterexample_context=draw => {
      draw.from.to_string() + " and " + draw.bound.to_string()
    },
  )
}
