///|
/// A seed for the fuzzer's own drawing, as QuickCheck hands it out: two
/// small numbers, so that no draw of the seed is favoured.
#derive(Eq, Debug)
pub(all) struct Seeded {
  first : Int32
  second : Int32
}

///|
impl @quickcheck.Arbitrary for Seeded with fn arbitrary(_size, r0) {
  { first: draw(65536, r0), second: draw(65536, r0) }
}

///|
/// No call names this implementation: it is what lets `check` shrink a
/// seed that fails, so the compiler cannot see it used.
#warnings("-unused_value")
impl @quickcheck.Shrink for Seeded with fn shrink(self) -> Iter[Seeded] {
  [| |]
}

///|
fn Seeded::number(self : Seeded) -> UInt64 {
  (self.first.to_int64() * 65536L + self.second.to_int64()).reinterpret_as_uint64()
}

///|
/// Whether the tool refused: in the words of a rule, or in some other way
/// that a person at a terminal would not know what to do with. Any other
/// error is reported, since it is what the fuzzer is looking for.
fn refused(ask : () -> Unit raise) -> Bool raise {
  try {
    ask()
    false
  } catch {
    @tool.Invalid(_) | @tool.Limit(_) => true
    other => fail("not a refusal in so many words: " + words(other))
  }
}

///|
test "a document that is changed as a fuzzer changes one is refused in so many words, or answered as the oracle says" {
  let answered = [0]
  let refusals = [0]
  @quickcheck.check(
    (seeded : Seeded) => {
      let documents = mangled(seeded.number())
      let outcome = refused(() => checked(documents[0], documents[1], documents[2]))
      if outcome {
        refusals[0] = refusals[0] + 1
      } else {
        answered[0] = answered[0] + 1
      }
      true
    },
    count=4000,
    max_size=12,
    max_shrinks=100,
    seed=31415,
    counterexample_context=seeded => {
      "seed " +
      seeded.number().to_string() +
      "\n" +
      shown_documents(mangled(seeded.number()))
    },
  )
  // Both have to happen, and often: a fuzzer whose every change is
  // refused before the tool reads a frame has found out very little.
  assert_true(answered[0] >= 500)
  assert_true(refusals[0] >= 500)
  println(
    "changed reviews: \{answered[0]} answered as the oracle says, \{refusals[0]} refused",
  )
}

///|
///|
/// Offer a document to the ways in named by `steps`, and count what came
/// of each: a read that went through, or a refusal in so many words. A
/// crash is what is looked for; it stops the run.
fn offered(
  document : Json,
  index : Int,
  fps : Int,
  steps : Array[Int],
  read : Array[Int],
  refusals : Array[Int],
) -> Unit {
  for step in steps {
    try {
      match step {
        0 => ignore(@tool.read_otio(document, track_index=index, fps=fps))
        1 => ignore(@tool.read_request(document))
        2 =>
          ignore(
            @tool.read_notes_from_markers(document, track_index=index, fps=fps),
          )
        _ =>
          ignore(
            @tool.with_markers(
              document,
              track_index=index,
              fps=fps,
              @tool.Resolution::{ transfers: [], held: [] },
            ),
          )
      }
      read[step] = read[step] + 1
    } catch {
      // The core raises nothing but its own refusals, as its types say.
      @tool.Invalid(_) | @tool.Limit(_) => refusals[step] = refusals[step] + 1
    }
  }
}

///|
let entrances : Array[String] = [
  "read_otio", "read_request", "read_notes_from_markers", "with_markers",
]

///|
test "a document that is anything at all is read or refused in so many words, never crashed" {
  let read = [0, 0, 0, 0]
  let refusals = [0, 0, 0, 0]
  let kept = [0, 0, 0, 0]
  let kept_refusals = [0, 0, 0, 0]
  @quickcheck.check(
    (seeded : Seeded) => {
      let state = @splitmix.RandomState::RandomState(seed=seeded.number())
      let anything_at_all = anything(4, state)
      let index = one_of([-1L, 0L, 1L, 2L], state).to_int()
      let fps = one_of([0L, 1L, 24L, 240L, 241L], state).to_int()
      offered(anything_at_all, index, fps, [0, 1, 2, 3], read, refusals)
      offered(grafted(seeded.number()), 0, 24, [0, 2, 3], kept, kept_refusals)
      offered(grafted(seeded.number(), asked=true), 0, 24, [1], kept, kept_refusals)
      true
    },
    count=3000,
    max_size=8,
    max_shrinks=100,
    seed=27182,
    counterexample_context=seeded => {
      let state = @splitmix.RandomState::RandomState(seed=seeded.number())
      "seed " +
      seeded.number().to_string() +
      "\nanything at all: " +
      anything(4, state).stringify() +
      "\na cut with a grafted part: " +
      grafted(seeded.number()).stringify() +
      "\na request with a grafted part: " +
      grafted(seeded.number(), asked=true).stringify()
    },
  )
  for step = 0; step < 4; step = step + 1 {
    println(
      "anything at all to \{entrances[step]}: \{read[step]} read, \{refusals[step]} refused; with a part replaced by anything at all: \{kept[step]} read, \{kept_refusals[step]} refused",
    )
  }
  // Anything at all is always refused, as it should be: nothing that was
  // not put together as a document reads as one. A real document with one
  // part replaced still reads often, which is what takes the reading past
  // its first checks and into what follows a success. A request has more
  // ways to be wrong than a cut has, so fewer of them still read.
  assert_eq(read, [0, 0, 0, 0])
  let least = [300, 100, 300, 300]
  for step in [0, 1, 2, 3] {
    assert_true(kept[step] >= least[step])
    assert_true(kept_refusals[step] >= 300)
  }
}