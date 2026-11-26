///|
/// A whole number written in plain digits, or None for anything else.
/// Command lines differ in what they carry besides the arguments, so only
/// runs of digits are taken as numbers, in the order written.
fn plain_digits(text : String) -> Int64? {
  if text.length() == 0 {
    return None
  }
  let mut value = 0L
  for digit in text {
    if digit < '0' || digit > '9' {
      return None
    }
    if value > 900719925474099L {
      return None
    }
    value = value * 10L + (digit.to_int() - '0'.to_int()).to_int64()
  }
  Some(value)
}

///|
/// What a campaign runs over: the reviews the generator draws, or reviews
/// a fuzzer changes.
priv enum Mode {
  Reviews
  Mutations
}

///|
/// Run the oracle over reviews in bulk, in one process, on whatever backend
/// this was built for. Every review is one seed's, so a failure names its
/// seed and the same seed replays it.
///
///     moon run cmd/campaign --target native -- 1000000 1 12
///     moon run cmd/campaign --target native -- mutate 1000000 1
///
/// The numbers are how many reviews, the first seed, and how large a review
/// may grow; left out, they are two hundred thousand, one and twelve. The
/// word `mutate` runs reviews a fuzzer changed instead, where the third
/// number does not apply.
fn main {
  let asked = [200000L, 1L, 12L]
  let mut found = 0
  let mut mode = Reviews
  for argument in @env.args() {
    if argument == "mutate" {
      mode = Mutations
    }
    match plain_digits(argument) {
      Some(value) =>
        if found < 3 {
          asked[found] = value
          found += 1
        }
      None => ()
    }
  }
  let count = asked[0]
  let first = asked[1]
  match mode {
    Reviews => reviews(first, count, asked[2].to_int())
    Mutations => mutations(first, count)
  }
}

///|
/// Generated reviews, each held whole to the oracle.
fn reviews(first : Int64, count : Int64, size : Int) -> Unit {
  let began = @env.now()
  let mut tally = @oracle.empty
  let mut failures = 0L
  for seed = first; seed < first + count; seed = seed + 1L {
    let review = @oracle.sample(seed.reinterpret_as_uint64(), size=size)
    try {
      tally = tally.add(@oracle.verify(review))
    } catch {
      error => {
        failures += 1L
        println("seed " + seed.to_string() + ": " + @oracle.words(error))
        println(@oracle.render(review))
      }
    }
  }
  let took = (@env.now() - began).reinterpret_as_int64()
  println(
    "campaign on " +
    target() +
    ": " +
    count.to_string() +
    " reviews from seed " +
    first.to_string() +
    " of size up to " +
    size.to_string() +
    " in " +
    took.to_string() +
    " ms; " +
    @debug.to_string(tally).replace(old=" Tally", new="") +
    "; failures " +
    failures.to_string(),
  )
  if failures > 0L {
    @env.exit(1)
  }
}

///|
/// Reviews a fuzzer changed, each its seed's: refused in so many words, or
/// answered exactly as the oracle says. Anything else is a failure, and
/// names its seed and its documents.
fn mutations(first : Int64, count : Int64) -> Unit {
  let began = @env.now()
  let mut answered = 0L
  let mut refused = 0L
  let mut failures = 0L
  for seed = first; seed < first + count; seed = seed + 1L {
    let documents = @oracle.mangled(seed.reinterpret_as_uint64())
    try {
      @oracle.checked(documents[0], documents[1], documents[2])
      answered += 1L
    } catch {
      @core.Invalid(_) | @core.Limit(_) => refused += 1L
      error => {
        failures += 1L
        println("seed " + seed.to_string() + ": " + @oracle.words(error))
        println(@oracle.shown_documents(documents))
      }
    }
  }
  let took = (@env.now() - began).reinterpret_as_int64()
  println(
    "mutations on " +
    target() +
    ": " +
    count.to_string() +
    " changed reviews from seed " +
    first.to_string() +
    " in " +
    took.to_string() +
    " ms; " +
    answered.to_string() +
    " answered as the oracle says, " +
    refused.to_string() +
    " refused; failures " +
    failures.to_string(),
  )
  if failures > 0L {
    @env.exit(1)
  }
}
