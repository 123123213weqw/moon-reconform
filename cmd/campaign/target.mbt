///|
/// The backend this program was built for, to say so in its summary.
#cfg(target = "js")
fn target() -> String {
  "js"
}

///|
#cfg(target = "wasm")
fn target() -> String {
  "wasm"
}

///|
#cfg(target = "wasm-gc")
fn target() -> String {
  "wasm-gc"
}

///|
#cfg(target = "native")
fn target() -> String {
  "native"
}
