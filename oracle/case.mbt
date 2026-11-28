///|
/// One generated cut: a first track, a second of the other kind where the
/// first bit of `layer` is set, and in the other bits which of them a
/// request selects and whether the first is for sound.
#derive(Eq, Debug)
pub(all) struct Cut {
  first : Array[Child]
  second : Array[Child]
  layer : Int32
}

///|
/// One annotation as small numbers. `span` is how long it runs, and zero
/// leaves it out. A negative `media` anchors it to the old track at `at`;
/// zero or more anchors it to that footage, from its frame `at`.
#derive(Eq, Debug)
pub(all) struct Mark {
  at : Int32
  span : Int32
  media : Int32
}

///|
/// A whole review as small numbers: the old cut, the new cut and the one
/// after it, the annotations, a pick for every ambiguous piece taken in
/// order, and, in the bits of `switches`: an editor's own marker on the
/// third cut, no choices in the first round, no choices in the second, text
/// with quotes, a newline and a tab in it, footage lying near the last
/// frame a document can write, tracks that begin with black far past what
/// a 32-bit cut could hold, and a review at 29.97 rather than at 24.
#derive(Eq, Debug)
pub(all) struct Case {
  cuts : Array[Cut]
  marks : Array[Mark]
  picks : Array[Int32]
  switches : Int32
}

///|
/// A small number drawn evenly from `0` up to `below`, not counting it.
fn draw(below : UInt32, state : @splitmix.RandomState) -> Int32 {
  state.next_uint(limit=below).reinterpret_as_int()
}

///|
/// Between none and eight children, drawn one after another. The built-in
/// generator for arrays comes out empty far more often than not, and a
/// review of empty tracks proves very little.
fn children_of(size : Int32, state : @splitmix.RandomState) -> Array[Child] {
  let out = []
  let count = draw(9, state)
  for index = 0; index < count; index = index + 1 {
    out.push(@quickcheck.Arbitrary::arbitrary(size, state))
  }
  out
}

///|
/// One generated cut, drawn from the state.
fn cut_of(size : Int32, state : @splitmix.RandomState) -> Cut {
  let first = children_of(size, state)
  let second = children_of(size, state)
  { first, second, layer: draw(8, state) }
}

///|
/// The same child two frames along its footage, or one frame longer or
/// shorter, or as it was.
fn nudged(child : Child, state : @splitmix.RandomState) -> Child {
  let start = match draw(3, state) {
    0 => child.start + 2
    1 => if child.start < 2 { 0 } else { child.start - 2 }
    _ => child.start
  }
  let length = match draw(3, state) {
    0 => child.length + 1
    1 => child.length - 1
    _ => child.length
  }
  {
    kind: child.kind,
    start,
    length: if length < 0 { 0 } else { length },
    media: child.media,
    entering: child.entering,
  }
}

///|
/// An annotation on footage the new cut has, so that finding footage is
/// as common in a review as losing it. Where the cut has none, the
/// annotation is drawn as any other.
fn mark_on(
  size : Int32,
  state : @splitmix.RandomState,
  fresh : Cut,
) -> Mark {
  let there = []
  for child in fresh.first {
    if (child.length & 7) != 0 && (child.kind & 7) != 0 && (child.kind & 7) != 2 &&
      (child.kind & 7) != 3 &&
      (child.kind & 7) != 4 {
      there.push(child)
    }
  }
  if there.length() == 0 {
    return @quickcheck.Arbitrary::arbitrary(size, state)
  }
  let child = there[(draw(1024, state) % there.length()).to_int()]
  {
    at: child.start,
    span: draw(7, state) + 1,
    media: child.media & 3,
  }
}

///|
/// The next cut an editor might make of this one: children dropped,
/// repeated, nudged along their footage or left as they were, then the
/// whole track turned round by a random amount. Footage therefore carries
/// over from one cut to the next, whole or in part, and now and then
/// twice.
fn recut(
  of : Cut,
  size : Int32,
  state : @splitmix.RandomState,
) -> Cut {
  let kept = []
  for child in of.first {
    match draw(8, state) {
      0 => ()
      1 =>
        for copy = 0; copy < 2; copy = copy + 1 {
          kept.push(nudged(child, state))
        }
      2 | 3 => kept.push(nudged(child, state))
      _ => kept.push(child)
    }
  }
  let first = []
  let turn = draw(8, state)
  for index = 0; index < kept.length(); index = index + 1 {
    first.push(kept[(index + turn) % kept.length()])
  }
  let second = children_of(size, state)
  { first, second, layer: draw(8, state) }
}

///|
/// Every child on a track is one of these, each as often as the others:
/// black, footage, a clip with no footage of its own, a transition, and a
/// nested sequence, with footage twice as often as any other.
const KINDS : UInt32 = 8

///|
impl @quickcheck.Arbitrary for Child with fn arbitrary(_size, r0) {
  // The built-in integer generator favours zero, one and the extremes,
  // which after a mask is nearly all black. Small even numbers are drawn
  // from the state instead, so that footage, black and the rest each get
  // their share and the grids stay small enough for edges to meet.
  {
    kind: draw(KINDS, r0),
    start: draw(16, r0) * 2,
    length: draw(8, r0),
    media: draw(4, r0),
    entering: draw(8, r0),
  }
}

///|
impl @quickcheck.Shrink for Child with fn shrink(self) {
  @quickcheck.Shrink::shrink((
    self.kind,
    self.start,
    self.length,
    self.media,
    self.entering,
  )).map(t => {
    kind: t.0,
    start: t.1,
    length: t.2,
    media: t.3,
    entering: t.4,
  })
}

///|
/// Drawn only through the properties, which the compiler cannot see.
#warnings("-unused_value")
impl @quickcheck.Arbitrary for Cut with fn arbitrary(size, r0) {
  cut_of(size, r0)
}

///|
impl @quickcheck.Shrink for Cut with fn shrink(self) {
  @quickcheck.Shrink::shrink((self.first, self.second, self.layer)).map(t => {
    first: t.0,
    second: t.1,
    layer: t.2,
  })
}

///|
impl @quickcheck.Arbitrary for Mark with fn arbitrary(_size, r0) {
  // Anchored to the old track or to footage, half and half, on the same
  // grids as the children; a span of zero leaves the annotation out.
  {
    at: draw(16, r0) * 2,
    span: draw(8, r0),
    media: if draw(2, r0) == 0 { -1 } else { draw(4, r0) },
  }
}

///|
impl @quickcheck.Shrink for Mark with fn shrink(self) {
  @quickcheck.Shrink::shrink((self.at, self.span, self.media)).map(t => {
    at: t.0,
    span: t.1,
    media: t.2,
  })
}

///|
impl @quickcheck.Arbitrary for Case with fn arbitrary(size, r0) {
  // The old cut, then two re-cuts of it; up to six annotations; a pick
  // for each of up to eight ambiguous pieces.
  let old = cut_of(size, r0)
  let fresh = recut(old, size, r0)
  let third = recut(fresh, size, r0)
  let marks = []
  let noted = draw(7, r0)
  for index = 0; index < noted; index = index + 1 {
    if draw(2, r0) == 0 {
      marks.push(mark_on(size, r0, fresh))
    } else {
      marks.push(@quickcheck.Arbitrary::arbitrary(size, r0))
    }
  }
  let picks = []
  let chosen = draw(8, r0)
  for index = 0; index < chosen; index = index + 1 {
    picks.push(draw(4, r0))
  }
  {
    cuts: [old, fresh, third],
    marks,
    picks,
    switches: draw(256, r0),
  }
}

///|
/// No call names this implementation: it is what lets `check` shrink a
/// review that fails, so the compiler cannot see it used.
#warnings("-unused_value")
impl @quickcheck.Shrink for Case with fn shrink(self) {
  @quickcheck.Shrink::shrink((
    self.cuts,
    self.marks,
    self.picks,
    self.switches,
  )).map(t => {
    cuts: t.0,
    marks: t.1,
    picks: t.2,
    switches: t.3,
  })
}

///|
///|
/// The case a seed stands for. The generator draws whole numbers only, so
/// a seed means the same review on every backend.
pub fn sample(seed : UInt64, size~ : Int32 = 12) -> Case {
  @quickcheck.Arbitrary::arbitrary(
    size,
    @splitmix.RandomState::RandomState(seed=seed),
  )
}

///|
/// A cut by its place in the review, or an empty one.
fn cut_at(case : Case, index : Int32) -> Cut {
  guard case.cuts.get(index) is Some(cut) else {
    return { first: [], second: [], layer: 0 }
  }
  cut
}

///|
/// The document for a cut, and the track in it that a request selects.
fn document_of(
  cut : Cut,
  far~ : Int64 = 0L,
  lead~ : Int64 = 0L,
  rate~ : @tool.Rate = @tool.Rate::whole(24),
) -> (Json, Int32) {
  let two = (cut.layer & 1) == 1
  let sound = (cut.layer & 4) == 4
  let selected = if two && (cut.layer & 2) == 2 { 1 } else { 0 }
  let other = if two {
    Some(track_of(cut.second, !sound, [], far~, lead~, rate~))
  } else {
    None
  }
  (
    sequence(track_of(cut.first, sound, [], far~, lead~, rate~), other, rate~),
    selected,
  )
}

///|
fn text_of(case : Case, index : Int32) -> String {
  if (case.switches & 8) == 8 {
    "审阅 " + index.to_string() + " \"引号\"\n换行\t😀"
  } else {
    "审阅 " + index.to_string()
  }
}

///|
/// The request for a round, as the reviewer would write it.
fn request(
  old_track : Int32,
  new_track : Int32,
  notes : Array[Json],
  selections : Array[Json],
  from_markers : Bool,
  rate~ : @tool.Rate = @tool.Rate::whole(24),
) -> Json {
  Json::object({
    "fps": Json::number(rate.value, repr=rate.token),
    "old_track": Json(old_track),
    "new_track": Json(new_track),
    "notes": Json::array(notes),
    "selections": Json::array(selections),
    "from_markers": Json(from_markers),
  })
}

///|
/// Where footage lies in a review whose switch for it is set: 256 frames
/// below two to the fifty-third. Every frame of it can still be named, at
/// the very edge of what a document can write and far past what a 32-bit
/// cut could hold. The tracks stay short; only the footage is far away.
pub let far_away : Int64 = 9007199254740736L

///|
/// The black a track begins with where the review's switch for it is set:
/// two to the thirty-third and five frames, so that every child of the
/// track lies past what a 32-bit cut could hold. The children are as short
/// as ever; only their places on the track are far away.
pub let long_lead : Int64 = 8589934597L

///|
/// The offset every piece of footage is moved by in this review.
fn offset_of(case : Case) -> Int64 {
  if (case.switches & 32) == 32 { far_away } else { 0L }
}

///|
/// The black each track begins with in this review.
fn lead_of(case : Case) -> Int64 {
  if (case.switches & 64) == 64 { long_lead } else { 0L }
}

///|
/// The frame rate this review is at: whole 24, or 29.97 where the review's
/// switch for it is set.
pub fn rate_of(case : Case) -> @tool.Rate {
  if (case.switches & 128) == 128 {
    { value: 29.97, token: "29.97" }
  } else {
    @tool.Rate::whole(24)
  }
}

fn build(case : Case) -> (Json, Int32, Json, Int32, Json, Int32, Json) {
  let far = offset_of(case)
  let lead = lead_of(case)
  let rate = rate_of(case)
  let (old, old_track) = document_of(cut_at(case, 0), far~, lead~, rate~)
  let (fresh, new_track) = document_of(cut_at(case, 1), far~, lead~, rate~)
  let (third, third_track) = document_of(cut_at(case, 2), far~, lead~, rate~)
  let old_length = duration_of(slots(old, old_track))
  let notes = []
  for i, mark in case.marks {
    let length = (mark.span & 7).to_int64()
    if length == 0L {
      continue
    }
    let id = "n" + i.to_string()
    let at = (mark.at & 31).to_int64()
    if mark.media < 0 {
      // Anchored to the old track, inside it or left out.
      // Counted from where the children begin, past the black.
      if at + lead < old_length {
        let stop = if at + length + lead < old_length {
          at + length
        } else {
          old_length - lead
        }
        notes.push(
          Json::object({
            "id": Json(id),
            "text": Json(text_of(case, i)),
            "start": frame(at + lead),
            "stop": frame(stop + lead),
          }),
        )
      }
    } else {
      notes.push(
        Json::object({
          "id": Json(id),
          "text": Json(text_of(case, i)),
          "media": Json(media_keys[(mark.media & 3).to_int()]),
          "source": span(at + far, at + far + length),
        }),
      )
    }
  }
  (
    old,
    old_track,
    fresh,
    new_track,
    third,
    third_track,
    request(old_track, new_track, notes, [], false, rate~),
  )
}

///|
/// A review in words, for when one fails.
pub fn render(case : Case) -> String {
  fn line(label : String, cut : Cut) -> String {
    let (document, selected) = document_of(cut)
    let laid = slots(document, selected)
    let parts = []
    for slot in laid {
      let what = match (slot.media, slot.why) {
        (Some(key), _) =>
          "{\"media\":\"" +
          key +
          "\",\"source\":{\"start\":" +
          slot.first.unwrap().to_string() +
          ",\"stop\":" +
          (slot.first.unwrap() + slot.stop - slot.from).to_string() +
          "}}"
        (None, Some(why)) => why
        (None, None) => "black"
      }
      parts.push(
        what + "@" + slot.from.to_string() + "+" +
        (slot.stop - slot.from).to_string(),
      )
    }
    label +
      (if (cut.layer & 1) == 1 { " two tracks," } else { " one track," }) +
      " track " +
      selected.to_string() +
      ": " +
      parts.join(" | ")
  }

  let marks = []
  for i, mark in case.marks {
    marks.push(
      "n" + i.to_string() +
      (if mark.media < 0 { " track " } else { " footage " + (mark.media & 3).to_string() + " " }) +
      "at " +
      (mark.at & 31).to_string() +
      " for " +
      (mark.span & 7).to_string(),
    )
  }
  "old: " +
  line("", cut_at(case, 0)) +
  "\nnew: " +
  line("", cut_at(case, 1)) +
  "\nthird: " +
  line("", cut_at(case, 2)) +
  "\nnotes: " +
  marks.join("; ") +
  "\npicks: " +
  case.picks.map(pick => pick.to_string()).join(",") +
  " switches " +
  case.switches.to_string() +
  (if lead_of(case) == 0L { "" } else { " after " + lead_of(case).to_string() + " frames of black" })
}
