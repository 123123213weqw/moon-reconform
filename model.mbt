///|
/// Frames use a half-open range [start, stop). Markers use [f, f + 1).
pub(all) struct Span {
  start : Int64
  stop : Int64
}

///|
pub(all) enum Shot {
  Clip(String, Span)
  Gap(Int64)
}

///|
pub(all) struct Note {
  id : String
  text : String
  range : Span
}

///|
pub(all) struct Placement {
  clip : Int32
  range : Span
}

///|
pub(all) enum PieceKind {
  Unique
  Ambiguous
  Deleted
  GapPiece
}

///|
pub(all) struct Piece {
  old : Span
  media : String?
  source : Span?
  candidates : Array[Placement]
  kind : PieceKind
}

///|
pub(all) struct NoteReport {
  note : Note
  pieces : Array[Piece]
}

///|
pub(all) suberror ReconformError {
  Invalid(String)
  Limit(String)
}

///|
let max_frames : Int64 = 9007199254740991L

///|
fn Span::checked(self : Span, context : String) -> Unit raise ReconformError {
  if self.start < 0L || self.stop <= self.start || self.stop > max_frames {
    raise Invalid(
      context + ": expected a nonempty nonnegative exact frame interval",
    )
  }
}

///|
fn add_frames(a : Int64, b : Int64) -> Int64 raise ReconformError {
  if b < 0L || a < 0L || a > max_frames - b {
    raise Limit("timeline exceeds exact frame range")
  }
  a + b
}

///|
pub fn Span::length(self : Span) -> Int64 {
  self.stop - self.start
}
