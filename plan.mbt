///|
priv struct Endpoint {
  frame : Int64
  entering : Bool
  shot : LocatedShot
}

///|
/// `old` is the piece's range on the old cut, or absent for an annotation
/// that was anchored to source media and never had one.
fn media_pieces(
  old : Span?,
  source : Span,
  key : String,
  matches : Array[LocatedShot],
  report_budget : Ref[Int32],
) -> Array[Piece] raise ReconformError {
  let endpoints : Array[Endpoint] = []
  for shot in matches {
    if intersection(source, source_span(shot)) is Some(overlap) {
      endpoints.push({ frame: overlap.start, entering: true, shot, })
      endpoints.push({ frame: overlap.stop, entering: false, shot, })
    }
  }
  endpoints.sort_by((a, b) => a.frame.compare(b.frame))
  let result = []
  let active : Map[Int32, LocatedShot] = Map([])
  let mut from = source.start
  let mut i = 0
  while from < source.stop {
    while i < endpoints.length() && endpoints[i].frame == from {
      let endpoint = endpoints[i]
      if endpoint.entering {
        active[endpoint.shot.clip] = endpoint.shot
      } else {
        active.remove(endpoint.shot.clip)
      }
      i += 1
    }
    let to = if i < endpoints.length() {
      endpoints[i].frame
    } else {
      source.stop
    }
    report_budget.val -= 1 + active.length()
    if report_budget.val < 0 {
      raise Limit("report piece and candidate budget exceeded")
    }
    let candidates = []
    for clip, shot in active {
      let start = shot.timeline.start + (from - source_span(shot).start)
      candidates.push({ clip, range: { start, stop: start + (to - from), }, })
    }
    candidates.sort_by((a, b) => a.clip.compare(b.clip))
    let kind = match candidates.length() {
      0 => Deleted
      1 => Unique
      _ => Ambiguous
    }
    let old_piece = match old {
      Some(anchor) =>
        Some({
          start: anchor.start + (from - source.start),
          stop: anchor.start + (to - source.start),
        })
      None => None
    }
    result.push({
      old: old_piece,
      media: Some(key),
      source: Some({ start: from, stop: to, }),
      candidates,
      kind,
    })
    from = to
  }
  result
}

///|
/// Partition every annotation in old timeline order. Repeated source frames
/// emit all new placements in ascending child-index order. An annotation
/// with `media` set is anchored to source frames and needs nothing from the
/// old cut, which is how a held annotation travels to the next round.
pub fn plan(
  before : Timeline,
  after : Timeline,
  notes : Array[Note],
) -> Array[NoteReport] raise ReconformError {
  if notes.length() > 10000 {
    raise Limit("too many annotations; limit is 10000")
  }
  let ids : Map[String, Unit] = Map([])
  let index = index_sources(after)
  let search_budget = Ref(1000000)
  let report_budget = Ref(100000)
  let reports = []
  for note in notes {
    if note.id.length() == 0 || ids.contains(note.id) {
      raise Invalid("annotation id is empty or repeated: " + note.id)
    }
    ids[note.id] = ()
    note.range.checked("annotation " + note.id)
    let pieces = []
    match note.media {
      Some(key) => {
        // An empty key matches no clip, so the annotation would be
        // reported deleted for a reason that is a typo rather than an edit.
        if key.length() == 0 {
          raise Invalid("annotation " + note.id + ": media key is empty")
        }
        let matches = match index.get(key) {
          Some(group) => group.overlapping(note.range, search_budget)
          None => []
        }
        for piece in media_pieces(None, note.range, key, matches, report_budget) {
          pieces.push(piece)
        }
      }
      None => {
        if note.range.stop > before.duration() {
          raise Invalid(
            "annotation " + note.id + " extends beyond the old timeline",
          )
        }
        let mut i = before.first_shot(note.range.start)
        while
          i < before.shots.length() &&
          before.shots[i].timeline.start < note.range.stop {
          let shot = before.shots[i]
          guard intersection(shot.timeline, note.range) is Some(old) else {
            i += 1
            continue
          }
          match shot.media {
            None => {
              report_budget.val -= 1
              if report_budget.val < 0 {
                raise Limit("report piece and candidate budget exceeded")
              }
              pieces.push({
                old: Some(old),
                media: None,
                source: None,
                candidates: [],
                kind: piece_kind(shot.why),
              })
            }
            Some(key) => {
              let start = source_span(shot).start +
                (old.start - shot.timeline.start)
              let source = { start, stop: start + old.length(), }
              let matches = match index.get(key) {
                Some(group) => group.overlapping(source, search_budget)
                None => []
              }
              for piece in media_pieces(
                Some(old),
                source,
                key,
                matches,
                report_budget,
              ) {
                pieces.push(piece)
              }
            }
          }
          i += 1
        }
      }
    }
    reports.push({ note, pieces, })
  }
  reports
}
