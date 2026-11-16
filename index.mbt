///|
priv struct SourceGroup {
  shots : Array[LocatedShot]
  max_stop : Array[Int64]
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
  let pending : Map[String, Array[LocatedShot]] = {}
  for shot in timeline.shots {
    if shot.media is Some(key) {
      match pending.get(key) {
        Some(shots) => shots.push(shot)
        None => pending[key] = [shot]
      }
    }
  }
  let index : Map[String, SourceGroup] = {}
  for key, shots in pending {
    shots.sort_by((a, b) => {
      let order = source_span(a).start.compare(source_span(b).start)
      if order == 0 {
        a.clip.compare(b.clip)
      } else {
        order
      }
    })
    let max_stop = []
    let mut maximum = 0L
    for shot in shots {
      let stop = source_span(shot).stop
      if stop > maximum {
        maximum = stop
      }
      max_stop.push(maximum)
    }
    index[key] = { shots, max_stop, }
  }
  index
}

///|
fn SourceGroup::overlapping(
  self : SourceGroup,
  target : Span,
  budget : Ref[Int32],
) -> Array[LocatedShot] raise ReconformError {
  let mut lo = 0
  let mut hi = self.shots.length()
  while lo < hi {
    let mid = lo + (hi - lo) / 2
    if self.max_stop[mid] <= target.start {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
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
