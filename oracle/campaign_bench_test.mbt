///|
///|
/// The benchmarks are black-box: the oracle and the tool are driven as a
/// campaign drives them. Setup is kept out of what is measured. Run them
/// with `moon bench oracle`.

///|
fn ignored(review : @oracle.Case) -> Unit {
  try {
    ignore(@oracle.verify(review))
  } catch {
    _ => ()
  }
}

///|
test "one review through the tool and the oracle" (b : @bench.T) {
  let review = @oracle.sample(1729, size=12)
  b.bench(fn() { ignored(review) })
}

///|
test "a cut of 20,000 children read from its document" (b : @bench.T) {
  let children = []
  for k = 0; k < 20000; k = k + 1 {
    children.push(
      @oracle.child_of(@oracle.Child::{
        kind: 5,
        start: k & 31,
        length: k % 7 + 1,
        media: k & 3,
        entering: 0,
      }).unwrap(),
    )
  }
  let document = @oracle.sequence(@oracle.plain_track(children), None)
  b.bench(fn() {
    try {
      ignore(@tool.read_otio(document, track_index=0, fps=@tool.Rate::whole(24)))
    } catch {
      _ => ()
    }
  })
}

///|
test "a thousand annotations planned against 20,000 children" (b : @bench.T) {
  let children = []
  for k = 0; k < 20000; k = k + 1 {
    children.push(
      @oracle.child_of(@oracle.Child::{
        kind: 5,
        start: k & 31,
        length: k % 7 + 1,
        media: k & 3,
        entering: 0,
      }).unwrap(),
    )
  }
  let document = @oracle.sequence(@oracle.plain_track(children), None)
  let cut = @tool.read_otio(document, track_index=0, fps=@tool.Rate::whole(24))
  let notes = []
  for k = 0; k < 1000; k = k + 1 {
    notes.push(
      @tool.Note::{
        id: "n" + k.to_string(),
        text: "审阅",
        range: { start: k.to_int64() * 7L, stop: k.to_int64() * 7L + 3L },
        media: None,
        origin: None,
      },
    )
  }
  b.bench(fn() {
    try {
      ignore(@tool.plan(cut, cut, notes))
    } catch {
      _ => ()
    }
  })
}
