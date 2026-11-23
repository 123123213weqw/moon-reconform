///|
fn base_request() -> Map[String, Json] {
  {
    "fps": Json::number(24.0),
    "old_track": Json::number(0.0),
    "new_track": Json::number(0.0),
    "notes": Json::array([]),
  }
}

///|
fn request_error(request : Map[String, Json]) -> String {
  let outcome = Ok(read_request(Json::object(request))) catch {
    error => Err(error)
  }
  match outcome {
    Err(Invalid(message)) => message
    _ => "no error raised"
  }
}

///|
fn note_object(note : Map[String, Json]) -> Json {
  Json::object(note)
}

///|
test "request rejects unknown fields by name at every level" {
  // A misspelled key used to be skipped, which narrowed what the tool
  // read: "end" in place of "stop" turned a range into a single frame.
  let misspelled = base_request()
  misspelled["selectons"] = Json::array([])
  assert_eq(request_error(misspelled), "request: unknown field selectons")

  let narrowed = base_request()
  narrowed["notes"] = Json::array([
    note_object({
      "id": Json("n1"),
      "text": Json("check the cut-in"),
      "start": Json::number(4.0),
      "end": Json::number(6.0),
    }),
  ])
  assert_eq(request_error(narrowed), "annotation n1: unknown field end")

  let selection = base_request()
  selection["notes"] = Json::array([
    note_object({
      "id": Json("n1"),
      "text": Json("t"),
      "start": Json::number(4.0),
    }),
  ])
  selection["selections"] = Json::array([
    Json::object({
      "note_id": Json("n1"),
      "piece": Json::number(0.0),
      "clips": Json::number(3.0),
    }),
  ])
  assert_eq(request_error(selection), "selection: unknown field clips")
}

///|
test "request keeps the documented shapes" {
  let request = base_request()
  request["notes"] = Json::array([
    note_object({
      "id": Json("n1"),
      "text": Json("t"),
      "start": Json::number(4.0),
    }),
    note_object({
      "id": Json("n2"),
      "text": Json("t"),
      "start": Json::number(3.0),
      "stop": Json::number(6.0),
    }),
  ])
  let parsed = read_request(Json::object(request))
  assert_eq(parsed.fps, 24)
  assert_eq(parsed.notes.length(), 2)
  // An omitted stop is one frame; an explicit stop is exclusive.
  assert_eq(parsed.notes[0].range.stop, 5L)
  assert_eq(parsed.notes[1].range.length(), 3L)
  assert_eq(parsed.selections.length(), 0)
  assert_eq(parsed.from_markers, false)
}

///|
test "from_markers is a flag, not a string" {
  let flagged = base_request()
  flagged["from_markers"] = Json::boolean(true)
  assert_eq(read_request(Json::object(flagged)).from_markers, true)
  flagged["from_markers"] = Json::boolean(false)
  assert_eq(read_request(Json::object(flagged)).from_markers, false)
  // A quoted flag would otherwise read as silently off.
  flagged["from_markers"] = Json("yes")
  assert_eq(request_error(flagged), "request.from_markers: expected a boolean")
  flagged["from_markers"] = Json::number(1.0)
  assert_eq(request_error(flagged), "request.from_markers: expected a boolean")
}

///|
test "source-anchored annotations parse alone and refuse a second anchor" {
  let request = base_request()
  request["notes"] = Json::array([
    note_object({
      "id": Json("s1"),
      "text": Json("check the trimmed head"),
      "media": Json("file:///shoot/A.mov"),
      "source": Json::object({
        "start": Json::number(30.0),
        "stop": Json::number(33.0),
      }),
    }),
  ])
  let parsed = read_request(Json::object(request))
  assert_eq(parsed.notes[0].media, Some("file:///shoot/A.mov"))
  assert_eq(parsed.notes[0].range.start, 30L)
  assert_eq(parsed.notes[0].range.stop, 33L)

  let twice = base_request()
  twice["notes"] = Json::array([
    note_object({
      "id": Json("s1"),
      "text": Json("t"),
      "start": Json::number(4.0),
      "media": Json("file:///shoot/A.mov"),
      "source": Json::object({
        "start": Json::number(30.0),
        "stop": Json::number(33.0),
      }),
    }),
  ])
  assert_eq(
    request_error(twice),
    "annotation s1: media and source cannot combine with start and stop",
  )

  let orphan = base_request()
  orphan["notes"] = Json::array([
    note_object({
      "id": Json("s1"),
      "text": Json("t"),
      "start": Json::number(4.0),
      "source": Json::object({
        "start": Json::number(30.0),
        "stop": Json::number(33.0),
      }),
    }),
  ])
  assert_eq(request_error(orphan), "annotation s1: source requires media")

  let typo = base_request()
  typo["notes"] = Json::array([
    note_object({
      "id": Json("s1"),
      "text": Json("t"),
      "media": Json("file:///shoot/A.mov"),
      "source": Json::object({
        "start": Json::number(30.0),
        "end": Json::number(33.0),
      }),
    }),
  ])
  assert_eq(request_error(typo), "s1.source: unknown field end")

  let empty = base_request()
  empty["notes"] = Json::array([
    note_object({
      "id": Json("s1"),
      "text": Json("t"),
      "media": Json(""),
      "source": Json::object({
        "start": Json::number(30.0),
        "stop": Json::number(33.0),
      }),
    }),
  ])
  assert_eq(request_error(empty), "annotation s1: media is empty")
}
