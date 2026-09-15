// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "lexchb/memcached"

version = "0.1.0"

readme = "README.mbt.md"

repository = "https://github.com/lexchb/moonbit-memcached.git"

license = "Apache-2.0"

keywords = [ "memcached", "cache", "client", "protocol", "text-protocol" ]

preferred_target = "wasm-gc"

description = "A memcached text protocol client library implemented in MoonBit."
