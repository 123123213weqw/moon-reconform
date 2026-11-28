///|
/// One step down a document: a member of an object, or a place in an array.
priv enum Step {
  Field(String)
  At(Int)
}

///|
/// The value a path leads to. The paths come from walking the same
/// document a moment before, so one that leads nowhere is a mistake here.
fn node_at(root : Json, path : Array[Step]) -> Json {
  let mut node = root
  for step in path {
    node = match (step, node) {
      (Field(key), Object(fields)) =>
        match fields.get(key) {
          Some(item) => item
          None => abort("oracle: no member " + key)
        }
      (At(index), Array(items)) => items[index]
      _ => abort("oracle: a path leads nowhere")
    }
  }
  node
}

///|
/// Put a value where a path leads, in the document itself.
fn put_at(root : Json, path : Array[Step], value : Json) -> Unit {
  let last = path[path.length() - 1]
  let parent = node_at(root, head(path, path.length() - 1))
  match (last, parent) {
    (Field(key), Object(fields)) => fields[key] = value
    (At(index), Array(items)) => items[index] = value
    _ => abort("oracle: a path leads nowhere")
  }
}

///|
/// The first `count` steps of a path.
fn head(path : Array[Step], count : Int) -> Array[Step] {
  let out = []
  for index = 0; index < count; index = index + 1 {
    out.push(path[index])
  }
  out
}

///|
fn nodes_of(
  value : Json,
  path : Array[Step],
  out : Array[(Json, Array[Step])],
) -> Unit {
  out.push((value, path))
  match value {
    Object(fields) =>
      for key, item in fields {
        let below = path.copy()
        below.push(Field(key))
        nodes_of(item, below, out)
      }
    Array(items) =>
      for index, item in items {
        let below = path.copy()
        below.push(At(index))
        nodes_of(item, below, out)
      }
    _ => ()
  }
}

///|
/// Every node of a document with the way there, the root first.
fn nodes(document : Json) -> Array[(Json, Array[Step])] {
  let out = []
  nodes_of(document, [], out)
  out
}

///|
/// The member a path ends at, where it ends at one.
fn under(path : Array[Step]) -> String? {
  if path.length() == 0 {
    None
  } else {
    match path[path.length() - 1] {
      Field(key) => Some(key)
      At(_) => None
    }
  }
}

///|
fn is_text(value : Json) -> Bool {
  value is String(_)
}

///|
fn is_list(value : Json) -> Bool {
  value is Array(_)
}

///|
fn is_object(value : Json) -> Bool {
  value is Object(_)
}

///|
/// A whole number that JSON writes in plain digits, if that is what this
/// is; anything too large to add to is left alone.
fn frame_count(value : Json) -> Int64? {
  guard value is Number(n, ..) &&
    n.abs() < 1152921504606846976.0 &&
    n == n.floor() else {
    return None
  }
  Some(n.to_int64())
}

///|
/// A small number drawn evenly from `0` up to `count`, not counting it.
/// Nothing to draw from is zero: a mutated frame count can come out too
/// large for an `Int`, and a caller that then divides it into a place and a
/// rest should not have to have thought of it.
fn among(count : Int, state : @splitmix.RandomState) -> Int {
  if count <= 0 {
    0
  } else {
    draw(count.reinterpret_as_uint(), state).to_int()
  }
}

///|
fn one_of(options : Array[Int64], state : @splitmix.RandomState) -> Int64 {
  options[among(options.length(), state)]
}

///|
fn any_of(options : Array[String], state : @splitmix.RandomState) -> String {
  options[among(options.length(), state)]
}

///|
/// The member of an object, where there is one.
fn member_of(value : Json, key : String) -> Json? {
  guard value is Object(fields) else { return None }
  fields.get(key)
}

///|
/// The members of an object, in the order it lists them.
fn keys_of(fields : Map[String, Json]) -> Array[String] {
  let keys = []
  for key, _ in fields {
    keys.push(key)
  }
  keys
}

///|
/// The frame counts and indexes a review counts in.
let counts : Array[String] = [
  "value", "start", "stop", "fps", "old_track", "new_track", "piece", "clip",
  "rate",
]

///|
/// Move one frame count or index: a nudge, a jump, a long way out, or a
/// value at the edge of what a frame can be.
fn renumber(document : Json, state : @splitmix.RandomState) -> Unit {
  let spots = nodes(document).filter(pair => {
    let named = match under(pair.1) {
      Some(key) => counts.contains(key)
      None => false
    }
    named && frame_count(pair.0) is Some(_)
  })
  if spots.length() == 0 {
    return
  }
  let (value, path) = spots[among(spots.length(), state)]
  let old = frame_count(value).unwrap()
  let roll = draw(100, state)
  let new = if roll < 60 {
    old +
    one_of([-2L, -1L, 1L, 2L], state)
  } else if roll < 80 {
    one_of([0L, 1L, 3L, 4L, 7L, 10L, 12L, 14L, 16L, 19L, 20L, 21L], state)
  } else if roll < 95 {
    (if old < 0L { 0L } else { old }) +
    one_of([1048576L, 1099511627776L, 2251799813685248L], state)
  } else {
    one_of(
      [
        9007199254740991L, 9007199254740992L, 9007199254740993L, 2147483648L,
        2147483647L, -1L,
      ],
      state,
    )
  }
  put_at(document, path, frame(new))
}

///|
/// Change one string: a schema, a track kind, a media key, or any name.
fn reword(document : Json, state : @splitmix.RandomState) -> Unit {
  let spots = nodes(document).filter(pair => is_text(pair.0) && pair.1.length() > 0)
  if spots.length() == 0 {
    return
  }
  let (value, path) = spots[among(spots.length(), state)]
  let old = text(value)
  let fresh = match under(path) {
    Some("OTIO_SCHEMA") =>
      any_of(
        ["Clip.1", "Clip.2", "Gap.1", "Transition.1", "Marker.2", "Track.1"],
        state,
      )
    Some("kind") => any_of(["Audio", "Video", "Transition", "video"], state)
    Some("target_url") =>
      any_of(
        [
          "file:///shoot/A.mov", "file:///shoot/B.mov", "file:///shoot/C.mov", "a", "",
          "file:///shoot/A.mov ", "file:///shoot/b.mov",
        ],
        state,
      )
    Some("active_media_reference_key") =>
      any_of(["original", "", "missing", "a b"], state)
    _ =>
      any_of(
        [
          "", "审阅 意见", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", "a#0", "entire-old#0", old + "#0", "😀",
          "\u{0}", old,
        ],
        state,
      )
  }
  put_at(document, path, Json(fresh))
}

///|
/// The lists a review is made of.
let lists : Array[String] = ["children", "markers", "notes", "selections"]

///|
/// Something of the list's own kind from elsewhere, so that the list still
/// reads as one after it is brought in.
fn donors(documents : Array[Json], kind : String) -> Array[Json] {
  let found = []
  for document in documents {
    for item in nodes(document) {
      let named = match under(item.1) {
        Some(key) => key == kind && item.1.length() > 0
        None => false
      }
      let of_the_kind = named &&
        is_object(item.0) &&
        (match kind {
          "notes" => member_of(item.0, "id") is Some(_)
          "selections" => member_of(item.0, "note_id") is Some(_)
          _ => member_of(item.0, "OTIO_SCHEMA") is Some(_)
        })
      if of_the_kind {
        found.push(copied(item.0))
      }
    }
  }
  found
}

///|
/// Delete, repeat, move, turn or bring in a child, a marker, an annotation
/// or a selection.
fn reshuffle(
  document : Json,
  documents : Array[Json],
  state : @splitmix.RandomState,
) -> Unit {
  let spots = nodes(document).filter(pair => {
    let named = match under(pair.1) {
      Some(key) => lists.contains(key)
      None => false
    }
    named && is_list(pair.0)
  })
  if spots.length() == 0 {
    return
  }
  let (value, path) = spots[among(spots.length(), state)]
  guard value is Array(items) else { return }
  let kind = under(path).unwrap()
  let count = items.length()
  let operation = among(7, state)
  if count == 0 && operation != 6 {
    return
  }
  let out : Array[Json] = []
  match operation {
    0 =>
      // One taken out.
      {
        let gone = among(count, state)
        for index = 0; index < count; index = index + 1 {
          if index != gone {
            out.push(items[index])
          }
        }
      }
    1 =>
      // One repeated, somewhere in the list.
      {
        let again = copied(items[among(count, state)])
        let place = among(count + 1, state)
        for index = 0; index <= count; index = index + 1 {
          if index == place {
            out.push(again)
          }
          if index < count {
            out.push(items[index])
          }
        }
      }
    2 if count > 1 =>
      // Two different places, swapped.
      {
        let i = among(count, state)
        let other = i + (if among(count - 1, state) >= i { 1 } else { 0 })
        for index = 0; index < count; index = index + 1 {
          out.push(
            if index == i {
              items[other]
            } else if index == other {
              items[i]
            } else {
              items[index]
            },
          )
        }
      }
    3 =>
      // The other way round.
      for index = count - 1; index >= 0; index = index - 1 {
        out.push(items[index])
      }
    4 =>
      // Turned round by some amount.
      {
        let turn = among(count, state)
        for index = 0; index < count; index = index + 1 {
          out.push(items[(index + turn) % count])
        }
      }
    5 =>
      // Shuffled by drawing each place once.
      {
        let left = []
        for index = 0; index < count; index = index + 1 {
          left.push(items[index])
        }
        while left.length() > 0 {
          let take = among(left.length(), state)
          out.push(left[take])
          ignore(left.remove(take))
        }
      }
    _ =>
      // Brought in from the same kind of list elsewhere.
      {
        let offered = donors(documents, kind)
        let place = among(count + 1, state)
        if offered.length() > 0 {
          let brought = copied(offered[among(offered.length(), state)])
          for index = 0; index <= count; index = index + 1 {
            if index == place {
              out.push(brought)
            }
            if index < count {
              out.push(items[index])
            }
          }
        } else {
          for index = 0; index < count; index = index + 1 {
            out.push(items[index])
          }
        }
      }
  }
  put_at(document, path, Json::array(out))
}

///|
/// The record an exported marker carries.
fn origin_record() -> Json {
  Json::object({
    "moon_reconform": Json::object({
      "note_id": Json("cut-frame"),
      "piece": Json(0),
      "media": Json("file:///shoot/B.mov"),
      "source": span(100L, 101L),
    }),
  })
}

///|
/// Take a key away from an object, or give it one it did not have.
fn rekey(document : Json, state : @splitmix.RandomState) -> Unit {
  let spots = nodes(document).filter(pair => is_object(pair.0) && pair.1.length() > 0)
  if spots.length() == 0 {
    return
  }
  let (value, _) = spots[among(spots.length(), state)]
  guard value is Object(fields) else { return }
  let keys = keys_of(fields)
  if keys.length() > 0 && draw(2, state) == 0 {
    fields.remove(keys[among(keys.length(), state)])
    return
  }
  let added = any_of(
    [
      "extra", "source", "media", "from_markers", "metadata", "enabled",
      "effects", "source_range",
    ],
    state,
  )
  fields[added] = match among(9, state) {
    0 => Json::null()
    1 => Json(1)
    2 => Json(0)
    3 => Json("x")
    4 => Json::array([])
    5 => Json::object(Map([]))
    6 => Json(true)
    7 => Json(false)
    _ => origin_record()
  }
}

///|
/// The ways to the children of a document's tracks that have some.
fn tracks(document : Json) -> Array[Array[Step]] {
  let found = []
  for item in nodes(document) {
    let is_track = is_object(item.0) &&
      member_of(item.0, "OTIO_SCHEMA") is Some(String("Track.1"))
    if is_track {
      match member_of(item.0, "children") {
        Some(Array(children)) if children.length() > 0 =>
          {
            let path = item.1.copy()
            path.push(Field("children"))
            found.push(path)
          }
        _ => ()
      }
    }
  }
  found
}

///|
/// A member's frame count, where it is one.
fn frame_in(value : Json, key : String) -> Int64? {
  match member_of(value, key) {
    Some(item) => frame_count(item)
    None => None
  }
}

///|
/// Edit one child of a track the way an editor would, keeping it what it
/// is: trim it, slip it, split it, swap it with its neighbour, turn it into
/// black, or let it run longer.
fn retime(document : Json, state : @splitmix.RandomState) -> Unit {
  let ways = tracks(document)
  if ways.length() == 0 {
    return
  }
  let children_path = ways[among(ways.length(), state)]
  guard node_at(document, children_path) is Array(children) else { return }
  let index = among(children.length(), state)
  let child_path = children_path.copy()
  child_path.push(At(index))
  let child = children[index]
  guard is_object(child) else { return }
  let span_path = child_path.copy()
  span_path.push(Field("source_range"))
  guard member_of(child, "source_range") is Some(span) else { return }
  guard member_of(span, "start_time") is Some(from) &&
    member_of(span, "duration") is Some(for_) else {
    return
  }
  let (start, length) = (frame_in(from, "value"), frame_in(for_, "value"))
  guard start is Some(from_frame) && length is Some(for_frames) else { return }
  let start_path = span_path.copy()
  start_path.push(Field("start_time"))
  start_path.push(Field("value"))
  let length_path = span_path.copy()
  length_path.push(Field("duration"))
  length_path.push(Field("value"))
  let is_gap = member_of(child, "OTIO_SCHEMA") is Some(String("Gap.1"))
  if is_gap {
    put_at(
      document,
      length_path,
      frame(if for_frames + one_of([-2L, -1L, 1L, 2L], state) < 1L {
        1L
      } else {
        for_frames + one_of([1L, 2L], state)
      }),
    )
    return
  }
  match among(7, state) {
    0 if for_frames > 1L =>
      // One frame off the head.
      {
        put_at(document, start_path, frame(from_frame + 1L))
        put_at(document, length_path, frame(for_frames - 1L))
      }
    1 if for_frames > 1L => put_at(document, length_path, frame(for_frames - 1L))
    2 =>
      put_at(
        document,
        start_path,
        frame(if from_frame + one_of([-2L, -1L, 1L, 2L, 7L, 100L], state) < 0L {
          0L
        } else {
          from_frame + one_of([1L, 2L, 7L, 100L], state)
        }),
      )
    3 if for_frames > 1L =>
      // Split in two, the second part starting where the first stopped.
      {
        let cut = 1L + among(for_frames.to_int() - 1, state).to_int64()
        put_at(document, length_path, frame(cut))
        let right_path = children_path.copy()
        right_path.push(At(index + 1))
        let right = copied(child)
        children.insert(index + 1, right)
        let right_start = right_path.copy()
        right_start.push(Field("source_range"))
        right_start.push(Field("start_time"))
        right_start.push(Field("value"))
        put_at(document, right_start, frame(from_frame + cut))
        let right_length = right_path.copy()
        right_length.push(Field("source_range"))
        right_length.push(Field("duration"))
        right_length.push(Field("value"))
        put_at(document, right_length, frame(for_frames - cut))
      }
    4 if children.length() > 1 =>
      // Swapped with its neighbour.
      {
        let other = (index + 1) % children.length()
        let held = children[index]
        children[index] = children[other]
        children[other] = held
      }
    5 => children[index] = black(for_frames)
    _ => put_at(document, length_path, frame(for_frames + one_of([1L, 2L, 5L], state)))
  }
}

///|
/// Values of every kind JSON has, for standing one where another was.
let others : Array[Json] = [
  Json::null(),
  Json(true),
  Json(false),
  Json::number(0.0),
  Json::number(1.0),
  Json::number(-1.0),
  Json::number(1.5),
  Json::number(1.0e300),
  Json(""),
  Json("x"),
  Json::array([]),
  Json::array([Json(1)]),
  Json::object(Map([])),
  Json::object({ "a": Json(1) }),
]

///|
/// Which kind of value a JSON value is.
fn sort_of(value : Json) -> Int {
  match value {
    Null => 0
    True | False => 1
    Number(_) => 2
    String(_) => 3
    Array(_) => 4
    Object(_) => 5
  }
}

///|
/// Stand a different kind of value where one was: a number for a string,
/// an array for an object, nothing at all.
fn retype(document : Json, state : @splitmix.RandomState) -> Unit {
  let spots = nodes(document).filter(pair => pair.1.length() > 0)
  if spots.length() == 0 {
    return
  }
  let (value, path) = spots[among(spots.length(), state)]
  let unlike = others.filter(one => sort_of(one) != sort_of(value))
  put_at(document, path, copied(unlike[among(unlike.length(), state)]))
}

///|
/// A review's three documents, changed the way a fuzzer changes them: a
/// nudge to a frame count, a name altered, a child dropped or repeated, a
/// member taken or added, a clip edited as an editor would, or a value of
/// another kind put where one was.
pub fn mangled(number : UInt64) -> Array[Json] {
  let state = @splitmix.RandomState::RandomState(seed=number)
  let case = sample(number ^ 11400714819323198485UL, size=12)
  let (old, _, fresh, _, _, _, asked) = build(case)
  let documents = [copied(old), copied(fresh), asked]
  let rounds = one_of([1L, 1L, 2L, 3L], state).to_int()
  for index = 0; index < rounds; index = index + 1 {
    let document = documents[among(3, state)]
    match among(19, state) {
      i if i < 4 => renumber(document, state)
      i if i < 6 => reword(document, state)
      i if i < 9 => reshuffle(document, documents, state)
      i if i < 10 => rekey(document, state)
      i if i < 16 => retime(document, state)
      _ => retype(document, state)
    }
  }
  documents
}

///|
/// A real cut, or a real request, with one part of it replaced by
/// anything at all. Only the tests name this function, so the compiler
/// cannot see it used.
#warnings("-unused_value")
fn grafted(number : UInt64, asked~ : Bool = false) -> Json {
  let state = @splitmix.RandomState::RandomState(seed=number)
  let case = sample(number ^ 11400714819323198485UL, size=12)
  let (old, _, _, _, _, _, request) = build(case)
  let document = copied(if asked { request } else { old })
  let spots = nodes(document).filter(pair => pair.1.length() > 0)
  put_at(document, spots[among(spots.length(), state)].1, anything(3, state))
  document
}

///|
/// The words a document about a timeline is written in, and a few that
/// have nothing to do with one.
let vocabulary : Array[String] = [
  "OTIO_SCHEMA", "Timeline.1", "tracks", "children", "Track.1", "kind",
  "Video", "Audio", "Clip.1", "Clip.2", "Gap.1", "Transition.1", "Stack.1",
  "Marker.2", "source_range", "start_time", "duration", "value", "rate",
  "media_reference", "media_references", "original", "ExternalReference.1",
  "target_url", "available_range", "metadata", "moon_reconform", "note_id",
  "piece", "media", "source", "start", "stop", "fps", "old_track",
  "new_track", "notes", "selections", "from_markers", "id", "text",
  "marked_range", "in_offset", "out_offset", "enabled", "effects", "markers",
  "name", "comment", "color", "a", "", "审阅", "x", "file:///shoot/A.mov",
]

///|
/// Numbers of every awkward size, as a document might hold them.
let figures : Array[Json] = [
  Json::number(0.0),
  Json::number(1.0),
  Json::number(-1.0),
  Json::number(24.0),
  Json::number(29.97),
  Json::number(0.5),
  Json::number(1.0e300),
  Json::number(-0.0),
  Json(2147483647),
  Json::number(2147483648.0),
  frame(9007199254740991L),
  frame(9007199254740992L),
  frame(9007199254740993L),
]

///|
/// A document that is anything at all: the names a timeline is written in,
/// put together any old how, with values of every kind JSON has.
pub fn anything(depth : Int, state : @splitmix.RandomState) -> Json {
  match draw(if depth <= 0 { 5 } else { 9 }, state) {
    0 => Json::null()
    1 => Json(draw(2, state) == 0)
    2 => figures[among(figures.length(), state)]
    3 => Json(any_of(vocabulary, state))
    4 =>
      Json::number((draw(40, state) - 20).to_double() + 0.5)
    5 | 6 =>
      // An array of up to three of anything one step less deep.
      {
        let out = []
        let count = among(4, state)
        for index = 0; index < count; index = index + 1 {
          out.push(anything(depth - 1, state))
        }
        Json::array(out)
      }
    _ =>
      // An object of up to four members, under the names a timeline uses.
      {
        let fields : Map[String, Json] = Map([])
        let count = among(5, state)
        for index = 0; index < count; index = index + 1 {
          fields[any_of(vocabulary, state)] = anything(depth - 1, state)
        }
        Json::object(fields)
      }
  }
}

///|
/// The three documents of a review, each on its own line.
pub fn shown_documents(documents : Array[Json]) -> String {
  let names = ["old", "new", "request"]
  let lines = []
  for index, document in documents {
    lines.push(names[index] + ": " + document.stringify())
  }
  lines.join("\n")
}
