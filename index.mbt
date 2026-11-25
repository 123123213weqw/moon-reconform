///|
priv struct SourceGroup {
  shots : Array[LocatedShot]
  /// At every shot, the furthest any shot of this footage so far reaches
  /// into it. These only rise, so the place a search can begin at can be
  /// found by halves.
  reach : FixedArray[Int64]
}

///|
fn source_span(shot : LocatedShot) -> Span {
  match shot.source {
    Some(span) => span
    None => abort("source index invariant")
  }
}

///|
fn index_sources(timeline : Timeline) -> Map[String, SourceGroup] {
  let pending : Map[String, Array[LocatedShot]] = Map([])
  for shot in timeline.shots {
    if shot.media is Some(key) {
      match pending.get(key) {
        Some(shots) => shots.push(shot)
        None => pending[key] = [shot]
      }
    }
  }
  let index : Map[String, SourceGroup] = Map([])
  for key, shots in pending {
    shots.sort_by((a, b) => {
      let order = source_span(a).start.compare(source_span(b).start)
      if order == 0 {
        a.clip.compare(b.clip)
      } else {
        order
      }
    })
    let stops = FixedArray::makei(shots.length(), i => source_span(shots[i]).stop)
    index[key] = { shots, reach: @spans.running_max(stops, 0L) }
  }
  index
}

///|
fn SourceGroup::overlapping(
  self : SourceGroup,
  target : Span,
  budget : Ref[Int32],
) -> Array[LocatedShot] raise ReconformError {
  // No shot before this place reaches past the first frame of the range,
  // so none of them can show any of it.
  let lo = @spans.first_above(self.reach, target.start)
  let result = []
  for i = lo; i < self.shots.length(); i = i + 1 {
    let shot = self.shots[i]
    let span = source_span(shot)
    if span.start >= target.stop {
      break
    }
    budget.val -= 1
    if budget.val < 0 {
      raise Limit("candidate search budget exceeded")
    }
    if span.stop > target.start {
      result.push(shot)
    }
  }
  result
}
