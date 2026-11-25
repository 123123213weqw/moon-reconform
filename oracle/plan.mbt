///|
/// A piece that holds no footage: black, or a child that holds none.
fn bare(old : @tool.Span, why : String?) -> @tool.Piece {
  let kind = match why {
    Some("offline") => @tool.OfflinePiece
    Some("transition") => @tool.TransitionPiece
    Some("nested") => @tool.NestedPiece
    _ => @tool.GapPiece
  }
  @tool.Piece::{
    old: Some(old),
    media: None,
    source: None,
    candidates: [],
    kind,
  }
}

///|
/// One placement of some footage, and the part of a run of it that the
/// placement shows.
priv struct Hit {
  child : Int32
  from : Int64
  first : Int64
  lo : Int64
  hi : Int64
}

///|
fn footage(
  old : @tool.Span?,
  media : String,
  source : @tool.Span,
  fresh : Array[Slot],
) -> Array[@tool.Piece] {
  // Every placement of this footage that shows any of the run.
  let hits = []
  for slot in fresh {
    if slot.media == Some(media) && slot.first is Some(first) {
      let lo = if source.start > first { source.start } else { first }
      let last = first + slot.stop - slot.from
      let hi = if source.stop < last { source.stop } else { last }
      if lo < hi {
        hits.push({ child: slot.child, from: slot.from, first, lo, hi })
      }
    }
  }
  // Cut the run at every frame where the set of placements showing it changes.
  let cuts = [source.start, source.stop]
  for hit in hits {
    cuts.push(hit.lo)
    cuts.push(hit.hi)
  }
  cuts.sort()
  let shift = match old {
    Some(anchor) => anchor.start - source.start
    None => 0L
  }
  let pieces = []
  let mut i = 0
  while i + 1 < cuts.length() {
    if cuts[i] == cuts[i + 1] {
      i += 1
      continue
    }
    let (x, y) = (cuts[i], cuts[i + 1])
    let candidates = []
    for hit in hits {
      if hit.lo <= x && y <= hit.hi {
        candidates.push(
          @tool.Placement::{
            clip: hit.child,
            range: {
              start: hit.from + x - hit.first,
              stop: hit.from + y - hit.first,
            },
          },
        )
      }
    }
    candidates.sort_by((a, b) => a.clip.compare(b.clip))
    let kind = match candidates.length() {
      0 => @tool.Deleted
      1 => @tool.Unique
      _ => @tool.Ambiguous
    }
    pieces.push(
      @tool.Piece::{
        old: match old {
          Some(_) => Some({ start: x + shift, stop: y + shift })
          None => None
        },
        media: Some(media),
        source: Some({ start: x, stop: y }),
        candidates,
        kind,
      },
    )
    i += 1
  }
  pieces
}

///|
/// The pieces an annotation must produce, by plain interval arithmetic and
/// nothing else: each run of footage is intersected with every placement of
/// that footage in the new cut, and cut wherever the covering set changes.
/// No endpoint sweep, no index and no budget; the tool has all three.
pub fn planned(
  old : Array[Slot],
  fresh : Array[Slot],
  note : @tool.Note,
) -> Array[@tool.Piece] {
  match note.media {
    None => {
      let pieces = []
      for slot in old {
        let lo = if note.range.start > slot.from { note.range.start } else { slot.from }
        let hi = if note.range.stop < slot.stop { note.range.stop } else { slot.stop }
        if lo < hi {
          match slot.first {
            None => pieces.push(bare({ start: lo, stop: hi }, slot.why))
            Some(first) =>
              for piece in footage(
                Some({ start: lo, stop: hi }),
                slot.media.unwrap(),
                { start: first + lo - slot.from, stop: first + hi - slot.from },
                fresh,
              ) {
                pieces.push(piece)
              }
          }
        }
      }
      pieces
    }
    Some(media) => footage(None, media, note.range, fresh)
  }
}

///|
fn status(kind : @tool.PieceKind) -> String {
  match kind {
    Unique => "unique"
    Ambiguous => "ambiguous"
    Deleted => "deleted"
    GapPiece => "gap"
    OfflinePiece => "offline"
    TransitionPiece => "transition"
    NestedPiece => "nested"
  }
}

///|
fn kind_of(why : String?) -> @tool.PieceKind {
  match why {
    Some("offline") => @tool.OfflinePiece
    Some("transition") => @tool.TransitionPiece
    Some("nested") => @tool.NestedPiece
    _ => @tool.GapPiece
  }
}

///|
/// Ground truth by enumeration. Every frame of every piece is looked up
/// where it lies, and the piece has to say exactly what was found there.
/// `laid` is the old track where the pieces were made, read by the oracle.
pub fn walk(
  laid : Array[Slot],
  fresh : Array[Slot],
  note : @tool.Note,
  pieces : Array[@tool.Piece],
) -> Unit raise {
  let old = frames(laid)
  let destinations : Map[(String, Int64), Array[(Int32, Int64)]] = Map([])
  for at, (child, media, source) in frames(fresh) {
    match (media, source) {
      (Some(key), Some(frame)) =>
        match destinations.get((key, frame)) {
          Some(places) => places.push((child, at.to_int64()))
          None => destinations[(key, frame)] = [(child, at.to_int64())]
        }
      _ => ()
    }
  }
  for piece in pieces {
    let (at, end) = match (note.media, piece.old, piece.source) {
      (None, Some(span), _) => (span.start, span.stop)
      (Some(_), None, Some(span)) => (span.start, span.stop)
      _ => fail("oracle: a piece claims both anchors or neither: " + status(piece.kind))
    }
    let children : Map[Int32, Unit] = Map([])
    for frame = at; frame < end; frame = frame + 1L {
      let (child, media, source) = match note.media {
        None => old[frame.to_int()]
        Some(key) => (-1, Some(key), Some(frame))
      }
      children[child] = ()
      if media is None {
        if piece.kind != kind_of(laid[child.to_int()].why) || piece.source is Some(_) {
          fail("oracle: frame \{frame} has no footage and the piece says \{status(piece.kind)}")
        }
      } else {
        let shown = piece.source.unwrap()
        if shown.start + frame - at != source.unwrap() ||
          shown.stop - shown.start != end - at {
          fail("oracle: the piece's footage is not the frame's footage at \{frame}")
        }
      }
      if piece.media != media {
        fail("oracle: the piece names other footage than frame \{frame}")
      }
      let targets = match (media, source) {
        (Some(key), Some(frame)) =>
          match destinations.get((key, frame)) {
            Some(places) => places
            None => []
          }
        _ => []
      }
      if media is Some(_) {
        let expected = match targets.length() {
          0 => @tool.Deleted
          1 => @tool.Unique
          _ => @tool.Ambiguous
        }
        if piece.kind != expected {
          fail("oracle: frame \{frame} has \{targets.length()} places and the piece says \{status(piece.kind)}")
        }
      }
      let seen = piece.candidates.map(c => (c.clip, c.range.start + frame - at))
      if seen != targets {
        fail("oracle: the candidates are not the places of frame \{frame}")
      }
    }
    if note.media is None && children.length() != 1 {
      fail("oracle: the report crossed an old edit boundary")
    }
    for candidate in piece.candidates {
      if candidate.range.stop - candidate.range.start != end - at {
        fail("oracle: a candidate is not as long as its piece")
      }
    }
  }
}

///|
/// What follows from the pieces by the tool's stated rules: an annotation
/// transfers whole when every one of its pieces is placed, by its only
/// candidate or by the choice made for it; otherwise it is held, and leaves
/// one annotation per piece that has footage, named after the piece.
pub fn expected(
  reports : Array[@tool.NoteReport],
  selections : Array[@tool.Selection],
) -> (@tool.Resolution, Array[@tool.Note]) {
  let transfers = []
  let held = []
  let carry = []
  for report in reports {
    let note = report.note
    let proposed = []
    for i, piece in report.pieces {
      let picked = selections
        .iter()
        .find_first(s => s.note_id == note.id && s.piece == i)
      let chosen = match picked {
        Some(selection) =>
          piece.candidates
            .iter()
            .find_first(c => c.clip == selection.clip)
        None =>
          if piece.candidates.length() == 1 { Some(piece.candidates[0]) } else { None }
      }
      if chosen is Some(placement) {
        proposed.push(
          @tool.Transfer::{
            note_id: note.id,
            text: note.text,
            piece: i,
            placement,
            origin: note.origin,
          },
        )
      }
    }
    if proposed.length() == report.pieces.length() {
      for transfer in proposed {
        transfers.push(transfer)
      }
    } else {
      held.push(note.id)
      for i, piece in report.pieces {
        if piece.media is Some(key) && piece.source is Some(source) {
          carry.push(
            @tool.Note::{
              id: note.id + "#" + i.to_string(),
              text: note.text,
              range: source,
              media: Some(key),
              origin: None,
            },
          )
        }
      }
    }
  }
  (@tool.Resolution::{ transfers, held }, carry)
}

///|
fn placement_at(placement : @tool.Placement) -> Json {
  Json::object({
    "clip": Json(placement.clip),
    "range": span(placement.range.start, placement.range.stop),
  })
}

///|
fn origin_at(origin : (String, Int32)?) -> Json {
  match origin {
    Some((note_id, piece)) =>
      Json::object({ "note_id": Json(note_id), "piece": Json(piece) })
    None => Json::null()
  }
}

///|
fn piece_at(piece : @tool.Piece) -> Json {
  Json::object({
    "old": match piece.old {
      Some(range) => span(range.start, range.stop)
      None => Json::null()
    },
    "media": match piece.media {
      Some(key) => Json(key)
      None => Json::null()
    },
    "source": match piece.source {
      Some(range) => span(range.start, range.stop)
      None => Json::null()
    },
    "status": Json(status(piece.kind)),
    "candidates": Json::array(piece.candidates.map(placement_at)),
  })
}

///|
/// The report the tool must print for these pieces and this outcome.
pub fn report_of(
  old_length : Int64,
  new_length : Int64,
  reports : Array[@tool.NoteReport],
  resolution : @tool.Resolution,
  carry : Array[@tool.Note],
) -> Json {
  Json::object({
    "ok": Json(true),
    "old_duration": frame(old_length),
    "new_duration": frame(new_length),
    "notes": Json::array(
      reports.map(report => {
        Json::object({
          "id": Json(report.note.id),
          "text": Json(report.note.text),
          "media": match report.note.media {
            Some(key) => Json(key)
            None => Json::null()
          },
          "range": span(report.note.range.start, report.note.range.stop),
          "origin": origin_at(report.note.origin),
          "pieces": Json::array(report.pieces.map(piece_at)),
        })
      }),
    ),
    "held": Json::array(resolution.held.map(id => Json(id))),
    "transfers": Json::array(
      resolution.transfers.map(transfer => {
        Json::object({
          "note_id": Json(transfer.note_id),
          "piece": Json(transfer.piece),
          "placement": placement_at(transfer.placement),
          "origin": origin_at(transfer.origin),
        })
      }),
    ),
    "carry": Json::array(
      carry.map(note => {
        Json::object({
          "id": Json(note.id),
          "text": Json(note.text),
          "media": Json(note.media.unwrap()),
          "source": span(note.range.start, note.range.stop),
        })
      }),
    ),
  })
}

///|
/// The marker an annotation was exported for, when the marker is one of
/// this tool's. The editor's own markers are passed over unread.
pub fn origin_key(marker : Json) -> (String, Int32)? {
  guard marker is Object(fields) &&
    fields.get("metadata") is Some(Object(data)) &&
    data.get("moon_reconform") is Some(Object(origin)) &&
    origin.get("note_id") is Some(String(note_id)) &&
    origin.get("piece") is Some(Number(piece, ..)) &&
    piece >= 0.0 &&
    piece <= 2147483647.0 &&
    piece == piece.floor() else {
    return None
  }
  Some((note_id, piece.to_int()))
}

///|
/// The marker the tool must write for a transfer, placed where the oracle
/// reads the placement to lie.
fn marker_for(transfer : @tool.Transfer, fresh : Array[Slot]) -> Json {
  let placement = transfer.placement
  let slot = fresh[placement.clip.to_int()]
  let first = slot.first.unwrap() + placement.range.start - slot.from
  let length = placement.range.stop - placement.range.start
  Json::object({
    "OTIO_SCHEMA": Json("Marker.2"),
    "name": Json(transfer.text),
    "comment": Json(""),
    "color": Json("GREEN"),
    "marked_range": duration(placement.range.start, length),
    "metadata": Json::object({
      "moon_reconform": Json::object({
        "note_id": Json(transfer.note_id),
        "piece": Json(transfer.piece),
        "target_child": Json(placement.clip),
        "media": Json(slot.media.unwrap()),
        "source": span(first, first + length),
      }),
    }),
  })
}

///|
/// The document the tool must write: the new cut with every marker kept but
/// the stale copies of the annotations that transferred, and one fresh
/// marker per transfer after them.
pub fn exported(
  fresh : Json,
  new_track : Int32,
  resolution : @tool.Resolution,
  laid : Array[Slot],
) -> Json {
  let superseded : Map[(String, Int32), Unit] = Map([])
  for transfer in resolution.transfers {
    match transfer.origin {
      Some(key) => superseded[key] = ()
      None => ()
    }
  }
  let markers = []
  for marker in markers_on(track_of_document(fresh, new_track)) {
    match origin_key(marker) {
      Some(key) => if superseded.contains(key) { continue }
      None => ()
    }
    markers.push(marker)
  }
  for transfer in resolution.transfers {
    markers.push(marker_for(transfer, laid))
  }
  with_markers_on(fresh, new_track, markers)
}

///|
/// What `from_markers` must add: every marker on the track that carries
/// this tool's record, restated as the footage the record names, in the
/// order the track lists them.
pub fn read_back(document : Json, index : Int32) -> Array[@tool.Note] {
  let notes = []
  for marker in markers_on(track_of_document(document, index)) {
    match origin_key(marker) {
      None => ()
      Some((note_id, piece)) => {
        let origin = entry(
          entry(entry(marker, "metadata"), "moon_reconform"),
          "source",
        )
        notes.push(
          @tool.Note::{
            id: note_id + "#" + piece.to_string(),
            text: text(entry(marker, "name")),
            range: {
              start: whole(entry(origin, "start")),
              stop: whole(entry(origin, "stop")),
            },
            media: Some(
              text(entry(entry(entry(marker, "metadata"), "moon_reconform"), "media")),
            ),
            origin: Some((note_id, piece)),
          },
        )
      }
    }
  }
  notes
}
