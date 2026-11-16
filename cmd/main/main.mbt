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
fn read_json(path : String) -> Json raise {
  guard read_input(path) is Some(text) else {
    fail("cannot read a regular UTF-8 input file of at most 16 MB: " + path)
  }
  @json.parse(text)
}

///|
fn main {
  try {
    let args = @env.args()
    if args.length() != 6 || args[2] != "plan" {
      fail(
        "usage: moon run cmd/main --target js -- plan old.otio new.otio notes.json",
      )
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
    let reports = @core.plan(before, after, request.notes)
    let resolution = @core.resolve(reports, request.selections)
    println(@core.report_json(before, after, reports, resolution).stringify())
  } catch {
    error => {
      println(
        Json::object({ "ok": Json(false), "error": Json(error.to_string()) }).stringify(),
      )
      exit_status(1)
    }
  }
}
