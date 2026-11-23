///|
fn time_json(value : Int64, fps : Int32) -> Json {
  Json::object({
    "OTIO_SCHEMA": Json("RationalTime.1"),
    "value": frame_json(value),
    "rate": Json(fps),
  })
}

///|
/// Besides the annotation it carries, the marker records the footage it was
/// placed on. `from_markers` reads that anchor rather than the timecode, so
/// the annotation stays with its footage however an editor's application
/// later moves the marker.
fn marker_json(
  transfer : Transfer,
  media : String,
  source : Span,
  fps : Int32,
) -> Json {
  let span = transfer.placement.range
  Json::object({
    "OTIO_SCHEMA": Json("Marker.2"),
    "name": Json(transfer.text),
    "comment": Json(""),
    "color": Json("GREEN"),
    "marked_range": Json::object({
      "OTIO_SCHEMA": Json("TimeRange.1"),
      "start_time": time_json(span.start, fps),
      "duration": time_json(span.length(), fps),
    }),
    "metadata": Json::object({
      "moon_reconform": Json::object({
        "note_id": Json(transfer.note_id),
        "piece": Json(transfer.piece),
        "target_child": Json(transfer.placement.clip),
        "media": Json(media),
        "source": span_json(source),
      }),
    }),
  })
}

///|
fn existing_annotation(marker : Json) -> (String, Int32)? {
  guard marker is Object(fields) &&
    fields.get("metadata") is Some(Object(metadata)) &&
    metadata.get("moon_reconform") is Some(Object(origin)) &&
    origin.get("note_id") is Some(String(id)) &&
    origin.get("piece") is Some(Number(n, ..)) &&
    n >= 0.0 &&
    n <= 2147483647.0 &&
    n == n.floor() else {
    return None
  }
  Some((id, n.to_int()))
}

///|
/// Append resolved markers to the new track. The input object is left
/// unchanged, and so is the whole document when nothing transfers.
///
/// An annotation read back from an earlier marker supersedes that marker
/// once it transfers: the copy an editor already conformed into the new
/// cut, by timecode rather than by footage, is dropped before the fresh
/// placement is appended. A held annotation supersedes nothing, so its
/// copy stays exactly where the editor put it.
pub fn with_markers(
  root : Json,
  track_index~ : Int32,
  fps~ : Int32,
  resolution : Resolution,
) -> Json raise ReconformError {
  let timeline = read_otio(root, track_index~, fps~)
  let track = otio_track(root, track_index).copy()
  if resolution.transfers.length() == 0 {
    return root
  }
  let superseded : Map[(String, Int32), Unit] = Map([])
  for transfer in resolution.transfers {
    if transfer.origin is Some(key) {
      superseded[key] = ()
    }
  }
  let markers = []
  match track.get("markers") {
    None => ()
    Some(value) =>
      for marker in array(value, "selected track.markers") {
        if existing_annotation(marker) is Some(key) && superseded.contains(key) {
          continue
        }
        markers.push(marker)
      }
  }
  let seen : Map[(String, Int32), Unit] = Map([])
  for marker in markers {
    if existing_annotation(marker) is Some(key) {
      seen[key] = ()
    }
  }
  for transfer in resolution.transfers {
    let key = (transfer.note_id, transfer.piece)
    if seen.contains(key) {
      raise Invalid("an exported marker already exists for " + transfer.note_id)
    }
    seen[key] = ()
    let context = "transfer " + transfer.note_id
    let placement = transfer.placement
    placement.range.checked(context)
    guard timeline.shots.get(placement.clip) is Some(shot) &&
      shot.media is Some(media) &&
      shot.source is Some(source) &&
      placement.range.start >= shot.timeline.start &&
      placement.range.stop <= shot.timeline.stop else {
      raise Invalid(context + ": placement is outside the intended clip")
    }
    // The anchor comes from the document being written, so it describes
    // the very clip the placement was just verified against.
    let offset = placement.range.start - shot.timeline.start
    let anchor = {
      start: source.start + offset,
      stop: source.start + offset + placement.range.length(),
    }
    markers.push(marker_json(transfer, media, anchor, fps))
  }
  track["markers"] = Json::array(markers)
  let b = object(root, "timeline").copy()
  let stack = object(required(b, "tracks", "timeline"), "tracks").copy()
  let tracks = array(required(stack, "children", "tracks"), "tracks.children").copy()
  tracks[track_index] = Json::object(track)
  stack["children"] = Json::array(tracks)
  b["tracks"] = Json::object(stack)
  Json::object(b)
}
