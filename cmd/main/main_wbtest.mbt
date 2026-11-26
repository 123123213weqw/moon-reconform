///|

///|
/// The command's own rules, with its files and its output in the test's
/// hands. The command reads nothing that is not laid out here and prints
/// nothing that is not collected here, so a rule can be stated exactly.

///|
/// A frame count at 24 fps, as OpenTimelineIO writes it.
fn at(value : Int64) -> String {
  "{\"OTIO_SCHEMA\":\"RationalTime.1\",\"value\":" +
  value.to_string() +
  ",\"rate\":24}"
}

///|
fn range(start : Int64, length : Int64) -> String {
  "{\"OTIO_SCHEMA\":\"TimeRange.1\",\"start_time\":" +
  at(start) +
  ",\"duration\":" +
  at(length) +
  "}"
}

///|
const A : String = "file:///shoot/A.mov"

///|
fn clip(start : Int64, length : Int64) -> String {
  "{\"OTIO_SCHEMA\":\"Clip.2\",\"name\":\"clip\",\"media_references\":{\"original\":{\"OTIO_SCHEMA\":\"ExternalReference.1\",\"name\":\"\",\"metadata\":{},\"target_url\":\"" +
  A +
  "\",\"available_range\":" +
  range(0L, 4000L) +
  ",\"available_image_bounds\":null}},\"active_media_reference_key\":\"original\",\"metadata\":{},\"source_range\":" +
  range(start, length) +
  ",\"markers\":[],\"effects\":[],\"enabled\":true,\"color\":null}"
}

///|
fn black(length : Int64) -> String {
  "{\"OTIO_SCHEMA\":\"Gap.1\",\"name\":\"\",\"metadata\":{},\"source_range\":" +
  range(0L, length) +
  ",\"markers\":[],\"effects\":[],\"enabled\":true,\"color\":null}"
}

///|
fn cut(children : Array[String], markers : Array[String]) -> String {
  let tracks = [
    "{\"OTIO_SCHEMA\":\"Track.1\",\"name\":\"V1\",\"kind\":\"Video\",\"children\":[" +
    children.join(",") +
    "],\"metadata\":{},\"source_range\":null,\"markers\":[" +
    markers.join(",") +
    "],\"effects\":[],\"enabled\":true,\"color\":null}",
  ]
  "{\"OTIO_SCHEMA\":\"Timeline.1\",\"name\":\"Review\",\"metadata\":{},\"global_start_time\":null,\"tracks\":{\"OTIO_SCHEMA\":\"Stack.1\",\"name\":\"tracks\",\"source_range\":null,\"metadata\":{},\"children\":[" +
  tracks.join(",") +
  "],\"markers\":[],\"effects\":[]}}"
}

///|
fn review(
  notes : Array[String],
  selections : Array[String],
  asked : Bool,
) -> String {
  "{\"fps\":24,\"old_track\":0,\"new_track\":0,\"notes\":[" +
  notes.join(",") +
  "],\"selections\":[" +
  selections.join(",") +
  "],\"from_markers\":" +
  (if asked { "true" } else { "false" }) +
  "}"
}

///|
fn note(id : String, start : Int64, stop : Int64) -> String {
  "{\"id\":\"" +
  id +
  "\",\"text\":\"审阅 " +
  id +
  "\",\"start\":" +
  start.to_string() +
  ",\"stop\":" +
  stop.to_string() +
  "}"
}

///|
/// Files that hold the given texts, report the given sizes where a text
/// stands for a larger file, and fail to write where asked to. They say
/// what the command wrote, what limit it read with, and what it read.
fn desk(
  texts : Map[String, String],
  sizes : Map[String, Int64],
  failing : String?,
) -> (Files, Array[(String, String)], Array[Int64], Array[String]) {
  let written = []
  let limits = []
  let read = []
  let files : Files = {
    read: fn(path, up_to) {
      limits.push(up_to)
      read.push(path)
      guard texts.get(path) is Some(text) else { return None }
      let size = match sizes.get(path) {
        Some(given) => given
        None => text.length().to_int64()
      }
      if size > up_to {
        None
      } else {
        Some(text)
      }
    },
    write: fn(path, content) {
      match failing {
        Some(error) => Some(error)
        // Semicolons separate statements here; without one the push
        // and the None would read as one expression.
        None => {
          written.push((path, content))
          None
        }
      }
    },
  }
  (files, written, limits, read)
}

///|
const OLD : String = "old.otio"

///|
const NEW : String = "new.otio"

///|
const ASKED : String = "request.json"

///|
const OUT : String = "reviewed.otio"

///|
/// The command's three paths, in the order it takes them.
fn inputs(old : String, fresh : String, asked : String) -> Map[String, String] {
  let texts : Map[String, String] = Map([])
  texts[OLD] = old
  texts[NEW] = fresh
  texts[ASKED] = asked
  texts
}

///|
/// Run the command on these files and collect what it printed.
fn run(args : Array[String], files : Files) -> (Array[String], Bool) {
  let said = []
  let failed = command(args, files, fn(text) { said.push(text) })
  (said, failed)
}

///|
fn refusal(message : String) -> String {
  Json::object({ "ok": Json(false), "error": Json(message) }).stringify()
}

///|
fn part(value : Json, key : String) -> Json raise {
  guard value is Object(fields) && fields.get(key) is Some(found) else {
    fail("no member " + key)
  }
  found
}

///|
fn listed(value : Json) -> Array[Json] raise {
  guard value is Array(items) else { fail("not an array") }
  items
}

///|
fn word(value : Json) -> String raise {
  guard value is String(found) else { fail("not a string") }
  found
}

///|
/// What the command printed, read back as the JSON it had to be.
fn printed(line : String) -> Json raise {
  match @codec.parse(line) {
    Ok(value) => value
    Err(error) => fail("the command did not print JSON: " + error)
  }
}

///|
test "a wrong invocation is refused with the usage, before any file is read" {
  let wrong = [
    ["node", "main.mbt"],
    ["node", "main.mbt", "plan"],
    ["node", "main.mbt", "plan", OLD, NEW],
    ["node", "main.mbt", "apply", OLD, NEW, ASKED],
    ["node", "main.mbt", "replan", OLD, NEW, ASKED],
    ["node", "main.mbt", "plan", OLD, NEW, ASKED, OUT],
    ["node", "main.mbt", "apply", OLD, NEW, ASKED, OUT, OUT],
  ]
  for args in wrong {
    let (files, written, _, read) = desk(Map([]), Map([]), None)
    let (said, failed) = run(args, files)
    assert_eq(said, [refusal(usage)])
    assert_true(failed)
    assert_eq(read, [])
    assert_eq(written, [])
  }
}

///|
test "the help flags print the usage and do not fail" {
  for flag in ["--help", "-h"] {
    let (files, written, _, read) = desk(Map([]), Map([]), None)
    let (said, failed) = run(["node", "main.mbt", flag], files)
    assert_eq(said, [usage])
    assert_false(failed)
    assert_eq(read, [])
    assert_eq(written, [])
  }
}

///|
test "an input is a regular UTF-8 file of at most 16,000,000 bytes" {
  let limit : Int64 = 16_000_000
  // A file that is not there, named as the one that could not be read.
  let (absent, _, limits, _) = desk(Map([]), Map([]), None)
  let (said, failed) = run(
    ["node", "main.mbt", "plan", OLD, NEW, ASKED],
    absent,
  )
  assert_eq(said, [
    refusal("cannot read a regular UTF-8 input file of at most 16 MB: " + OLD),
  ])
  assert_true(failed)
  // The limit is the command's own, and is what it reads with.
  assert_eq(limits, [limit])
  // A file of exactly the limit is read, and one byte more is not.
  let texts = inputs(cut([clip(0L, 4L)], []), cut([clip(0L, 4L)], []), "{}")
  for (size, readable) in [(limit, true), (limit + 1L, false)] {
    let sizes : Map[String, Int64] = Map([])
    sizes[ASKED] = size
    let (files, _, _, read) = desk(texts, sizes, None)
    let (said, failed) = run(
      ["node", "main.mbt", "plan", OLD, NEW, ASKED],
      files,
    )
    assert_true(failed)
    if readable {
      // The request was read and then refused by the core: `{}` has no fps.
      assert_eq(read, [OLD, NEW, ASKED])
      assert_true(said[0].has_prefix("{\"ok\":false,\"error\":\"request"))
      assert_false(said[0].contains("cannot read"))
    } else {
      assert_eq(said, [
        refusal(
          "cannot read a regular UTF-8 input file of at most 16 MB: " + ASKED,
        ),
      ])
    }
  }
  // A file that is not JSON is named with what was wrong with it.
  let broken = inputs(cut([clip(0L, 4L)], []), cut([clip(0L, 4L)], []), "{")
  let (files, _, _, _) = desk(broken, Map([]), None)
  let (said, failed) = run(["node", "main.mbt", "plan", OLD, NEW, ASKED], files)
  assert_true(failed)
  assert_eq(said.length(), 1)
  assert_true(said[0].has_prefix("{\"ok\":false,\"error\":\"" + ASKED + ": "))
}

///|
test "a plan prints the core's report and writes nothing" {
  let texts = inputs(
    cut([clip(0L, 4L), black(2L)], []),
    cut([clip(0L, 2L), clip(1L, 4L)], []),
    review([note("n1", 1L, 3L), note("n2", 4L, 6L)], [], false),
  )
  let (files, written, _, read) = desk(texts, Map([]), None)
  let (said, failed) = run(["node", "main.mbt", "plan", OLD, NEW, ASKED], files)
  assert_false(failed)
  assert_eq(read, [OLD, NEW, ASKED])
  assert_eq(written, [])
  assert_eq(said.length(), 1)
  let report = printed(said[0])
  assert_eq(part(report, "ok"), Json(true))
  // The first frame of n1 is shown twice over and the rest once, so n1 is
  // held for a choice; n2 lies on black.
  assert_eq(listed(part(report, "transfers")).length(), 0)
  let notes = listed(part(report, "notes"))
  assert_eq(notes.length(), 2)
  let pieces = listed(part(notes[0], "pieces"))
  assert_eq(pieces.length(), 2)
  assert_eq(listed(part(pieces[0], "candidates")).length(), 2)
  assert_eq(word(part(pieces[0], "status")), "ambiguous")
  assert_eq(listed(part(pieces[1], "candidates")).length(), 1)
  assert_eq(word(part(pieces[1], "status")), "unique")
  assert_eq(word(part(listed(part(notes[1], "pieces"))[0], "status")), "gap")
  assert_eq(listed(part(report, "held")).map(word), ["n1", "n2"])
}

///|
test "an apply writes the new cut with its markers, and prints the report" {
  let texts = inputs(
    cut([clip(0L, 4L)], []),
    cut([clip(0L, 4L), black(2L)], []),
    review([note("n1", 0L, 1L)], [], false),
  )
  let (files, written, _, _) = desk(texts, Map([]), None)
  let (said, failed) = run(
    ["node", "main.mbt", "apply", OLD, NEW, ASKED, OUT],
    files,
  )
  assert_false(failed)
  assert_eq(written.length(), 1)
  let (path, content) = written[0]
  assert_eq(path, OUT)
  let report = printed(said[0])
  let transfers = listed(part(report, "transfers"))
  assert_eq(transfers.length(), 1)
  assert_eq(word(part(transfers[0], "note_id")), "n1")
  // What was written is a document with the marker on it.
  let document = printed(content)
  let tracks = listed(part(part(document, "tracks"), "children"))
  assert_eq(tracks.length(), 1)
  let markers = listed(part(tracks[0], "markers"))
  assert_eq(markers.length(), 1)
  assert_eq(word(part(markers[0], "name")), "审阅 n1")
}

///|
test "a failure to write is the command's own failure, said whole" {
  let texts = inputs(
    cut([clip(0L, 4L)], []),
    cut([clip(0L, 4L)], []),
    review([note("n1", 0L, 1L)], [], false),
  )
  let reason = "cannot create OTIO output (EEXIST): " + OUT
  let (files, _, _, _) = desk(texts, Map([]), Some(reason))
  let (said, failed) = run(
    ["node", "main.mbt", "apply", OLD, NEW, ASKED, OUT],
    files,
  )
  assert_true(failed)
  assert_eq(said, [refusal(reason)])
}

///|
test "markers the old cut carries are read back when the request asks" {
  // A first round puts a marker on the new cut.
  let (files, written, _, _) = desk(
    inputs(
      cut([clip(0L, 4L)], []),
      cut([clip(0L, 4L)], []),
      review([note("n1", 0L, 1L)], [], false),
    ),
    Map([]),
    None,
  )
  let (_, failed) = run(
    ["node", "main.mbt", "apply", OLD, NEW, ASKED, OUT],
    files,
  )
  assert_false(failed)
  let marked = written[0].1
  // The next cut no longer shows the first frame the marker is on.
  let moved = cut([clip(1L, 4L)], [])
  for (asked, notes, held) in [(true, 1, ["n1#0"]), (false, 0, [])] {
    let (files, _, _, _) = desk(
      inputs(marked, moved, review([], [], asked)),
      Map([]),
      None,
    )
    let (said, failed) = run(
      ["node", "main.mbt", "plan", OLD, NEW, ASKED],
      files,
    )
    assert_false(failed)
    let report = printed(said[0])
    let found = listed(part(report, "notes"))
    assert_eq(found.length(), notes)
    if asked {
      assert_eq(word(part(found[0], "id")), "n1#0")
      assert_eq(part(part(found[0], "origin"), "note_id"), Json("n1"))
      assert_eq(
        word(part(listed(part(found[0], "pieces"))[0], "status")),
        "deleted",
      )
    }
    let refused = listed(part(report, "held")).map(word)
    assert_eq(refused, held)
    assert_eq(listed(part(report, "transfers")).length(), 0)
  }
}

///|
test "a refusal from the core is passed through whole, with no source position" {
  let texts = inputs(
    cut([clip(0L, 4L)], []),
    cut([clip(0L, 4L)], []),
    "{\"fps\":24,\"old_track\":0,\"new_track\":0,\"notes\":[],\"selections\":[],\"end\":3,\"from_markers\":false}",
  )
  let (files, _, _, _) = desk(texts, Map([]), None)
  let (said, failed) = run(["node", "main.mbt", "plan", OLD, NEW, ASKED], files)
  assert_true(failed)
  assert_eq(said, [refusal("request: unknown field end")])
  assert_false(said[0].contains(".mbt:"))
  assert_false(said[0].contains("Failure("))
}
