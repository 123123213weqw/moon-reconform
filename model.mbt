///|
/// Frames use a half-open range [start, stop). Markers use [f, f + 1).
#derive(Eq, Debug)
pub(all) struct Span {
  start : Int64
  stop : Int64
}

///|
/// Why a stretch of a track has no footage a note could be placed on.
#derive(Eq, Debug)
pub(all) enum Unplaceable {
  /// A clip whose media has no location of its own: missing, embedded in
  /// the document, or made by the application, as a title or a matte is.
  Offline
  /// A transition between two clips. Its frames come from the clips on
  /// either side and belong to the range of neither.
  Transition
  /// A sequence nested into the track as one clip.
  Nested
}

///|
/// One child of a track. `Gap` is black. `Unplaceable` takes up time like
/// any child but holds no footage a note can be placed on; the Int64 is its
/// length in frames.
#derive(Eq, Debug)
pub(all) enum Shot {
  Clip(String, Span)
  Gap(Int64)
  Unplaceable(Unplaceable, Int64)
}

///|
/// A review annotation. `range` is in frames of the old track, or in
/// frames of the source media named by `media` when the annotation is
/// anchored to the footage itself. A source-anchored annotation needs
/// nothing from the old cut, so it can follow the footage into any later
/// version. `origin` names the exported marker the annotation was read
/// back from, if it was.
#derive(Eq, Debug)
pub(all) struct Note {
  id : String
  text : String
  range : Span
  media : String?
  origin : (String, Int32)?
}

///|
#derive(Eq, Debug)
pub(all) struct Placement {
  clip : Int32
  range : Span
}

///|
/// What became of one piece of an annotation. `GapPiece`, `OfflinePiece`,
/// `TransitionPiece` and `NestedPiece` have no footage and no candidates,
/// so an annotation with such a piece is held.
#derive(Eq, Debug)
pub(all) enum PieceKind {
  Unique
  Ambiguous
  Deleted
  GapPiece
  OfflinePiece
  TransitionPiece
  NestedPiece
}

///|
fn piece_kind(why : Unplaceable?) -> PieceKind {
  match why {
    None => GapPiece
    Some(Offline) => OfflinePiece
    Some(Transition) => TransitionPiece
    Some(Nested) => NestedPiece
  }
}

///|
#derive(Eq, Debug)
pub(all) struct Piece {
  /// The piece's range on the old track; absent for a source-anchored
  /// annotation, which never had a position on the old cut.
  old : Span?
  media : String?
  source : Span?
  candidates : Array[Placement]
  kind : PieceKind
}

///|
#derive(Eq, Debug)
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
fn sum_of(a : Int64, b : Int64) -> Int64? where {
  proof_require: 0L <= a && 0L <= b,
  proof_ensure: result => summed_ok(a, b, result),
} {
  @spans.summed(a, b)
}

///|
fn add_frames(a : Int64, b : Int64) -> Int64 raise ReconformError {
  match sum_of(a, b) {
    Some(total) => total
    None => raise Limit("timeline exceeds exact frame range")
  }
}

///|
pub fn Span::length(self : Span) -> Int64 where {
  proof_ensure: result => result == self.stop - self.start,
} {
  self.stop - self.start
}
