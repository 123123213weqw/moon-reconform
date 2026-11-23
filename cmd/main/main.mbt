///|
extern "js" fn read_input(path : String) -> String? =
  #| path => {
  #|   const fs = process.getBuiltinModule("node:fs");
  #|   let fd;
  #|   try {
  #|     fd = fs.openSync(path, "r");
  #|     const stats = fs.fstatSync(fd);
  #|     if (!stats.isFile() || stats.size > 16_000_000) return undefined;
  #|     const buffer = Buffer.alloc(stats.size + 1);
  #|     let size = 0;
  #|     while (size < buffer.length) {
  #|       const read = fs.readSync(fd, buffer, size, buffer.length - size, null);
  #|       if (read === 0) break;
  #|       size += read;
  #|     }
  #|     if (size !== stats.size) return undefined;
  #|     return new TextDecoder("utf-8", { fatal: true }).decode(buffer.subarray(0, size));
  #|   } catch {
  #|     return undefined;
  #|   } finally {
  #|     if (fd !== undefined) fs.closeSync(fd);
  #|   }
  #| }

///|
extern "js" fn exit_status(code : Int32) -> Unit =
  #| code => { process.exitCode = code; }

///|
extern "js" fn write_new(path : String, content : String) -> String? =
  #| (path, content) => {
  #|   const fs = process.getBuiltinModule("node:fs");
  #|   const p = process.getBuiltinModule("node:path");
  #|   let dir, temp;
  #|   try {
  #|     const target = p.resolve(path);
  #|     dir = fs.mkdtempSync(p.join(p.dirname(target), ".moon-reconform-"));
  #|     temp = p.join(dir, "timeline.otio");
  #|     fs.writeFileSync(temp, content + "\n", { flag: "wx" });
  #|     fs.linkSync(temp, target);
  #|     return undefined;
  #|   } catch (err) {
  #|     return "cannot create OTIO output (" + (err.code || "write failed") + "): " + path;
  #|   } finally {
  #|     if (temp) { try { fs.unlinkSync(temp); } catch {} }
  #|     if (dir) { try { fs.rmdirSync(dir); } catch {} }
  #|   }
  #| }

///|
/// A failure of the command itself rather than a refusal from the core: a
/// wrong invocation, an input that cannot be read, an output that cannot be
/// written. The message is for the person at the terminal, so it names the
/// file or the usage and never a source position.
pub(all) suberror Command {
  Arguments(String)
  Input(String)
  Output(String)
}

///|
let usage : String =
  #|usage: plan old.otio new.otio request.json
  #|       apply old.otio new.otio request.json output.otio

///|
fn read_json(path : String) -> Json raise Command {
  guard read_input(path) is Some(text) else {
    raise Input("cannot read a regular UTF-8 input file of at most 16 MB: " + path)
  }
  match @codec.parse(text) {
    Ok(value) => value
    Err(error) => raise Input(path + ": " + error)
  }
}

///|
fn main {
  try {
    let args = @env.args()
    let planning = args.length() == 6 && args[2] == "plan"
    let applying = args.length() == 7 && args[2] == "apply"
    if args.length() == 3 && (args[2] == "--help" || args[2] == "-h") {
      println(usage)
      return
    }
    if !planning && !applying {
      raise Arguments(usage)
    }
    let old_json = read_json(args[3])
    let new_json = read_json(args[4])
    let request = @core.read_request(read_json(args[5]))
    let before = @core.read_otio(
      old_json,
      track_index=request.old_track,
      fps=request.fps,
    )
    let after = @core.read_otio(
      new_json,
      track_index=request.new_track,
      fps=request.fps,
    )
    // Annotations the reviewer wrote come first; the markers the old cut
    // already carries follow in track order.
    let notes = request.notes.copy()
    if request.from_markers {
      for note in @core.read_notes_from_markers(
        old_json,
        track_index=request.old_track,
        fps=request.fps,
      ) {
        notes.push(note)
      }
    }
    let reports = @core.plan(before, after, notes)
    let resolution = @core.resolve(reports, request.selections)
    if applying {
      let exported = @core.with_markers(
        new_json,
        track_index=request.new_track,
        fps=request.fps,
        resolution,
      )
      let content = match @codec.stringify(exported) {
        Ok(value) => value
        Err(error) => raise Output("cannot encode OTIO output: " + error)
      }
      if write_new(args[6], content) is Some(error) {
        raise Output(error)
      }
    }
    println(@core.report_json(before, after, reports, resolution).stringify())
  } catch {
    error => {
      let message = match error {
        @core.Invalid(reason) => reason
        @core.Limit(reason) => reason
        Arguments(reason) | Input(reason) | Output(reason) => reason
        _ => error.to_string()
      }
      println(
        Json::object({ "ok": Json(false), "error": Json(message) }).stringify(),
      )
      exit_status(1)
    }
  }
}
