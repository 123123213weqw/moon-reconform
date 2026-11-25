///|
#derive(Eq, Debug)
pub(all) struct Selection {
  note_id : String
  piece : Int32
  clip : Int32
}

///|
#derive(Eq, Debug)
pub(all) struct Transfer {
  note_id : String
  text : String
  piece : Int32
  placement : Placement
  /// The marker the annotation was read back from, if it was.
  origin : (String, Int32)?
}

///|
#derive(Eq, Debug)
pub(all) struct Resolution {
  transfers : Array[Transfer]
  held : Array[String]
}

///|
/// Resolve whole annotations only. Every unresolved piece holds its annotation
/// back, even when other pieces already have confirmed placements.
pub fn resolve(
  reports : Array[NoteReport],
  selections : Array[Selection],
) -> Resolution raise ReconformError {
  if selections.length() > 100000 {
    raise Limit("too many manual selections")
  }
  let pending : Map[(String, Int32), Int32] = Map([])
  for selection in selections {
    let key = (selection.note_id, selection.piece)
    if pending.contains(key) {
      raise Invalid("duplicate selection for " + selection.note_id)
    }
    pending[key] = selection.clip
  }
  let transfers = []
  let held = []
  for report in reports {
    let note = report.note
    let proposed = []
    for i, piece in report.pieces {
      let key = (note.id, i)
      let chosen = match pending.get(key) {
        Some(clip) => {
          pending.remove(key)
          if piece.kind is Ambiguous {
            let candidate = piece.candidates
              .iter()
              .find_first(p => p.clip == clip)
            guard candidate is Some(placement) else {
              raise Invalid("selection clip is not a candidate for " + note.id)
            }
            Some(placement)
          } else {
            raise Invalid(
              "selections require an ambiguous piece for " + note.id,
            )
          }
        }
        None =>
          if piece.kind is Unique {
            piece.candidates.get(0)
          } else {
            None
          }
      }
      if chosen is Some(placement) {
        proposed.push({
          note_id: note.id,
          text: note.text,
          piece: i,
          placement,
          origin: note.origin,
        })
      }
    }
    if proposed.length() == report.pieces.length() {
      for transfer in proposed {
        transfers.push(transfer)
      }
    } else {
      held.push(note.id)
    }
  }
  if pending.length() != 0 {
    raise Invalid("selection references an unknown annotation or piece")
  }
  { transfers, held, }
}

///|
/// The held annotations restated for the next cut. A held annotation has
/// no place on the new timeline, so it cannot travel by frame number; what
/// survives is the footage it pointed at. Every held piece that has source
/// frames becomes one annotation anchored to those frames and named
/// `<id>#<piece>`, ready to paste into the next request's `notes`. Pieces on
/// old-track black have no footage and are left out.
pub fn carried(
  reports : Array[NoteReport],
  resolution : Resolution,
) -> Array[Note] {
  let held : Map[String, Unit] = Map([])
  for id in resolution.held {
    held[id] = ()
  }
  let notes = []
  for report in reports {
    if held.contains(report.note.id) {
      for i, piece in report.pieces {
        if piece.media is Some(key) && piece.source is Some(source) {
          notes.push({
            id: report.note.id + "#" + i.to_string(),
            text: report.note.text,
            range: source,
            media: Some(key),
            origin: None,
          })
        }
      }
    }
  }
  notes
}
