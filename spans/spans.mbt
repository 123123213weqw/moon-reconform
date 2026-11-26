///|
/// Where two half-open ranges overlap, as one range; none where they do
/// not. Both have to hold a frame, as every range in a cut does.
///
/// What comes back is the largest range inside both, and it is empty
/// exactly where one range ends before the other begins.
pub fn intersection(
  a_start : Int64,
  a_stop : Int64,
  b_start : Int64,
  b_stop : Int64,
) -> (Int64, Int64)? where {
  proof_require: a_start < a_stop,
  proof_require: b_start < b_stop,
  proof_ensure: result =>
    intersection_ok(a_start, a_stop, b_start, b_stop, result),
} {
  let start = if a_start > b_start { a_start } else { b_start }
  let stop = if a_stop < b_stop { a_stop } else { b_stop }
  if start < stop {
    Some((start, stop))
  } else {
    None
  }
}

///|
/// The first place whose value is above `bound`, or the number of places
/// where none is. The values have to rise; the search is otherwise lost.
///
/// Every place before it is at or below the bound, and every place from it
/// on is above.
pub fn first_above(values : FixedArray[Int64], bound : Int64) -> Int where {
  proof_require: rising(values),
  proof_ensure: result => first_above_ok(values, bound, result),
} {
  for lo = 0, hi = values.length(); lo < hi; {
    let mid = lo + (hi - lo) / 2
    if values[mid] <= bound {
      continue lo + 1, hi
    } else {
      continue lo, mid
    }
  } nobreak {
    lo
  } where {
    proof_invariant: 0 <= lo,
    proof_invariant: lo <= hi,
    proof_invariant: hi <= values.length(),
    proof_invariant: ∀ j : Int, (0 <= j) && (j < lo) → values[j] <= bound,
    proof_invariant: ∀ j : Int, (hi <= j) && (j < values.length()) → bound < values[j],
  }
}

///|
/// At every place, the largest of `from` and of the values up to it.
///
/// The result never falls behind itself, hides none of the values, and is
/// at every place exactly the largest so far: at least each of them and at
/// most anything that is.
pub fn running_max(
  values : FixedArray[Int64],
  from : Int64,
) -> FixedArray[Int64] where {
  proof_ensure: result => running_max_ok(values, from, result),
} {
  let out = FixedArray::make(values.length(), from)
  for i = 0, top = from; i < values.length(); {
    let next = if values[i] > top { values[i] } else { top }
    out[i] = next
    continue i + 1, next
  } nobreak {
    out
  } where {
    proof_invariant: 0 <= i,
    proof_invariant: i <= values.length(),
    proof_invariant: values.length() == out.length(),
    proof_invariant: rising_upto(out, i),
    proof_invariant: from <= top,
    proof_invariant: ∀ k : Int, (0 <= k) && (k < i) → values[k] <= top,
    proof_invariant: ∀ p : Int, ((0 <= p) && (p < i)) →
      largest_upto(values, from, p, out[p]),
    proof_invariant: ∀ b : Int64,
      ((from <= b) && (∀ k : Int, ((0 <= k) && (k < i)) → values[k] <= b)) →
        top <= b,
  }
}

///|
/// The first place from which some value is above `bound`: where a search
/// for a range that starts at `bound` may begin at, since nothing before
/// it is above the bound. It starts no later than it has to: up to it,
/// some value or `from` is above.
pub fn first_high(
  values : FixedArray[Int64],
  from : Int64,
  bound : Int64,
) -> Int where {
  proof_ensure: result => first_high_ok(values, from, bound, result),
} {
  first_above(running_max(values, from), bound)
}

///|
/// The last frame a count can name.
pub let last : Int64 = 9007199254740991L

///|
/// Two counts added where the sum can still be named; none where it
/// cannot, which is a negative count or a sum past the last frame.
pub fn summed(a : Int64, b : Int64) -> Int64? where {
  proof_ensure: result => summed_ok(a, b, result),
} {
  if a < 0L || b < 0L || a > 9007199254740991L - b {
    None
  } else {
    Some(a + b)
  }
}

///|
/// A row of lengths laid out: where each one stops, and how many were laid
/// before one did not fit.
pub struct Row {
  stops : FixedArray[Int64]
  upto : Int
}

///|
/// Where each of a row of lengths stops, laid end to end from the first
/// frame. A length that does not fit after the last one laid stops the
/// row there: the stops made are kept, and `upto` says how many.
pub fn laid_out(lengths : FixedArray[Int64]) -> Row where {
  proof_ensure: result => row_ok(lengths, result),
} {
  let stops = FixedArray::make(lengths.length(), 0L)
  let n = lengths.length()
  for i = 0, cursor = 0L, bad = n; i < n; {
    // Past the place the row stopped, nothing more is laid.
    if bad < n {
      continue i + 1, cursor, bad
    }
    match summed(cursor, lengths[i]) {
      Some(stop) => {
        stops[i] = stop
        continue i + 1, stop, bad
      }
      None => continue i + 1, cursor, i
    }
  } nobreak {
    { stops, upto: bad }
  } where {
    proof_invariant: 0 <= i,
    proof_invariant: i <= n,
    proof_invariant: 0L <= cursor,
    proof_invariant: cursor <= 9007199254740991L,
    proof_invariant: within(bad, n),
    proof_invariant: stopped_place_is_behind(bad, i, n),
    proof_invariant: not_stopped_or_stopped_at(lengths, stops, bad, n),
    proof_invariant: whole_goes_end_to_end(lengths, stops, i, bad, n),
    proof_invariant: whole_starts_with_own_length(lengths, stops, i, bad, n),
    proof_invariant: whole_is_in_frames(stops, i, bad, n),
    proof_invariant: whole_cursor_follows(stops, i, cursor, bad, n),
    proof_invariant: whole_starts_from_zero(i, cursor, bad, n),
    proof_invariant: part_goes_end_to_end(lengths, stops, bad, n),
    proof_invariant: part_starts_with_own_length(lengths, stops, bad, n),
    proof_invariant: part_is_in_frames(stops, bad, n),
    proof_invariant: stops.length() == n,
  }
}
