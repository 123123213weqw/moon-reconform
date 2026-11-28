///|
/// The exported markers on one track as annotations, in track order. Only
/// markers that carry a `moon_reconform` origin count; the others belong
/// to the editor or to another tool and are left alone.
///
/// A marker is read by the footage it records, never by the timecode it is
/// drawn at. An editor's application conforms markers by timecode, so a
/// marker can drift onto other footage between two rounds; its recorded
/// anchor cannot drift with it. That is also why a held annotation read
/// back here can travel on: it is anchored to source media like any other
/// carried annotation.
///
/// Each marker becomes an annotation named `<note_id>#<piece>`, so the
/// pieces of an earlier annotation stay distinct. `origin` remembers the
/// marker it came from, which is what lets a later export supersede the
/// copy an editor may already have conformed into the new cut.
pub fn read_notes_from_markers(
  root : Json,
  track_index~ : Int32,
  fps~ : Rate,
) -> Array[Note] raise ReconformError {
  check_rate(fps)
  let track = otio_track(root, track_index)
  let notes = []
  let seen : Map[(String, Int32), Int32] = Map([])
  let mut position = 0
  match track.get("markers") {
    None => ()
    Some(value) =>
      for marker in array(value, "selected track.markers") {
        let context = "selected track marker " + position.to_string()
        position += 1
        guard marker is Object(fields) else {
          raise Invalid(context + ": expected an object")
        }
        guard fields.get("metadata") is Some(Object(metadata)) &&
          metadata.get("moon_reconform") is Some(Object(origin)) else {
          continue
        }
        let schema = field_string(fields, "OTIO_SCHEMA", context)
        if schema != "Marker.1" && schema != "Marker.2" {
          raise Invalid(context + ": unsupported schema " + schema)
        }
        let note_id = field_string(origin, "note_id", context)
        if note_id.length() == 0 {
          raise Invalid(context + ": note_id is empty")
        }
        let piece = exact_integer(
          required(origin, "piece", context),
          context + ".piece",
        )
        if piece > 2147483647L {
          raise Invalid(context + ".piece: exceeds index range")
        }
        let key = (note_id, piece.to_int())
        if seen.get(key) is Some(first) {
          raise Invalid(
            context +
            ": repeats the marker for " +
            note_id +
            "#" +
            piece.to_string() +
            " at position " +
            first.to_string(),
          )
        }
        seen[key] = position - 1
        // Markers exported before 0.2.0 recorded no footage. Reading them
        // by position would trust a timecode, so they are refused by name.
        guard origin.get("media") is Some(media_value) else {
          raise Invalid(
            context +
            ": records no footage; export it again to record some",
          )
        }
        let media = string(media_value, context + ".media")
        if media.length() == 0 {
          raise Invalid(context + ": media is empty")
        }
        let source = object(
          required(origin, "source", context),
          context + ".source",
        )
        let range = {
          start: exact_integer(
            required(source, "start", context + ".source"),
            context + ".source.start",
          ),
          stop: exact_integer(
            required(source, "stop", context + ".source"),
            context + ".source.stop",
          ),
        }
        range.checked(context + ".source")
        notes.push({
          id: note_id + "#" + piece.to_string(),
          text: field_string(fields, "name", context),
          range,
          media: Some(media),
          origin: Some(key),
        })
      }
  }
  notes
}
