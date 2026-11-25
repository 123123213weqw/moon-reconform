///|
/// One child of a track as the oracle reads it: where it lies on the track
/// and, if it has footage, which footage and from which frame.
#derive(Eq, Debug)
pub(all) struct Slot {
  child : Int32
  from : Int64
  stop : Int64
  media : String?
  first : Int64?
  why : String?
}

///|
fn schema_of(value : Json) -> String {
  text(entry(value, "OTIO_SCHEMA"))
}

///|
fn length_of(range : Json) -> Int64 {
  whole(entry(entry(range, "duration"), "value"))
}

///|
fn first_of(range : Json) -> Int64 {
  whole(entry(entry(range, "start_time"), "value"))
}

///|
/// Read a track straight from its document. Nothing is validated: the
/// documents are ones the generator built or the tool wrote, and the point
/// is to reach their layout by the shortest way there is, not by the tool's.
pub fn slots(document : Json, index : Int32) -> Array[Slot] {
  let track = track_of_document(document, index)
  let result = []
  let mut at = 0L
  for child, item in items(entry(track, "children")) {
    let schema = schema_of(item)
    let (media, first, why, length) = if schema == "Gap.1" {
      (None, None, None, length_of(entry(item, "source_range")))
    } else if schema == "Transition.1" {
      (
        None,
        None,
        Some("transition"),
        whole(entry(entry(item, "in_offset"), "value")) +
        whole(entry(entry(item, "out_offset"), "value")),
      )
    } else if schema == "Stack.1" {
      (None, None, Some("nested"), length_of(entry(item, "source_range")))
    } else {
      let reference = if schema == "Clip.1" {
        entry(item, "media_reference")
      } else {
        let key = text(entry(item, "active_media_reference_key"))
        entry(entry(item, "media_references"), key)
      }
      if reference is Object(_) && schema_of(reference) == "ExternalReference.1" {
        // A clip without a source range uses as much of its media as there is.
        let own = entry(item, "source_range")
        let range = if own is Null { entry(reference, "available_range") } else { own }
        (
          Some(text(entry(reference, "target_url"))),
          Some(first_of(range)),
          None,
          length_of(range),
        )
      } else {
        (None, None, Some("offline"), length_of(entry(item, "source_range")))
      }
    }
    result.push({ child, from: at, stop: at + length, media, first, why })
    at = at + length
  }
  result
}

///|
/// How long a track is, by the oracle's own reading.
pub fn duration_of(laid : Array[Slot]) -> Int64 {
  let mut total = 0L
  for slot in laid {
    total = total + slot.stop - slot.from
  }
  total
}

///|
/// Every frame of a track in order: which child it lies on, and which frame
/// of which footage it shows when it shows one.
pub fn frames(laid : Array[Slot]) -> Array[(Int32, String?, Int64?)] {
  let result = []
  for slot in laid {
    for offset = 0L; offset < slot.stop - slot.from; offset = offset + 1L {
      result.push((
        slot.child,
        slot.media,
        match slot.first {
          Some(first) => Some(first + offset)
          None => None
        },
      ))
    }
  }
  result
}
