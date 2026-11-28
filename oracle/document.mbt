///|
/// A member of a JSON object. The oracle reads documents it built itself or
/// got back from the tool, so a member that is missing is a mistake in the
/// oracle, not something to refuse.
pub fn entry(value : Json, key : String) -> Json {
  guard value is Object(fields) && fields.get(key) is Some(found) else {
    abort("oracle: no member " + key)
  }
  found
}

///|
pub fn items(value : Json) -> Array[Json] {
  guard value is Array(list) else { abort("oracle: not an array") }
  list
}

///|
pub fn text(value : Json) -> String {
  guard value is String(found) else { abort("oracle: not a string") }
  found
}

///|
/// A number the generator wrote, which is always a whole number of frames.
pub fn whole(value : Json) -> Int64 {
  guard value is Number(n, ..) else { abort("oracle: not a number") }
  n.to_int64()
}

///|
/// A frame count as the tool writes one, with every digit kept.
pub fn frame(value : Int64) -> Json {
  Json::number(value.to_double(), repr=value.to_string())
}

///|
pub fn span(start : Int64, stop : Int64) -> Json {
  Json::object({ "start": frame(start), "stop": frame(stop) })
}

///|
pub fn nothing() -> Json {
  Json::object(Map([]))
}

///|
fn instant(value : Int64, rate~ : @tool.Rate = @tool.Rate::whole(24)) -> Json {
  Json::object({
    "OTIO_SCHEMA": Json("RationalTime.1"),
    "value": frame(value),
    "rate": Json::number(rate.value, repr=rate.token),
  })
}

///|
/// An OpenTimelineIO time range: where it starts and how long it is.
pub fn duration(
  start : Int64,
  length : Int64,
  rate~ : @tool.Rate = @tool.Rate::whole(24),
) -> Json {
  Json::object({
    "OTIO_SCHEMA": Json("TimeRange.1"),
    "start_time": instant(start, rate~),
    "duration": instant(length, rate~),
  })
}

///|
/// One child of a generated track, as small numbers. `kind` picks what it
/// is: black, footage, a clip with no footage of its own, a transition or a
/// nested sequence. The others place it on a small grid, so that edges,
/// annotation edges and repeated footage keep landing on the same frame.
#derive(Eq, Debug)
pub(all) struct Child {
  kind : Int32
  start : Int32
  length : Int32
  media : Int32
  entering : Int32
}

///|
/// Footage the generated cuts use. The last is in no generated annotation,
/// so pieces of it can only ever be unique or repeated.
pub let media_keys : ReadOnlyArray[String] = [
  "file:///shoot/A.mov",
  "file:///shoot/B.mov",
  "file:///shoot/C.mov",
  "file:///shoot/D.mov",
]

///|
fn footage_clip(
  url : String,
  start : Int64,
  length : Int64,
  rate~ : @tool.Rate = @tool.Rate::whole(24),
) -> Json {
  Json::object({
    "OTIO_SCHEMA": Json("Clip.2"),
    "name": Json(url),
    "media_references": Json::object({
      "original": Json::object({
        "OTIO_SCHEMA": Json("ExternalReference.1"),
        "name": Json(""),
        "metadata": nothing(),
        "target_url": Json(url),
        "available_range": duration(0L, 4000L, rate~),
      }),
    }),
    "active_media_reference_key": Json("original"),
    "metadata": nothing(),
    "source_range": duration(start, length, rate~),
    "markers": Json::array([]),
    "effects": Json::array([]),
    "enabled": Json(true),
  })
}

///|
/// A clip whose media has no location of its own: missing, made by the
/// application, or not named at all.
fn offline_clip(
  start : Int64,
  length : Int64,
  which : Int32,
  rate~ : @tool.Rate = @tool.Rate::whole(24),
) -> Json {
  let reference = match which & 3 {
    0 => Json::null()
    1 =>
      Json::object({
        "OTIO_SCHEMA": Json("MissingReference.1"),
        "name": Json(""),
        "metadata": nothing(),
      })
    2 =>
      Json::object({
        "OTIO_SCHEMA": Json("GeneratorReference.1"),
        "name": Json(""),
        "metadata": nothing(),
        "parameters": nothing(),
      })
    _ =>
      Json::object({
        "OTIO_SCHEMA": Json("ImageSequenceReference.1"),
        "name": Json(""),
        "metadata": nothing(),
        "base_url": Json("file:///shoot/frame_"),
      })
  }
  Json::object({
    "OTIO_SCHEMA": Json("Clip.1"),
    "name": Json("no footage of its own"),
    "media_reference": reference,
    "metadata": nothing(),
    "source_range": duration(start, length, rate~),
    "markers": Json::array([]),
    "effects": Json::array([]),
    "enabled": Json(true),
  })
}

///|
/// The document for one generated child, or None when its length came out
/// zero, in which case it is not on the track at all.
pub fn child_of(
  child : Child,
  far~ : Int64 = 0L,
  rate~ : @tool.Rate = @tool.Rate::whole(24),
) -> Json? {
  // Between one and seven frames; a length that comes out zero leaves the
  // child out, which is also what a shrunk case asks for. `far` moves the
  // footage itself far from its first frame.
  let length = (child.length & 7).to_int64()
  if length == 0L {
    return None
  }
  let start = (child.start & 31).to_int64() + far
  match child.kind & 7 {
    0 =>
      Some(
        Json::object({
          "OTIO_SCHEMA": Json("Gap.1"),
          "name": Json(""),
          "metadata": nothing(),
          "source_range": duration(0L, length, rate~),
          "markers": Json::array([]),
          "effects": Json::array([]),
          "enabled": Json(true),
        }),
      )
    2 => Some(offline_clip(start, length, child.media, rate~))
    3 => {
      // A transition lasts its two offsets; here they add up to its length.
      let entering = (child.entering.to_int64() & 7L) % length
      Some(
        Json::object({
          "OTIO_SCHEMA": Json("Transition.1"),
          "name": Json("dissolve"),
          "metadata": nothing(),
          "transition_type": Json("SMPTE_Dissolve"),
          "parameters": nothing(),
          "in_offset": instant(entering, rate~),
          "out_offset": instant(length - entering, rate~),
        }),
      )
    }
    4 =>
      Some(
        Json::object({
          "OTIO_SCHEMA": Json("Stack.1"),
          "name": Json("sub-sequence"),
          "metadata": nothing(),
          "source_range": duration(0L, length, rate~),
          "children": Json::array([]),
          "markers": Json::array([]),
          "effects": Json::array([]),
          "enabled": Json(true),
        }),
      )
    _ =>
      Some(
        footage_clip(media_keys[(child.media & 3).to_int()], start, length, rate~),
      )
  }
}

///|
/// Black, as long as asked.
pub fn black(
  length : Int64,
  rate~ : @tool.Rate = @tool.Rate::whole(24),
) -> Json {
  Json::object({
    "OTIO_SCHEMA": Json("Gap.1"),
    "name": Json(""),
    "metadata": nothing(),
    "source_range": duration(0L, length, rate~),
    "markers": Json::array([]),
    "effects": Json::array([]),
    "enabled": Json(true),
  })
}

///|
/// A track laid out from whole documents rather than from the generator's
/// small numbers, for the rules that are stated in thousands.
pub fn plain_track(children : Array[Json]) -> Json {
  Json::object({
    "OTIO_SCHEMA": Json("Track.1"),
    "name": Json("V1"),
    "kind": Json("Video"),
    "children": Json::array(children),
    "metadata": nothing(),
    "source_range": Json::null(),
    "markers": Json::array([]),
    "effects": Json::array([]),
    "enabled": Json(true),
  })
}

///|
/// A track holding generated children. `sound` makes it an Audio track.
pub fn track_of(
  children : Array[Child],
  sound : Bool,
  markers : Array[Json],
  far~ : Int64 = 0L,
  lead~ : Int64 = 0L,
  rate~ : @tool.Rate = @tool.Rate::whole(24),
) -> Json {
  let laid = []
  if lead > 0L {
    laid.push(black(lead, rate~))
  }
  for child in children {
    match child_of(child, far~, rate~) {
      Some(one) => laid.push(one)
      None => ()
    }
  }
  Json::object({
    "OTIO_SCHEMA": Json("Track.1"),
    "name": Json(if sound { "A1" } else { "V1" }),
    "kind": Json(if sound { "Audio" } else { "Video" }),
    "children": Json::array(laid),
    "metadata": nothing(),
    "source_range": Json::null(),
    "markers": Json::array(markers),
    "effects": Json::array([]),
    "enabled": Json(true),
  })
}

///|
/// A sequence of one or two tracks. The second is always of the other kind
/// than the first, so that choosing a track is a real choice.
pub fn sequence(
  first : Json,
  second : Json?,
  rate~ : @tool.Rate = @tool.Rate::whole(24),
) -> Json {
  let tracks = [first]
  match second {
    Some(one) => tracks.push(one)
    None => ()
  }
  Json::object({
    "OTIO_SCHEMA": Json("Timeline.1"),
    "name": Json("Generated"),
    "metadata": nothing(),
    "global_start_time": instant(0L, rate~),
    "tracks": Json::object({
      "OTIO_SCHEMA": Json("Stack.1"),
      "name": Json("tracks"),
      "metadata": nothing(),
      "children": Json::array(tracks),
      "markers": Json::array([]),
      "effects": Json::array([]),
      "enabled": Json(true),
    }),
  })
}

///|
/// A marker of the editor's own: nothing in it says it came from this tool.
pub fn own_marker(
  name : String,
  at : Int64,
  length : Int64,
  rate~ : @tool.Rate = @tool.Rate::whole(24),
) -> Json {
  Json::object({
    "OTIO_SCHEMA": Json("Marker.2"),
    "name": Json(name),
    "comment": Json(""),
    "color": Json("RED"),
    "marked_range": duration(at, length, rate~),
    "metadata": nothing(),
  })
}

///|
/// The selected track of a document.
pub fn track_of_document(document : Json, index : Int32) -> Json {
  items(entry(entry(document, "tracks"), "children"))[index.to_int()]
}

///|
/// The markers on a track, or none where the track lists none.
pub fn markers_on(track : Json) -> Array[Json] {
  guard track is Object(fields) && fields.get("markers") is Some(value) else {
    return []
  }
  items(value)
}

///|
/// A deep copy, so that the oracle can build the document it expects without
/// touching the one it was given.
pub fn copied(value : Json) -> Json {
  match value {
    Array(list) => Json::array(list.map(copied))
    Object(fields) => {
      let out : Map[String, Json] = Map([])
      for key, item in fields {
        out[key] = copied(item)
      }
      Json::object(out)
    }
    _ => value
  }
}

///|
/// Put a track's markers where they belong in a copy of the document.
pub fn with_markers_on(document : Json, index : Int32, markers : Array[Json]) -> Json {
  let out = copied(document)
  let tracks = items(entry(entry(out, "tracks"), "children"))
  guard tracks[index.to_int()] is Object(fields) else {
    abort("oracle: the track is not an object")
  }
  fields["markers"] = Json::array(markers)
  out
}
