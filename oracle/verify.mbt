///|
/// What one planning produced, as the tool wrote it.
priv struct Outcome {
  written : Json
  resolution : @tool.Resolution
  carry : Array[@tool.Note]
  cursor : Int
  markers : Int64
  pieces : Int64
  choices : Int64
  once : Int64
  repeated : Int64
  nowhere : Int64
  no_footage : Int64
}

///|
/// What a review amounted to, for a campaign to add up.
#derive(Eq, Debug)
pub(all) struct Tally {
  rounds : Int64
  annotations : Int64
  pieces : Int64
  transfers : Int64
  held : Int64
  markers : Int64
  /// The rounds planned with footage near the last frames a count can name.
  distant : Int64
  /// The rounds planned on tracks that begin past what a 32-bit cut could
  /// hold, and are too long to walk a frame at a time.
  lengthy : Int64
  /// The ambiguous pieces that were settled by one of the case's picks.
  choices : Int64
  /// The pieces by what became of them: found once, found in more than
  /// one place, found nowhere, and pieces that hold no footage to find.
  once : Int64
  repeated : Int64
  nowhere : Int64
  no_footage : Int64
}

///|
/// Add one review's numbers to a running total.
pub fn Tally::add(self : Tally, other : Tally) -> Tally {
  Tally::{
    rounds: self.rounds + other.rounds,
    annotations: self.annotations + other.annotations,
    pieces: self.pieces + other.pieces,
    transfers: self.transfers + other.transfers,
    held: self.held + other.held,
    markers: self.markers + other.markers,
    distant: self.distant + other.distant,
    lengthy: self.lengthy + other.lengthy,
    choices: self.choices + other.choices,
    once: self.once + other.once,
    repeated: self.repeated + other.repeated,
    nowhere: self.nowhere + other.nowhere,
    no_footage: self.no_footage + other.no_footage,
  }
}

///|
/// A review with nothing in it yet.
pub let empty : Tally = Tally::{
  rounds: 0L,
  annotations: 0L,
  pieces: 0L,
  transfers: 0L,
  held: 0L,
  markers: 0L,
  distant: 0L,
  lengthy: 0L,
  choices: 0L,
  once: 0L,
  repeated: 0L,
  nowhere: 0L,
  no_footage: 0L,
}

///|
/// What an error says, in the words of the rule it broke.
pub fn words(error : Error) -> String {
  match error {
    @tool.Invalid(reason) => reason
    @tool.Limit(reason) => reason
    Failure(message) => message
    _ => @debug.to_string(error)
  }
}

///|
fn shown(pieces : Array[@tool.Piece]) -> String {
  Json::array(pieces.map(piece_at)).stringify()
}

///|
/// A choice for every ambiguous piece, one pick from the case for each, in
/// order: which of the piece's candidates to take.
fn choose_for(
  reports : Array[@tool.NoteReport],
  picks : Array[Int32],
  cursor : Int,
) -> (Array[@tool.Selection], Int) {
  let selections = []
  let mut at = cursor
  for report in reports {
    for i, piece in report.pieces {
      if piece.candidates.length() > 1 {
        let pick = if at < picks.length() {
          (picks[at] & 0x7fffffff).to_int64()
        } else {
          0L
        }
        at += 1
        let count = piece.candidates.length().to_int64()
        let clip = piece.candidates[(pick % count).to_int()].clip
        selections.push(@tool.Selection::{ note_id: report.note.id, piece: i, clip })
      }
    }
  }
  (selections, at)
}

///|
/// Check one planning against the oracle, end to end. The old and the new
/// cut are read by the tool and, separately, by the oracle; every
/// annotation's pieces must equal the oracle's interval plan and survive
/// its frame walk; the outcome must be what follows from those pieces; the
/// report must be the one the oracle writes; and the export must be the
/// document the oracle builds. Raises at the first thing that is not so,
/// saying which.
fn examine(
  old : Json,
  fresh : Json,
  old_track : Int32,
  new_track : Int32,
  notes : Array[@tool.Note],
  picks : Array[Int32],
  cursor : Int,
  choose : Bool,
  walked~ : Bool,
  fps~ : Int32 = 24,
  picked~ : Array[@tool.Selection] = [],
) -> Outcome raise {
  let before = @tool.read_otio(old, track_index=old_track, fps~)
  let after = @tool.read_otio(fresh, track_index=new_track, fps~)
  let reports = @tool.plan(before, after, notes)
  let old_slots = slots(old, old_track)
  let fresh_slots = slots(fresh, new_track)
  if before.duration() != duration_of(old_slots) ||
    after.duration() != duration_of(fresh_slots) {
    fail("the tool and the oracle read the tracks as different lengths")
  }
  let model = []
  let mut pieces = 0L
  let mut once = 0L
  let mut repeated = 0L
  let mut nowhere = 0L
  let mut no_footage = 0L
  for i, note in notes {
    let wanted = planned(old_slots, fresh_slots, note)
    if reports[i].pieces != wanted {
      fail(
        "annotation " +
        note.id +
        ": the tool planned " +
        shown(reports[i].pieces) +
        " and the oracle " +
        shown(wanted),
      )
    }
    // A track that begins far away is too long to walk a frame at a time.
    // Its pieces are still held to the interval plan, and so is all that
    // follows from them.
    if walked {
      walk(old_slots, fresh_slots, note, reports[i].pieces)
    }
    model.push(@tool.NoteReport::{ note, pieces: wanted })
    pieces += wanted.length().to_int64()
    for piece in wanted {
      match piece.kind {
        Unique => once += 1L
        Ambiguous => repeated += 1L
        Deleted => nowhere += 1L
        _ => no_footage += 1L
      }
    }
  }
  let (selections, after_picks) =
    if choose { choose_for(reports, picks, cursor) } else { (picked, cursor) }
  let resolution = @tool.resolve(reports, selections)
  let (settled, carried) = expected(model, selections)
  if resolution != settled {
    fail(
      "the tool settled on " +
      @debug.to_string(resolution) +
      " and the oracle on " +
      @debug.to_string(settled),
    )
  }
  let travelled = @tool.carried(reports, resolution)
  if travelled != carried {
    fail(
      "the tool carries " +
      @debug.to_string(travelled) +
      " and the oracle " +
      @debug.to_string(carried),
    )
  }
  let report = @tool.report_json(before, after, reports, resolution)
  let written_report = report_of(
    before.duration(),
    after.duration(),
    model,
    settled,
    carried,
  )
  if report != written_report {
    fail(
      "the report is not the one the oracle writes:\n" +
      report.stringify(indent=1) +
      "\n---\n" +
      written_report.stringify(indent=1),
    )
  }
  let written = @tool.with_markers(
    fresh,
    track_index=new_track,
    fps~,
    resolution,
  )
  let document = exported(fresh, new_track, settled, fresh_slots)
  if written != document {
    fail(
      "the export is not the document the oracle builds:\n" +
      written.stringify(indent=1) +
      "\n---\n" +
      document.stringify(indent=1),
    )
  }
  Outcome::{
    written,
    resolution,
    carry: carried,
    cursor: after_picks,
    markers: markers_on(track_of_document(written, new_track)).length().to_int64(),
    pieces,
    choices: selections.length().to_int64(),
    once,
    repeated,
    nowhere,
    no_footage,
  }
}

///|
fn count_of(outcome : Outcome) -> Tally {
  Tally::{
    rounds: 1L,
    annotations: 0L,
    pieces: outcome.pieces,
    transfers: outcome.resolution.transfers.length().to_int64(),
    held: outcome.resolution.held.length().to_int64(),
    markers: outcome.resolution.transfers.length().to_int64(),
    distant: 0L,
    lengthy: 0L,
    choices: outcome.choices,
    once: outcome.once,
    repeated: outcome.repeated,
    nowhere: outcome.nowhere,
    no_footage: outcome.no_footage,
  }
}

///|
/// Run a whole review through the tool, round by round, and hold everything
/// it answers to the oracle. The first round plans the case's annotations
/// against the new cut and exports. Wherever that leaves a marker, the
/// editor's next cut carries them all, by timecode, next to a marker of
/// their own now and then; the second round reads them back by footage,
/// carries what was held, plans against that third cut, and exports again.
pub fn verify(case : Case) -> Tally raise {
  let (old, old_track, fresh, new_track, third, third_track, asked) = build(case)
  let notes = @tool.read_request(asked).notes
  let one = examine(
    old,
    fresh,
    old_track,
    new_track,
    notes,
    case.picks,
    0,
    (case.switches & 2) == 0,
    walked=lead_of(case) == 0L,
  )
  let first = count_of(one)
  let tally = Tally::{
    rounds: first.rounds,
    annotations: notes.length().to_int64(),
    pieces: first.pieces,
    transfers: first.transfers,
    held: first.held,
    markers: first.markers,
    distant: if offset_of(case) == 0L { 0L } else { 1L },
    lengthy: if lead_of(case) == 0L { 0L } else { 1L },
    choices: first.choices,
    once: first.once,
    repeated: first.repeated,
    nowhere: first.nowhere,
    no_footage: first.no_footage,
  }
  if one.markers > 0 {
    let stale = markers_on(track_of_document(one.written, new_track)).copy()
    if (case.switches & 1) == 1 {
      stale.push(own_marker("The editor's own", 1L, 1L))
    }
    let next = with_markers_on(third, third_track, stale)
    let carried = one.carry.map(note => {
      Json::object({
        "id": Json(note.id),
        "text": Json(note.text),
        "media": Json(note.media.unwrap()),
        "source": span(note.range.start, note.range.stop),
      })
    })
    let asked_again = request(
      new_track,
      third_track,
      carried,
      [],
      true,
    )
    let again = @tool.read_request(asked_again).notes.copy()
    let read = @tool.read_notes_from_markers(
      one.written,
      track_index=new_track,
      fps=24,
    )
    let wanted = read_back(one.written, new_track)
    if read != wanted {
      fail(
        "the tool reads back " +
        @debug.to_string(read) +
        " and the oracle " +
        @debug.to_string(wanted),
      )
    }
    for note in read {
      again.push(note)
    }
    let two = examine(
      one.written,
      next,
      new_track,
      third_track,
      again,
      case.picks,
      one.cursor,
      (case.switches & 4) == 0,
      walked=lead_of(case) == 0L,
    )
    let more = count_of(two)
    tally.add(
      Tally::{
        rounds: more.rounds,
        annotations: again.length().to_int64(),
        pieces: more.pieces,
        transfers: more.transfers,
        held: more.held,
        markers: more.markers,
        distant: if offset_of(case) == 0L { 0L } else { 1L },
        lengthy: if lead_of(case) == 0L { 0L } else { 1L },
        choices: more.choices,
        once: more.once,
        repeated: more.repeated,
        nowhere: more.nowhere,
        no_footage: more.no_footage,
      },
    )
  } else {
    tally
  }
}

///|
/// Hold a review that was not generated but changed, as a fuzzer changes
/// one, to the same standard as a generated one: the tool refuses it in so
/// many words, or answers it exactly as the oracle says. The request's own
/// frame rate and its own selections are what the tool is given.
pub fn checked(old : Json, fresh : Json, asked : Json) -> Unit raise {
  let request = @tool.read_request(asked)
  // The tool reads both cuts first: a document it will not read is not
  // one the oracle sets out to lay out.
  ignore(@tool.read_otio(old, track_index=request.old_track, fps=request.fps))
  ignore(@tool.read_otio(fresh, track_index=request.new_track, fps=request.fps))
  let notes = request.notes.copy()
  if request.from_markers {
    for note in @tool.read_notes_from_markers(
      old,
      track_index=request.old_track,
      fps=request.fps,
    ) {
      notes.push(note)
    }
  }
  let old_length = duration_of(slots(old, request.old_track))
  let fresh_length = duration_of(slots(fresh, request.new_track))
  let walked = old_length <= 20000L && fresh_length <= 20000L
  ignore(
    examine(
      old,
      fresh,
      request.old_track,
      request.new_track,
      notes,
      [],
      0,
      false,
      walked~,
      fps=request.fps,
      picked=request.selections,
    ),
  )
}

///|
/// A cut compared with itself puts every annotation back where it was.
/// A piece on the track is offered its own frames, and every other place
/// the cut repeats that footage, and nothing else. A piece on footage is
/// offered every place the cut has it, or nothing where it has it not.
/// A piece on black, or on a child without footage, is offered nothing.
/// The frame walk says that each place offered shows the piece's footage.
pub fn self_mapped(
  cut : Cut,
  marks : Array[Mark],
  far~ : Int64 = 0L,
) -> Unit raise {
  let (document, selected) = document_of(cut, far~)
  let laid = slots(document, selected)
  let timeline = @tool.read_otio(document, track_index=selected, fps=24)
  let built = build({ cuts: [cut, cut, cut], marks, picks: [], switches: 0 })
  let notes = @tool.read_request(built.6).notes
  let reports = @tool.plan(timeline, timeline, notes)
  for i, note in notes {
    for piece in reports[i].pieces {
      let one = piece.candidates.length()
      let kind = match one {
        0 => @tool.Deleted
        1 => @tool.Unique
        _ => @tool.Ambiguous
      }
      // With nothing offered there is nothing to be missed; otherwise the
      // piece's own frames have to be among the places offered.
      let mut own = one == 0 || piece.old is None
      for candidate in piece.candidates {
        if piece.old is Some(range) && candidate.range == range {
          own = true
        }
      }
      let nothing = piece.media is None && one == 0
      if !(own && (piece.kind == kind || nothing)) {
        fail(
          "annotation " +
          note.id +
          " is not offered its own place, and only that: " +
          shown(reports[i].pieces),
        )
      }
    }
    walk(laid, laid, note, reports[i].pieces)
  }
}
