///|
pub(all) struct Request {
  fps : Int32
  old_track : Int32
  new_track : Int32
  notes : Array[Note]
  selections : Array[Selection]
  /// Read the old track's exported markers as annotations too.
  from_markers : Bool
}

///|
fn integer_field(
  fields : Map[String, Json],
  key : String,
  context : String,
) -> Int64 raise ReconformError {
  exact_integer(required(fields, key, context), context + "." + key)
}

///|
fn index_field(
  fields : Map[String, Json],
  key : String,
  context : String,
) -> Int32 raise ReconformError {
  let index = integer_field(fields, key, context)
  if index > 2147483647L {
    raise Invalid(context + "." + key + ": exceeds index range")
  }
  index.to_int()
}

///|
/// The request is the reviewer's own input, so a misspelled key must fail
/// instead of silently narrowing what the tool reads. OTIO documents keep
/// their unknown fields; only the request is held to this rule.
fn fields_only(
  fields : Map[String, Json],
  allowed : Array[String],
  context : String,
) -> Unit raise ReconformError {
  for key, _ in fields {
    if !allowed.contains(key) {
      raise Invalid(context + ": unknown field " + key)
    }
  }
}

///|
pub fn read_request(value : Json) -> Request raise ReconformError {
  let fields = object(value, "request")
  fields_only(
    fields,
    ["fps", "old_track", "new_track", "notes", "selections", "from_markers"],
    "request",
  )
  let fps = index_field(fields, "fps", "request")
  let old_track = index_field(fields, "old_track", "request")
  let new_track = index_field(fields, "new_track", "request")
  let from_markers = match fields.get("from_markers") {
    None => false
    Some(True) => true
    Some(False) => false
    Some(_) => raise Invalid("request.from_markers: expected a boolean")
  }
  let input = array(required(fields, "notes", "request"), "request.notes")
  if input.length() > 10000 {
    raise Limit("too many annotations; limit is 10000")
  }
  let notes = []
  for value in input {
    let note = object(value, "annotation")
    let id = field_string(note, "id", "annotation")
    fields_only(
      note,
      ["id", "text", "start", "stop", "media", "source"],
      "annotation " + id,
    )
    let text = field_string(note, "text", "annotation")
    // An annotation is anchored either to the old track, by start and
    // stop, or to source media, by media and source. The two never mix.
    let (range, media) = match note.get("media") {
      None => {
        if note.contains("source") {
          raise Invalid("annotation " + id + ": source requires media")
        }
        let start = integer_field(note, "start", id)
        let stop = match note.get("stop") {
          Some(value) => exact_integer(value, id + ".stop")
          None => add_frames(start, 1L)
        }
        let range = { start, stop, }
        (range, None)
      }
      Some(value) => {
        if note.contains("start") || note.contains("stop") {
          raise Invalid(
            "annotation " +
            id +
            ": media and source cannot combine with start and stop",
          )
        }
        let key = string(value, id + ".media")
        if key.length() == 0 {
          raise Invalid("annotation " + id + ": media is empty")
        }
        let context = id + ".source"
        let source = object(required(note, "source", id), context)
        fields_only(source, ["start", "stop"], context)
        let start = integer_field(source, "start", context)
        let stop = integer_field(source, "stop", context)
        let range = { start, stop, }
        (range, Some(key))
      }
    }
    notes.push({ id, text, range, media, origin: None, })
  }
  let selections = []
  if fields.get("selections") is Some(value) {
    let input = array(value, "request.selections")
    if input.length() > 100000 {
      raise Limit("too many manual selections")
    }
    for value in input {
      let selection = object(value, "selection")
      fields_only(selection, ["note_id", "piece", "clip"], "selection")
      selections.push({
        note_id: field_string(selection, "note_id", "selection"),
        piece: index_field(selection, "piece", "selection"),
        clip: index_field(selection, "clip", "selection"),
      })
    }
  }
  { fps, old_track, new_track, notes, selections, from_markers, }
}

///|
fn frame_json(frame : Int64) -> Json {
  Json::number(frame.to_double(), repr=frame.to_string())
}

///|
fn span_json(span : Span) -> Json {
  Json::object({
    "start": frame_json(span.start),
    "stop": frame_json(span.stop),
  })
}

///|
fn placement_json(p : Placement) -> Json {
  Json::object({ "clip": Json(p.clip), "range": span_json(p.range) })
}

///|
fn piece_json(piece : Piece) -> Json {
  let status = match piece.kind {
    Unique => "unique"
    Ambiguous => "ambiguous"
    Deleted => "deleted"
    GapPiece => "gap"
    OfflinePiece => "offline"
    TransitionPiece => "transition"
    NestedPiece => "nested"
  }
  Json::object({
    "old": match piece.old {
      Some(span) => span_json(span)
      None => Json::null()
    },
    "media": match piece.media {
      Some(key) => Json(key)
      None => Json::null()
    },
    "source": match piece.source {
      Some(span) => span_json(span)
      None => Json::null()
    },
    "status": Json(status),
    "candidates": Json::array(piece.candidates.map(placement_json)),
  })
}

///|
/// The marker an annotation was read back from, when it was.
fn origin_json(origin : (String, Int32)?) -> Json {
  match origin {
    Some((note_id, piece)) =>
      Json::object({ "note_id": Json(note_id), "piece": Json(piece) })
    None => Json::null()
  }
}

///|
fn carry_json(note : Note) -> Json {
  guard note.media is Some(key) else {
    abort("carried annotations are anchored to source media")
  }
  Json::object({
    "id": Json(note.id),
    "text": Json(note.text),
    "media": Json(key),
    "source": span_json(note.range),
  })
}

///|
/// The report names each annotation with its anchor, so `range` reads as
/// old-track frames when `media` is null and as source frames otherwise,
/// and with the marker it was read back from when `origin` is set. `carry`
/// restates every held annotation for the next request.
pub fn report_json(
  before : Timeline,
  after : Timeline,
  reports : Array[NoteReport],
  resolution : Resolution,
) -> Json {
  Json::object({
    "ok": Json(true),
    "old_duration": frame_json(before.duration()),
    "new_duration": frame_json(after.duration()),
    "notes": Json::array(
      reports.map(report => {
        Json::object({
          "id": Json(report.note.id),
          "text": Json(report.note.text),
          "media": match report.note.media {
            Some(key) => Json(key)
            None => Json::null()
          },
          "range": span_json(report.note.range),
          "origin": origin_json(report.note.origin),
          "pieces": Json::array(report.pieces.map(piece_json)),
        })
      }),
    ),
    "held": Json(resolution.held),
    "transfers": Json::array(
      resolution.transfers.map(transfer => {
        Json::object({
          "note_id": Json(transfer.note_id),
          "piece": Json(transfer.piece),
          "placement": placement_json(transfer.placement),
          "origin": origin_json(transfer.origin),
        })
      }),
    ),
    "carry": Json::array(carried(reports, resolution).map(carry_json)),
  })
}
