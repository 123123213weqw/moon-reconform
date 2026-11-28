///|
/// A frame rate: how many frames a second, and how that number was
/// written. Whole numbers are the common case; 23.976 and 29.97 are why it
/// is not a whole number alone.
///
/// Every time in a cut has to be at the request's rate. Nothing ever
/// converts between rates, so frame numbers stay exact whatever the rate
/// is: a cut at 29.97 works in frames of 29.97, as a cut at 24 works in
/// frames of 24.
#derive(Eq, Debug)
pub(all) struct Rate {
  /// Frames per second.
  value : Double
  /// The number as it was written where this rate came from, so that a
  /// marker the tool writes is spelled the same way.
  token : String
}

///|
/// A whole-number frame rate, as a program makes one up.
pub fn Rate::whole(frames : Int32) -> Rate {
  { value: frames.to_double(), token: frames.to_string() }
}

///|
/// Whether two rates are the same number of frames per second, however
/// each one is written.
pub fn Rate::same(self : Rate, other : Rate) -> Bool {
  self.value == other.value
}

///|
/// A number JSON can carry in plain digits, with or without a fraction and
/// with no exponent or sign: a spelling a marker can carry as it stands.
fn plainly_written(token : String) -> Bool {
  let mut digits = 0
  let mut dots = 0
  for byte in token {
    if byte == '.' {
      dots += 1
      if dots > 1 {
        return false
      }
    } else if byte >= '0' && byte <= '9' {
      digits += 1
    } else {
      return false
    }
  }
  digits > 0
}

///|
/// How a rate is written into a marker: as the request wrote it where that
/// is plain digits, and as the number itself otherwise.
fn rate_written(value : Double, token : String) -> String {
  if plainly_written(token) {
    token
  } else {
    value.to_string()
  }
}

///|
/// The request's frame rate: a number from 1 to 240 per second, whole or
/// not, kept as it was written so that a marker can carry the same
/// spelling.
fn exact_rate(value : Json, context : String) -> Rate raise ReconformError {
  guard value is Number(n, repr~) else {
    raise Invalid(context + ": expected a frame rate")
  }
  if !(n >= 1.0 && n <= 240.0) {
    raise Invalid("fps must be between 1 and 240")
  }
  let token = match repr {
    Some(shown) => rate_written(n, shown)
    None => n.to_string()
  }
  { value: n, token }
}

///|
/// A rate written in a document has to be the request's, however either one
/// is spelled.
fn check_rate_field(
  value : Json,
  rate : Rate,
  context : String,
) -> Unit raise ReconformError {
  guard value is Number(n, repr~) else {
    raise Invalid(context + ".rate: expected a frame rate")
  }
  if !(n > 0.0 && n <= 1000000.0) {
    raise Invalid(context + ".rate: expected a positive frame rate")
  }
  if n != rate.value {
    let shown = match repr {
      Some(token) => token
      None => n.to_string()
    }
    raise Invalid(
      context +
      ": RationalTime rate " +
      shown +
      " differs from the request's " +
      rate.token +
      " fps. Every time in a cut has to be at the request's frame rate. An export that gives a clip's footage at the rate of its own media, as 15 fps footage in a 30 fps sequence, mixes rates and is not supported.",
    )
  }
}
