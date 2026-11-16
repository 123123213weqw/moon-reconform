///|
pub(all) struct Selection {
  note_id : String
  piece : Int32
  clip : Int32
}

///|
pub(all) struct Transfer {
  note_id : String
  text : String
  piece : Int32
  placement : Placement
}

///|
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
