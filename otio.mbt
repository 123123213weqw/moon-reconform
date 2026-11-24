///|
fn object(
  value : Json,
  context : String,
) -> Map[String, Json] raise ReconformError {
  guard value is Object(fields) else {
    raise Invalid(context + ": expected an object")
  }
  fields
}

///|
fn array(value : Json, context : String) -> Array[Json] raise ReconformError {
  guard value is Array(items) else {
    raise Invalid(context + ": expected an array")
  }
  items
}

///|
fn required(
  fields : Map[String, Json],
  key : String,
  context : String,
) -> Json raise ReconformError {
  guard fields.get(key) is Some(value) else {
    raise Invalid(context + ": missing " + key)
  }
  value
}

///|
fn string(value : Json, context : String) -> String raise ReconformError {
  guard value is String(content) else {
    raise Invalid(context + ": expected a string")
  }
  content
}

///|
fn field_string(
  fields : Map[String, Json],
  key : String,
  context : String,
) -> String raise ReconformError {
  string(required(fields, key, context), context + "." + key)
}

///|
fn expect_schema(
  fields : Map[String, Json],
  schema : String,
  context : String,
) -> Unit raise ReconformError {
  if field_string(fields, "OTIO_SCHEMA", context) != schema {
    raise Invalid(context + ": expected " + schema)
  }
}

///|
fn exact_integer(value : Json, context : String) -> Int64 raise ReconformError {
  guard value is Number(n, repr~) else {
    raise Invalid(context + ": expected a nonnegative exact integer")
  }
  if !(n >= 0.0 && n <= max_frames.to_double() && n == n.floor()) ||
    (repr is Some(token) && !integral_token(token, is_zero=n == 0.0)) {
    raise Invalid(context + ": expected a nonnegative exact integer")
  }
  n.to_int64()
}

///|
// The lossless codec preserves numeric token text. A decimal smaller than
// one binary64 ULP must still be rejected if its original value is fractional.
fn integral_token(token : String, is_zero~ : Bool) -> Bool {
  let mut decimal = false
  let mut exponent = false
  let mut exponent_negative = false
  let mut magnitude = 0L
  let mut fractional = 0L
  let mut trailing_zeroes = 0L
  let mut nonzero = false
  for digit in token {
    match digit {
      'e' | 'E' => exponent = true
      '.' => decimal = true
      '-' if exponent => exponent_negative = true
      '-' | '+' => ()
      '0'..<='9' =>
        if exponent {
          if magnitude <= token.length().to_int64() {
            magnitude = magnitude * 10L +
              (digit.to_int() - '0'.to_int()).to_int64()
          }
        } else {
          if decimal {
            fractional += 1L
          }
          if digit == '0' {
            trailing_zeroes += 1L
          } else {
            trailing_zeroes = 0L
            nonzero = true
          }
        }
      _ => return false
    }
  }
  if !nonzero {
    return true
  }
  if is_zero {
    return false
  }
  let shift = if exponent_negative { -magnitude } else { magnitude }
  shift + trailing_zeroes >= fractional
}

///|
fn exact_time(
  value : Json,
  fps : Int32,
  context : String,
) -> Int64 raise ReconformError {
  let fields = object(value, context)
  expect_schema(fields, "RationalTime.1", context)
  // A rate that is not a whole number is what 23.976 and 29.97 footage
  // looks like. That is the commonest reason to be refused, and it
  // deserves more than being called a bad integer.
  match required(fields, "rate", context) {
    Number(n, repr~) if n > 0.0 && n < 1000000.0 && n != n.floor() => raise Invalid(
        context +
        ".rate: the frame rate " +
        repr.unwrap_or(n.to_string()) +
        " is not a whole number of frames per second. Cuts at rates such as 23.976 and 29.97 are not supported.",
      )
    _ => ()
  }
  let rate = exact_integer(required(fields, "rate", context), context + ".rate")
  if rate != fps.to_int64() {
    raise Invalid(
      context +
      ": RationalTime rate " +
      rate.to_string() +
      " differs from the request's " +
      fps.to_string() +
      " fps. Every time in a cut has to be at one whole-number frame rate. An export that gives a clip's footage at the rate of its own media, as 15 fps footage in a 30 fps sequence, mixes rates and is not supported.",
    )
  }
  exact_integer(required(fields, "value", context), context + ".value")
}

///|
fn source_range(
  value : Json,
  fps : Int32,
  context : String,
) -> Span raise ReconformError {
  let fields = object(value, context)
  expect_schema(fields, "TimeRange.1", context)
  let start = exact_time(
    required(fields, "start_time", context),
    fps,
    context + ".start_time",
  )
  let duration = exact_time(
    required(fields, "duration", context),
    fps,
    context + ".duration",
  )
  let span = { start, stop: add_frames(start, duration), }
  span.checked(context)
  span
}

///|
fn reject_effects(
  fields : Map[String, Json],
  context : String,
) -> Unit raise ReconformError {
  match fields.get("enabled") {
    None | Some(True) => ()
    _ => raise Invalid(context + ": expected an enabled OTIO item")
  }
  if fields.get("effects") is Some(value) &&
    array(value, context + ".effects").length() > 0 {
    raise Invalid(
      context + ": effects and retiming are outside the supported format",
    )
  }
}

///|
fn untrimmed(
  fields : Map[String, Json],
  context : String,
) -> Unit raise ReconformError {
  match fields.get("source_range") {
    None | Some(Null) => ()
    Some(_) =>
      raise Invalid(
        context + ": source_range trims a containing track or stack",
      )
  }
  reject_effects(fields, context)
}

///|
fn otio_track(
  root : Json,
  track_index : Int32,
) -> Map[String, Json] raise ReconformError {
  let timeline = object(root, "timeline")
  expect_schema(timeline, "Timeline.1", "timeline")
  let stack = object(required(timeline, "tracks", "timeline"), "tracks")
  expect_schema(stack, "Stack.1", "tracks")
  untrimmed(stack, "tracks")
  let tracks = array(required(stack, "children", "tracks"), "tracks.children")
  guard tracks.get(track_index) is Some(value) else {
    raise Invalid("track index is outside the stack")
  }
  let track = object(value, "selected track")
  expect_schema(track, "Track.1", "selected track")
  // A Video track and an Audio track are each one line of time whose
  // children are cuts of footage, which is all the plan needs of a track.
  // A Transition track, or a kind an application made up, means something
  // else and is refused rather than read as cuts.
  let kind = field_string(track, "kind", "selected track")
  if kind != "Video" && kind != "Audio" {
    raise Invalid("selected track must be a Video or Audio track")
  }
  untrimmed(track, "selected track")
  // The track's markers are handed back as they are, read or not, so each
  // has to be a marker: an object. Anything else in their place is not
  // something this tool would know how to keep. The rule sits here, where
  // every reader of a track passes, so that plan, apply and from_markers
  // agree on it.
  match track.get("markers") {
    None => ()
    Some(value) =>
      for i, marker in array(value, "selected track.markers") {
        guard marker is Object(_) else {
          raise Invalid(
            "selected track marker " + i.to_string() + ": expected an object",
          )
        }
      }
  }
  track
}

///|
fn media_value(
  clip : Map[String, Json],
  schema : String,
  context : String,
) -> Json raise ReconformError {
  if schema == "Clip.1" {
    required(clip, "media_reference", context)
  } else {
    let references = object(
      required(clip, "media_references", context),
      context + ".media_references",
    )
    let key = field_string(clip, "active_media_reference_key", context)
    required(references, key, context + ".media_references")
  }
}

///|
fn check_fps(fps : Int32) -> Unit raise ReconformError {
  if fps <= 0 || fps > 240 {
    raise Invalid("fps must be between 1 and 240")
  }
}

///|
/// Read one untrimmed hard-cut Video or Audio track from a Timeline.1.
pub fn read_otio(
  root : Json,
  track_index~ : Int32,
  fps~ : Int32,
) -> Timeline raise ReconformError {
  check_fps(fps)
  let track = otio_track(root, track_index)
  let children = array(
    required(track, "children", "selected track"),
    "track.children",
  )
  if children.length() > 20000 {
    raise Limit("too many shots; limit is 20000")
  }
  let shots = []
  for i, value in children {
    let context = "track child " + i.to_string()
    let child = object(value, context)
    let schema = field_string(child, "OTIO_SCHEMA", context)
    reject_effects(child, context)
    let shot = match schema {
      "Clip.1" | "Clip.2" => {
        let media = media_value(child, schema, context)
        let found = match media {
          // A clip may name no media at all.
          Null => "none"
          _ =>
            field_string(
              object(media, context + ".media_reference"),
              "OTIO_SCHEMA",
              context + ".media_reference",
            )
        }
        if found != "ExternalReference.1" {
          // Media with no location of its own, or none at all: missing,
          // embedded, or made by the application. The clip takes up time,
          // and a note on it is held until the media is linked, but there
          // is no footage to place the note by. The clip alone knows how
          // long it is.
          match required(child, "source_range", context) {
            Null =>
              raise Invalid(
                context +
                ": a clip with no media of its own (" +
                found +
                ") has to say how long it is with a source_range",
              )
            range =>
              Unplaceable(
                Offline,
                source_range(range, fps, context + ".source_range").length(),
              )
          }
        } else {
          let reference = object(media, context + ".media_reference")
          let url = field_string(
            reference,
            "target_url",
            context + ".media_reference",
          )
          let range = match required(child, "source_range", context) {
            Null =>
              required(reference, "available_range", context + ".media_reference")
            range => range
          }
          Clip(url, source_range(range, fps, context + ".source_range"))
        }
      }
      "Gap.1" =>
        Gap(
          source_range(
            required(child, "source_range", context),
            fps,
            context + ".source_range",
          ).length(),
        )
      // A transition lies between two clips and lasts its two offsets.
      "Transition.1" => {
        let entering = exact_time(
          required(child, "in_offset", context),
          fps,
          context + ".in_offset",
        )
        let leaving = exact_time(
          required(child, "out_offset", context),
          fps,
          context + ".out_offset",
        )
        let length = add_frames(entering, leaving)
        if length == 0L {
          raise Invalid(context + ": a transition has to last at least one frame")
        }
        Unplaceable(Transition, length)
      }
      // A sequence nested as a clip lasts what its source range says.
      "Stack.1" =>
        match required(child, "source_range", context) {
          Null =>
            raise Invalid(
              context +
              ": a nested sequence has to say how long it is with a source_range",
            )
          range =>
            Unplaceable(
              Nested,
              source_range(range, fps, context + ".source_range").length(),
            )
        }
      _ => raise Invalid(context + ": unsupported schema " + schema)
    }
    shots.push(shot)
  }
  Timeline::from_shots(shots)
}
