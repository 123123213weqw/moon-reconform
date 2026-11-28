///|
fn refusal_of(document : Json, none : Resolution) -> String {
  let outcome = Ok(with_markers(document, track_index=0, fps=Rate::whole(24), none)) catch {
    error => Err(error)
  }
  match outcome {
    Err(Invalid(message)) => message
    Err(Limit(message)) => "limit: " + message
    _ => "no error raised"
  }
}

///|
fn no_transfers(document : Json) -> Resolution raise ReconformError {
  let cut = read_otio(document, track_index=0, fps=Rate::whole(24))
  resolve(plan(cut, cut, []), [])
}

///|
fn j_with_metadata(document : Json, value : Json) -> Json raise ReconformError {
  let fields = object(document, "cut").copy()
  fields["metadata"] = j_obj({ "anything": value })
  Json::object(fields)
}

///|
test "a number no double can hold is refused before it can be written back" {
  let cut = j_timeline(j_track([j_clip("file:///shoot/A.mov", 0L, 4L, Rate::whole(24))], []))
  let none = no_transfers(cut)
  // The text 1e309 is a JSON number and not a double. Read as infinity, the
  // only thing the codec can write back is Inf: the text said something
  // finite and would come back infinite.
  let overflow : Double = 1.0e308 * 10.0
  let over = j_with_metadata(
    cut,
    j_obj({
      "deep": Json::array([
        j_obj({ "deeper": Json::number(overflow, repr="1e309") }),
      ]),
    }),
  )
  assert_eq(
    refusal_of(over, none),
    "the new cut holds a number too large to write back unchanged: 1e309",
  )
  for token in ["-1e400", "1.7976931348623159e308", "1e999999999"] {
    let value = if token[0] == '-' { -overflow } else { overflow }
    assert_eq(
      refusal_of(j_with_metadata(cut, Json::number(value, repr=token)), none),
      "the new cut holds a number too large to write back unchanged: " + token,
    )
  }
  // A number that already says it is not finite passes. The codec keeps no
  // text for Inf, -Inf or NaN, and writes them back as Inf, -Inf and NaN.
  let nan = overflow - overflow
  let lenient : Array[Double] = [overflow, -overflow, nan]
  for value in lenient {
    assert_eq(
      refusal_of(j_with_metadata(cut, Json::number(value)), none),
      "no error raised",
    )
  }
  // The largest and the smallest finite doubles are kept.
  let finite : Array[(Double, String)] = [
    (1.0e308, "1e308"),
    (1.7976931348623157e308, "1.7976931348623157e308"),
    (-1.0e308, "-1e308"),
    (1.0e-323, "1e-323"),
    (0.1, "0.1"),
  ]
  for pair in finite {
    let (value, token) = pair
    assert_eq(
      refusal_of(j_with_metadata(cut, Json::number(value, repr=token)), none),
      "no error raised",
    )
  }
  // The walk keeps its own stack: the number may sit under any depth.
  let mut buried : Json = Json::number(-overflow, repr="-1e400")
  for _ in 0..<200000 {
    buried = Json::array([buried])
  }
  assert_eq(
    refusal_of(j_with_metadata(cut, buried), none),
    "the new cut holds a number too large to write back unchanged: -1e400",
  )
}
