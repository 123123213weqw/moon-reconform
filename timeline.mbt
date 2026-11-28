///|
priv struct LocatedShot {
  clip : Int32
  timeline : Span
  media : String?
  source : Span?
  /// Set when the child holds no footage: why it holds none.
  why : Unplaceable?
}

///|
pub struct Timeline {
  priv shots : Array[LocatedShot]
  /// Where each shot stops on the track, as the proved kernel laid them
  /// out end to end. Every shot holds at least one frame, so these only
  /// rise, which is what the search is made over.
  priv stops : FixedArray[Int64]
  priv length_frames : Int64
}

///|
pub fn Timeline::from_shots(
  shots : Array[Shot],
) -> Timeline raise ReconformError {
  if shots.length() > 20000 {
    raise Limit("too many shots; limit is 20000")
  }
  let lengths : Array[Int64] = []
  let parts : Array[(String?, Span?, Unplaceable?)] = []
  let mut cursor = 0L
  for shot in shots {
    let (media, source, why, length) = match shot {
      Clip(id, source) => {
        if id.length() == 0 {
          raise Invalid("clip media key is empty")
        }
        source.checked("source span")
        (Some(id), Some(source), None, source.length())
      }
      Gap(n) => {
        if n <= 0L {
          raise Invalid("gap must have positive duration")
        }
        (None, None, None, n)
      }
      Unplaceable(reason, n) => {
        if n <= 0L {
          raise Invalid(
            "a clip without footage, a transition or a nested sequence must have positive duration",
          )
        }
        (None, None, Some(reason), n)
      }
    }
    // Added here, shot by shot, so that a cut that runs past the last
    // frame is refused where it runs past it.
    cursor = add_frames(cursor, length)
    lengths.push(length)
    parts.push((media, source, why))
  }
  // Where each shot stops, laid end to end by the proved kernel. The row
  // is whole: every length was added above, with the same sum.
  let row = @spans.laid_out(FixedArray::makei(lengths.length(), i => lengths[i]))
  if row.upto < lengths.length() {
    raise Limit("timeline exceeds exact frame range")
  }
  let located : Array[LocatedShot] = Array::makei(
    lengths.length(),
    i => {
      clip: i,
      timeline: {
        start: if i == 0 { 0L } else { row.stops[i - 1] },
        stop: row.stops[i],
      },
      media: parts[i].0,
      source: parts[i].1,
      why: parts[i].2,
    },
  )
  { shots: located, stops: row.stops, length_frames: cursor }
}

///|
pub fn Timeline::duration(self : Timeline) -> Int64 where {
  proof_ensure: result => result == self.length_frames,
} {
  self.length_frames
}

///|
pub fn Timeline::shot_count(self : Timeline) -> Int32 {
  self.shots.length()
}

///|
fn Timeline::first_shot(self : Timeline, start : Int64) -> Int {
  @spans.first_above(self.stops, start)
}

///|
fn intersection(a : Span, b : Span) -> Span? where {
  proof_require: holds_a_frame(a),
  proof_require: holds_a_frame(b),
  proof_ensure: result => intersection_ok(a, b, result),
} {
  match @spans.intersection(a.start, a.stop, b.start, b.stop) {
    Some((start, stop)) => Some({ start, stop, })
    None => None
  }
}
