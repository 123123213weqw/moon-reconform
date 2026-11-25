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
  /// Where each shot stops on the track. Every shot holds at least one
  /// frame, so these only rise, which is what the search is made over.
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
  let located = []
  let mut cursor = 0L
  for i, shot in shots {
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
    let stop = add_frames(cursor, length)
    located.push({ clip: i, timeline: { start: cursor, stop, }, media, source, why, })
    cursor = stop
  }
  {
    shots: located,
    stops: FixedArray::makei(located.length(), i => located[i].timeline.stop),
    length_frames: cursor,
  }
}

///|
pub fn Timeline::duration(self : Timeline) -> Int64 {
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
fn intersection(a : Span, b : Span) -> Span? {
  let start = if a.start > b.start { a.start } else { b.start }
  let stop = if a.stop < b.stop { a.stop } else { b.stop }
  if start < stop {
    Some({ start, stop, })
  } else {
    None
  }
}
