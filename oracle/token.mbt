///|
/// The last frame a count can name. Every whole number up to here is a
/// double exactly; nothing above it is.
let top : @bigint.BigInt = @bigint.BigInt::from_int64(9007199254740991L)

///|
let ten : @bigint.BigInt = @bigint.BigInt::from_int64(10L)

///|
let zero : @bigint.BigInt = @bigint.BigInt::from_int64(0L)

///|
/// A JSON number taken apart: every digit of its mantissa with the point
/// left out, how many of them followed the point, and its exponent.
priv struct Parts {
  negative : Bool
  digits : String
  places : Int64
  exponent : Int64
}

///|
fn digit_of(char : Char) -> Bool {
  char >= '0' && char <= '9'
}

///|
/// Take a number apart as JSON writes it, or None where it is not written
/// as one: a leading zero before another digit, a bare point, a bare
/// exponent or a leftover character all count as not one.
fn parts_of(token : String) -> Parts? {
  let signs = token.to_array()
  let mut at = 0
  let mut negative = false
  if at < signs.length() && signs[at] == '-' {
    negative = true
    at += 1
  }
  let first_digit = at
  while at < signs.length() && digit_of(signs[at]) {
    at += 1
  }
  if at == first_digit || (at - first_digit > 1 && signs[first_digit] == '0') {
    return None
  }
  let mut digits = ""
  let mut places = 0L
  for index = first_digit; index < at; index = index + 1 {
    digits = digits + signs[index].to_string()
  }
  if at < signs.length() && signs[at] == '.' {
    at += 1
    let first_place = at
    while at < signs.length() && digit_of(signs[at]) {
      digits = digits + signs[at].to_string()
      places += 1L
      at += 1
    }
    if at == first_place {
      return None
    }
  }
  let mut exponent = 0L
  if at < signs.length() && (signs[at] == 'e' || signs[at] == 'E') {
    at += 1
    let mut below = false
    if at < signs.length() && (signs[at] == '+' || signs[at] == '-') {
      below = signs[at] == '-'
      at += 1
    }
    let first_power = at
    while at < signs.length() && digit_of(signs[at]) {
      // No exponent above nine digits needs its exact size: every such
      // number is far past the last frame, or far from a whole one.
      if exponent < 100000000000000L {
        exponent = exponent * 10L + (signs[at].to_int() - '0'.to_int()).to_int64()
      }
      at += 1
    }
    if at == first_power {
      return None
    }
    if below {
      exponent = -exponent
    }
  }
  if at != signs.length() {
    return None
  }
  Some({ negative, digits, places, exponent })
}

///|
/// What a frame count has to mean, judged with exact integers and nothing
/// of the tool's: `Some(frame)` where the number is a whole number of
/// frames from 0 to the last one, `None` where it is a fraction, negative,
/// or past the last frame. The digits are taken as they are written, so a
/// number that only looks whole after rounding is not whole.
pub fn judged(token : String) -> Int64? {
  let parts = match parts_of(token) {
    Some(found) => found
    None => return None
  }
  let parsed = Ok(@string.parse_bigint(parts.digits)) catch { error => Err(error) }
  let number = match parsed {
    Ok(found) => found
    Err(_) => return None
  }
  if number.is_zero() {
    return Some(0L)
  }
  if parts.negative {
    return None
  }
  let shift = @bigint.BigInt::from_int64(parts.exponent - parts.places)
  let value = if shift.compare_int64(0L) >= 0 {
    // The point moves right: the number of digits only grows. Seventeen
    // digits is already past the last frame, however small they are.
    let size = number.to_string().length().to_int64()
    if shift.compare_int64(16L) > 0 || size + shift.to_int64() > 16L {
      return None
    }
    number * ten.pow(shift)
  } else {
    // The point moves left: only trailing zeros can absorb the places.
    let back = shift.neg()
    if back.compare_int64(number.to_string().length().to_int64()) > 0 {
      return None
    }
    let divisor = ten.pow(back)
    if (number % divisor) != zero {
      return None
    }
    number / divisor
  }
  if value.compare(top) > 0 {
    return None
  }
  Some(value.to_int64())
}

///|
/// A number as a document might write it, as small numbers: digits of the
/// mantissa and of the fraction, and in the bits of `sign` a minus, a
/// fraction, an exponent and a plus before the exponent's digits.
#derive(Eq, Debug)
pub(all) struct Token {
  sign : Int32
  whole : Array[Int32]
  fraction : Array[Int32]
  power : Array[Int32]
}

///|
/// No call names these two implementations: they are what let `check`
/// draw numbers and shrink one that fails, so the compiler cannot see them
/// used.
#warnings("-unused_value")
impl @quickcheck.Arbitrary for Token with fn arbitrary(size, r0) {
  let r1 = r0.split()
  let r2 = r0.split()
  let r3 = r0.split()
  {
    sign: @quickcheck.Arbitrary::arbitrary(size, r0),
    whole: @quickcheck.Arbitrary::arbitrary(size, r1),
    fraction: @quickcheck.Arbitrary::arbitrary(size, r2),
    power: @quickcheck.Arbitrary::arbitrary(size, r3),
  }
}

///|
#warnings("-unused_value")
impl @quickcheck.Shrink for Token with fn shrink(self) {
  @quickcheck.Shrink::shrink((
    self.sign,
    self.whole,
    self.fraction,
    self.power,
  )).map(t => {
    sign: t.0,
    whole: t.1,
    fraction: t.2,
    power: t.3,
  })
}

///|
/// Every digit, leading zeros kept.
fn every_digit(values : Array[Int32]) -> String {
  let out = []
  for value in values {
    out.push((value & 9).to_string())
  }
  out.join("")
}

///|
/// The digits before the point, without a leading zero before another
/// digit, and as "0" where they are all zero.
fn whole_digits(values : Array[Int32]) -> String {
  let mut out = ""
  for value in values {
    let digit = (value & 9).to_string()
    if out == "" && digit == "0" {
      continue
    }
    out = out + digit
  }
  if out == "" { "0" } else { out }
}

///|
/// The number as text, written the way JSON allows and no other way.
pub fn written(raw : Token) -> String {
  let minus = if (raw.sign & 1) == 1 { "-" } else { "" }
  let mut out = minus + whole_digits(raw.whole)
  if (raw.sign & 2) == 2 && raw.fraction.length() > 0 {
    out = out + "." + every_digit(raw.fraction)
  }
  if (raw.sign & 4) == 4 && raw.power.length() > 0 {
    let mark = if (raw.sign & 16) == 16 { "E" } else { "e" }
    let plus = if (raw.sign & 8) == 8 { "+" } else { "" }
    out = out + mark + plus + every_digit(raw.power)
  }
  out
}

///|
/// A double past every other: the value a reader gets from text that
/// overflows.
let beyond : Double = 1.0e308 * 10.0

///|
/// The double a reader gets from the text, or infinity where it overflows.
pub fn approximate(token : String) -> Double {
  let outcome = Ok(@string.parse_double(token)) catch { error => Err(error) }
  match outcome {
    Ok(value) => value
    Err(_) =>
      if token.has_prefix("-") { -beyond } else { beyond }
  }
}

///|
/// A one-clip cut of one frame whose footage begins wherever a number says,
/// with the number written as itself.
fn cut_starting_at(token : String, value : Double) -> Json {
  let clip = footage_clip(media_keys[0], 0L, 1L)
  guard clip is Object(fields) &&
    fields.get("source_range") is Some(Object(range)) &&
    range.get("start_time") is Some(Object(instant)) else {
    abort("oracle: the clip is not built as expected")
  }
  instant["value"] = Json::number(value, repr=token)
  let document = sequence(track_of([], false, []), None)
  guard document is Object(parts) &&
    parts.get("tracks") is Some(Object(tracks)) &&
    tracks.get("children") is Some(Array(children)) &&
    children[0] is Object(track) else {
    abort("oracle: the sequence is not built as expected")
  }
  track["children"] = Json::array([clip])
  document
}

///|
/// What the tool makes of the number: `Ok(frame)` where the clip's footage
/// is read to begin at that frame, or the words it was refused with.
pub fn read_as(token : String) -> Result[Int64, String] raise {
  let document = cut_starting_at(token, approximate(token))
  let outcome = Ok(@tool.read_otio(document, track_index=0, fps=24)) catch {
    error => Err(error)
  }
  let timeline = match outcome {
    Ok(found) => found
    Err(Invalid(words)) => return Err(words)
    Err(Limit(words)) => return Err(words)
  }
  let reports = @tool.plan(timeline, timeline, [
    @tool.Note::{
      id: "n",
      text: "",
      range: { start: 0L, stop: 1L },
      media: None,
      origin: None,
    },
  ])
  Ok(reports[0].pieces[0].source.unwrap().start)
}

///|
/// The last frame can be named but cannot begin a clip of one frame, so
/// the tool refuses the clip's range where it accepted the number.
pub let last : Int64 = 9007199254740991L

///|
/// Whether the tool and the judge say the same of a number. A number that
/// is not a whole frame is refused as one; a whole frame is read back as
/// itself; and the last of all is refused for the range it would make,
/// never as a number.
pub fn agree(token : String) -> Bool raise {
  match (judged(token), read_as(token)) {
    (None, Err(_)) => true
    (Some(frame), Ok(read)) => frame == read
    (Some(frame), Err(words)) =>
      frame == last &&
      (words.contains("exact frame range") || words.contains("frame interval"))
    _ => false
  }
}
