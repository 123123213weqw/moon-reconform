///|
/// The largest input the command reads, in bytes. The limit keeps a
/// document inside what the counts above bound: 20,000 children and
/// 10,000 annotations make up about 14.85 MB at their largest.
let input_limit : Int64 = 16_000_000

///|
/// Read a whole regular file of at most `limit` bytes, as UTF-8; none
/// where it is not one, is larger, or changed while being read. The limit
/// is the caller's, so that it is a number of the command and not of Node.
extern "js" fn read_input(path : String, limit : Int64) -> String? =
  #| (path, limit) => {
  #|   const fs = process.getBuiltinModule("node:fs");
  #|   let fd;
  #|   try {
  #|     fd = fs.openSync(path, "r");
  #|     const stats = fs.fstatSync(fd);
  #|     if (!stats.isFile() || stats.size > limit) return undefined;
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
/// Where the command reads its three inputs and writes its one output.
/// The command is `answer`; `main` hands it the terminal's own, and a
/// test hands it what it likes.
struct Files {
  /// A whole regular file of at most the given number of bytes, or none.
  read : (String, Int64) -> String?
  /// Write the content to a path that has to be new; an error message
  /// where that could not be done.
  write : (String, String) -> String?
}

///|
let usage : String =
  #|usage: plan old.otio new.otio request.json
  #|       apply old.otio new.otio request.json output.otio

///|
fn Files::json(self : Files, path : String) -> Json raise Command {
  guard (self.read)(path, input_limit) is Some(text) else {
    raise Input(
      "cannot read a regular UTF-8 input file of at most 16 MB: " + path,
    )
  }
  match @codec.parse(text) {
    Ok(value) => value
    Err(error) => raise Input(path + ": " + error)
  }
}

///|
/// The command, with its files and its output left to the caller. It says
/// whether the command succeeded; what it printed went to `out`, on one line
/// each, as the terminal would have had it. A refusal from the core or a
/// failure of the command itself is let out as it was raised, for `command`
/// to put into words.
fn answer(
  args : Array[String],
  files : Files,
  out : (String) -> Unit,
) -> Bool raise {
  let planning = args.length() == 6 && args[2] == "plan"
  let applying = args.length() == 7 && args[2] == "apply"
  if args.length() == 3 && (args[2] == "--help" || args[2] == "-h") {
    out(usage)
    return false
  }
  if !planning && !applying {
    raise Arguments(usage)
  }
  let old_json = files.json(args[3])
  let new_json = files.json(args[4])
  let request = @core.read_request(files.json(args[5]))
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
    for
      note in @core.read_notes_from_markers(
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
    if (files.write)(args[6], content) is Some(error) {
      raise Output(error)
    }
  }
  out(@core.report_json(before, after, reports, resolution).stringify())
  false
}

///|
/// The command as the terminal has it: a refusal from the core or a failure
/// of the command itself is put into words here, printed as one JSON line,
/// and never carries a source position.
fn command(args : Array[String], files : Files, out : (String) -> Unit) -> Bool {
  answer(args, files, out) catch {
    error => {
      let message = match error {
        @core.Invalid(reason) => reason
        @core.Limit(reason) => reason
        Arguments(reason) | Input(reason) | Output(reason) => reason
        _ => error.to_string()
      }
      out(
        Json::object({ "ok": Json(false), "error": Json(message) }).stringify(),
      )
      true
    }
  }
}

///|
fn main {
  let files = {
    read: fn(path, limit) { read_input(path, limit) },
    write: write_new,
  }
  if command(@env.args(), files, fn(text) { println(text) }) {
    exit_status(1)
  }
}
