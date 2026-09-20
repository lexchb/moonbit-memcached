// Whitebox tests run within the package scope.
// Use them to validate internal helpers or invariants.
// Keep them focused; public behavior belongs in `_test.mbt`.
//
// The blackbox suite only drives the package through `Decoder`, `Client` and
// `ScriptedConnection`, so several private paths are never reached directly:
// four of the six `StorageOp` command words, the `i32`/`u64` numeric
// boundaries, the `0x7F` key rule, keys longer than 250 bytes once multi-byte
// characters are involved, and the response-kind checks. Those are what the
// tests below pin down.

///|
/// Short name for how a protocol call failed.
///
/// The probes below take plain arguments and do their own `try`/`catch`, so a
/// single private helper can be observed without writing a closure per case.
fn name_of(err : ProtocolError) -> String {
  match err {
    Malformed(_) => "malformed"
    Desynchronised(_, _) => "desynchronised"
    Remote(kind, _) =>
      match kind {
        RemoteErrorKind::Generic => "generic"
        RemoteErrorKind::Client => "client"
        RemoteErrorKind::Server => "server"
      }
  }
}

///|
/// How `parse_decimal` reacts to `text`, which it expects to hold `what`.
fn decimal_outcome(text : String, what : String) -> String {
  try {
    ignore(parse_decimal(text.view(), what))
    "ok"
  } catch {
    err => name_of(err)
  }
}

///|
/// How `parse_decimal_int` reacts to `text`, which it expects to hold `what`.
fn int_outcome(text : String, what : String) -> String {
  try {
    ignore(parse_decimal_int(text.view(), what))
    "ok"
  } catch {
    err => name_of(err)
  }
}

///|
/// How `parse_value_header` reacts to `line`, whose block is assumed to be
/// received by a decoder of the default size.
fn header_outcome(line : String, limit? : Int = DEFAULT_BUFFER_LIMIT) -> String {
  try {
    ignore(parse_value_header(line, limit))
    "ok"
  } catch {
    err => name_of(err)
  }
}

///|
/// How `decode_response` reacts to `input`.
///
/// An incomplete response is not an error: it reports `"ok"` because the call
/// merely returns `None` and waits for more bytes.
fn response_outcome(input : Bytes) -> String {
  try {
    ignore(decode_response(input.view(), DEFAULT_BUFFER_LIMIT))
    "ok"
  } catch {
    err => name_of(err)
  }
}

///|
/// How `parse_stat_line` reacts to `line`.
fn stat_outcome(line : BytesView) -> String {
  try {
    ignore(parse_stat_line(line))
    "ok"
  } catch {
    err => name_of(err)
  }
}

///|
/// How `decode_stats` reacts to `input`.
///
/// Like `response_outcome`, a section that has not reached its `END` line is
/// not an error: the call returns `None` and waits for more data.
fn stats_outcome(input : Bytes) -> String {
  try {
    ignore(decode_stats(input.view()))
    "ok"
  } catch {
    err => name_of(err)
  }
}

///|
/// How `expect_values` reacts to `response`.
///
/// Unlike the helpers above, these raise the untyped `Error`, so the catch
/// arm matches on `ProtocolError` instead of naming it directly.
fn values_outcome(response : Response) -> String {
  try {
    ignore(expect_values(response))
    "ok"
  } catch {
    err =>
      match err {
        ProtocolError::Malformed(_) => "malformed"
        _ => "other"
      }
  }
}

///|
/// How `expect_status` reacts to `response`.
fn status_outcome(response : Response) -> String {
  try {
    ignore(expect_status(response))
    "ok"
  } catch {
    err =>
      match err {
        ProtocolError::Malformed(_) => "malformed"
        _ => "other"
      }
  }
}

///|
/// How `expect_counter` reacts to `response`.
fn counter_outcome(response : Response) -> String {
  try {
    ignore(expect_counter(response))
    "ok"
  } catch {
    err =>
      match err {
        ProtocolError::Malformed(_) => "malformed"
        _ => "other"
      }
  }
}

///|
/// How `validate_key` reacts to `key`.
fn key_outcome(key : String) -> String {
  try {
    validate_key(key)
    "ok"
  } catch {
    err => name_of(err)
  }
}

///|
/// The message `validate_key` raises for `key`.
fn key_message(key : String) -> String {
  try {
    validate_key(key)
    abort("expected a malformed error")
  } catch {
    ProtocolError::Malformed(message) => message
    _ => abort("expected a malformed error")
  }
}

///|
/// The message `validate_subcommand` raises for `section`.
fn section_message(section : String) -> String {
  try {
    validate_subcommand(section)
    abort("expected a malformed error")
  } catch {
    ProtocolError::Malformed(message) => message
    _ => abort("expected a malformed error")
  }
}

///|
/// How `validate_request` reacts to `request`.
fn request_outcome(request : Request) -> String {
  try {
    validate_request(request)
    "ok"
  } catch {
    err => name_of(err)
  }
}

///|
/// A key of `n` one-byte characters.
fn ascii_key(n : Int) -> String {
  let builder = StringBuilder()
  for _ in 0..<n {
    builder.write_char('k')
  }
  builder.to_string()
}

///|
/// A key of `n` three-byte characters, totalling `3 * n` bytes.
fn wide_key(n : Int) -> String {
  let builder = StringBuilder()
  for _ in 0..<n {
    builder.write_char('键')
  }
  builder.to_string()
}

///|
test "every storage op maps to its command word" {
  assert_eq(StorageOp::Set.name().to_owned(), "set")
  assert_eq(StorageOp::Add.name().to_owned(), "add")
  assert_eq(StorageOp::Replace.name().to_owned(), "replace")
  assert_eq(StorageOp::Append.name().to_owned(), "append")
  assert_eq(StorageOp::Prepend.name().to_owned(), "prepend")
  assert_eq(StorageOp::Cas.name().to_owned(), "cas")
}

///|
test "find_crlf reports the offset of the first separator" {
  assert_true(find_crlf(b"\r\nrest".view()) is Some(0))
  assert_true(find_crlf(b"abc\r\n".view()) is Some(3))
  assert_true(find_crlf(b"a\r\nb\r\n".view()) is Some(1))
  assert_true(find_crlf(b"".view()) is None)
  assert_true(find_crlf(b"abc\r".view()) is None)
  assert_true(find_crlf(b"abc".view()) is None)
}

///|
test "is_decimal only accepts non-empty digit runs" {
  assert_true(is_decimal("0".view()))
  assert_true(is_decimal("007".view()))
  assert_true(is_decimal("18446744073709551615".view()))
  assert_true(!is_decimal("".view()))
  assert_true(!is_decimal("-1".view()))
  assert_true(!is_decimal("+1".view()))
  assert_true(!is_decimal("1a".view()))
  assert_true(!is_decimal("1 2".view()))
}

///|
test "parse_decimal spans the whole uint64 range" {
  assert_eq(parse_decimal("42".view(), "field"), 42UL)
  assert_eq(
    parse_decimal("18446744073709551615".view(), "field"),
    18446744073709551615UL,
  )
  assert_eq(decimal_outcome("0", "field"), "ok")
  assert_eq(decimal_outcome("18446744073709551616", "field"), "malformed")
  assert_eq(decimal_outcome("", "field"), "malformed")
  assert_eq(decimal_outcome("12a", "field"), "malformed")
}

///|
test "parse_decimal_int stops at the signed 32-bit boundary" {
  assert_eq(parse_decimal_int("2147483647".view(), "flags"), 2147483647)
  assert_eq(int_outcome("0", "flags"), "ok")
  assert_eq(int_outcome("2147483647", "flags"), "ok")
  assert_eq(int_outcome("2147483648", "flags"), "malformed")
  assert_eq(int_outcome("4294967296", "bytes"), "malformed")
  assert_eq(int_outcome("", "bytes"), "malformed")
  assert_eq(int_outcome("x", "bytes"), "malformed")
}

///|
test "parse_value_header accepts four or five fields only" {
  let plain = parse_value_header("VALUE foo 7 3", DEFAULT_BUFFER_LIMIT)
  assert_eq(plain.key, "foo")
  assert_eq(plain.flags, 7)
  assert_eq(plain.size, 3)
  assert_true(plain.cas is None)

  let with_cas = parse_value_header("VALUE foo 7 3 42", DEFAULT_BUFFER_LIMIT)
  assert_true(with_cas.cas is Some(42UL))

  let unicode = parse_value_header("VALUE 键 0 3", DEFAULT_BUFFER_LIMIT)
  assert_eq(unicode.key, "键")

  assert_eq(header_outcome("VALUE foo 7"), "malformed")
  assert_eq(header_outcome("VALUE foo 7 3 42 99"), "malformed")
  assert_eq(header_outcome("VALUE foo x 3"), "malformed")
  assert_eq(header_outcome("VALUE foo 7 x"), "malformed")
  assert_eq(header_outcome("VALUE foo 4294967296 3"), "malformed")
}

///|
test "a VALUE header beyond the decoder's limit is refused before it is buffered" {
  // The cap is the receiving decoder's buffer limit, and a retrieval has to be
  // buffered whole, so the header line, the CRLF that closes the block and the
  // END line come out of that same cap: the block may only use what is left.
  assert_eq(header_outcome("VALUE foo 0 1048576"), "ok")
  assert_eq(header_outcome("VALUE foo 0 \{DEFAULT_BUFFER_LIMIT}"), "malformed")
  assert_eq(
    header_outcome("VALUE foo 0 \{DEFAULT_BUFFER_LIMIT + 1}"),
    "malformed",
  )
  // A 64-byte decoder: `VALUE foo 0 41` needs 14 + 41 + 9 = 64 bytes, so it
  // fits exactly, while one byte more does not.
  assert_eq(header_outcome("VALUE foo 0 41", limit=64), "ok")
  assert_eq(header_outcome("VALUE foo 0 42", limit=64), "malformed")
  assert_eq(header_outcome("VALUE foo 0 1048576", limit=64), "malformed")
}

///|
test "an oversized block is reported against the limit, not the data" {
  // The declaration is the only place the problem shows, so the decoder says so
  // instead of waiting for a block that could never fit. Naming the declaration,
  // what it needs with its framing and the limit tells the two possible culprits
  // apart: a peer that lost its framing, or a limit too small for the block.
  let decoder = Decoder::with_limit(8)
  decoder.feed(b"VALUE k 0 100\r\nabc")
  try {
    ignore(decoder.next())
    abort("expected a malformed error")
  } catch {
    ProtocolError::Malformed(message) =>
      assert_eq(
        message, "a VALUE block of 100 bytes needs 122 bytes with its header and the END line, more than the 8-byte block limit",
      )
    _ => abort("expected a malformed error")
  }
}

///|
test "decode_status hands back the offset it was given" {
  let (response, offset) = decode_status("STORED".view(), 9)
  assert_true(response == Response::Status(Status::Stored))
  assert_eq(offset, 9)
}

///|
test "decode_line renders utf-8 keys as text" {
  assert_eq(decode_line(b"VALUE 键 0 3".view()), "VALUE 键 0 3")
  assert_eq(decode_line(b"END".view()), "END")
}

///|
test "an incomplete response is not an error" {
  assert_eq(response_outcome(b""), "ok")
  assert_eq(response_outcome(b"STORED\r"), "ok")
  assert_eq(response_outcome(b"VALUE k 0 3\r\nab"), "ok")
}

///|
test "a retrieval with many blocks decodes every block" {
  let builder = StringBuilder()
  for i in 0..<64 {
    builder.write_string("VALUE k\{i} 0 1\r\nx\r\n")
  }
  builder.write_string("END\r\n")
  let input = @utf8.encode(builder.to_string().view())
  match decode_response(input.view(), DEFAULT_BUFFER_LIMIT) {
    Some((Response::Values(values), consumed)) => {
      assert_eq(values.length(), 64)
      assert_eq(values[0].key, "k0")
      assert_eq(values[63].key, "k63")
      assert_eq(values[63].data, b"x")
      assert_eq(consumed, input.length())
    }
    _ => abort("expected a retrieval response")
  }
}

///|
test "a response of the wrong kind is reported as malformed" {
  assert_eq(values_outcome(Response::Values([])), "ok")
  assert_eq(values_outcome(Response::Status(Status::Stored)), "malformed")
  assert_eq(status_outcome(Response::Status(Status::Stored)), "ok")
  assert_eq(status_outcome(Response::Counter(1UL)), "malformed")
  assert_eq(counter_outcome(Response::Counter(7UL)), "ok")
  assert_eq(counter_outcome(Response::Values([])), "malformed")
}

///|
test "key validation enforces the byte rules of the command line" {
  assert_eq(key_outcome("foo"), "ok")
  assert_eq(key_outcome("!"), "ok")
  assert_eq(key_outcome("键"), "ok")
  assert_eq(key_outcome(""), "malformed")
  assert_eq(key_outcome("has space"), "malformed")
  assert_eq(key_outcome("has\ttab"), "malformed")
  assert_eq(key_outcome("has\rreturn"), "malformed")
  assert_eq(key_outcome("has\nnewline"), "malformed")
  assert_eq(key_outcome("\u{1F}"), "malformed")
  assert_eq(key_outcome("\u{7F}"), "malformed")
}

///|
test "key validation measures length in utf-8 bytes" {
  assert_eq(key_outcome(ascii_key(250)), "ok")
  assert_eq(key_outcome(ascii_key(251)), "malformed")
  assert_eq(key_outcome(wide_key(83)), "ok")
  assert_eq(key_outcome(wide_key(84)), "malformed")
}

///|
test "a rejected key is quoted and its rule is spelt out" {
  // The key comes from application data, so the message has to say which key
  // was refused and which rule it broke.
  assert_eq(key_message(""), "a key cannot be empty")
  // The key is quoted through `quote`, so a key too long to print is cut while
  // the byte count beside it still reports how long the key really was.
  assert_eq(
    key_message(ascii_key(251)),
    "key '\{ascii_key(64)}...' is 251 bytes, more than the 250 bytes a key may hold",
  )
  // A byte a command line cannot carry arrives beside the key it was found in,
  // escaped the same way `quote` escapes peer data, so a tab or a delete stays
  // visible instead of reaching the message as itself.
  assert_eq(
    key_message("has\ttab"),
    "key 'has\\ttab' holds a blank or control byte a command line cannot carry: '\\t'",
  )
  assert_eq(
    key_message("has space"),
    "key 'has space' holds a blank or control byte a command line cannot carry: ' '",
  )
  assert_eq(
    key_message("\u{7F}"),
    "key '\\u{7f}' holds a blank or control byte a command line cannot carry: '\\u{7f}'",
  )
}

///|
test "request validation covers every command that carries a key" {
  let bad = "bad key"
  assert_eq(request_outcome(Request::Quit), "ok")
  assert_eq(request_outcome(Request::Version), "ok")
  assert_eq(request_outcome(Request::Stats(sub=None)), "ok")
  assert_eq(request_outcome(Request::Stats(sub=Some("items"))), "ok")
  // A section may take arguments, which the server reads as further words.
  assert_eq(request_outcome(Request::Stats(sub=Some("detail on"))), "ok")
  assert_eq(request_outcome(Request::Stats(sub=Some("cachedump 1 100"))), "ok")
  assert_eq(
    request_outcome(Request::Stats(sub=Some("bad\tsection"))),
    "malformed",
  )
  assert_eq(request_outcome(Request::Stats(sub=Some(""))), "malformed")
  assert_eq(request_outcome(Request::Stats(sub=Some(" "))), "malformed")
  assert_eq(request_outcome(Request::Stats(sub=Some("items "))), "malformed")
  assert_eq(request_outcome(Request::Stats(sub=Some(" items"))), "malformed")
  assert_eq(
    request_outcome(Request::Stats(sub=Some("detail  on"))),
    "malformed",
  )
  assert_eq(request_outcome(Request::FlushAll(delay=None, noreply=false)), "ok")
  assert_eq(
    request_outcome(Request::FlushAll(delay=Some(10), noreply=false)),
    "ok",
  )
  assert_eq(
    request_outcome(Request::FlushAll(delay=Some(-1), noreply=false)),
    "malformed",
  )
  assert_eq(request_outcome(Request::Verbosity(level=0, noreply=false)), "ok")
  assert_eq(
    request_outcome(Request::Verbosity(level=-1, noreply=false)),
    "malformed",
  )
  assert_eq(request_outcome(Request::Delete(key="foo", noreply=false)), "ok")
  assert_eq(request_outcome(Request::Get(keys=["foo"], with_cas=false)), "ok")
  assert_eq(request_outcome(Request::Get(keys=[], with_cas=true)), "malformed")
  assert_eq(
    request_outcome(Request::Get(keys=["ok", bad], with_cas=false)),
    "malformed",
  )
  assert_eq(
    request_outcome(Request::Gat(keys=["foo"], exptime=0, with_cas=false)),
    "ok",
  )
  assert_eq(
    request_outcome(Request::Gat(keys=[], exptime=0, with_cas=true)),
    "malformed",
  )
  assert_eq(
    request_outcome(Request::Gat(keys=[bad], exptime=0, with_cas=false)),
    "malformed",
  )
  assert_eq(
    request_outcome(Request::Touch(key="foo", exptime=0, noreply=false)),
    "ok",
  )
  assert_eq(
    request_outcome(Request::Touch(key=bad, exptime=0, noreply=true)),
    "malformed",
  )
  assert_eq(
    request_outcome(
      Request::Storage(
        op=Set,
        key=bad,
        flags=0,
        exptime=0,
        value=b"x",
        cas=None,
        noreply=false,
      ),
    ),
    "malformed",
  )
  assert_eq(
    request_outcome(Request::Delete(key=bad, noreply=true)),
    "malformed",
  )
  assert_eq(
    request_outcome(Request::Incr(key=bad, delta=1UL, noreply=false)),
    "malformed",
  )
  assert_eq(
    request_outcome(Request::Decr(key=bad, delta=1UL, noreply=false)),
    "malformed",
  )
}

///|
test "a rejected stats section names the hole it would leave" {
  // The words of the section are what the server reads, so a space is only
  // legal between two of them. Whichever way the hole is left -- no section,
  // leading, trailing or doubled space -- the message is the same one.
  assert_eq(
    section_message(""),
    "stats section is 0 bytes, outside the 1..250 bytes this client allows: ''",
  )
  assert_eq(section_message(" "), "stats section has an empty word: ' '")
  assert_eq(
    section_message("items "),
    "stats section has an empty word: 'items '",
  )
  assert_eq(
    section_message(" items"),
    "stats section has an empty word: ' items'",
  )
  assert_eq(
    section_message("detail  on"),
    "stats section has an empty word: 'detail  on'",
  )
  // A byte that can be neither a word byte nor a separator is reported as
  // itself, escaped, so the section it came in stays recognisable.
  assert_eq(
    section_message("bad\tsection"),
    "stats section has a byte a command line cannot carry: 'bad\\tsection'",
  )
  // The cap is the one borrowed from keys; the message says so by calling it
  // what this client allows rather than what the server requires, and the
  // quoted section is cut by the same rule as any other quoted text.
  assert_eq(
    section_message(ascii_key(251)),
    "stats section is 251 bytes, outside the 1..250 bytes this client allows: '\{ascii_key(64)}...'",
  )
}

///|
test "a STAT line splits at its first space only" {
  let simple = parse_stat_line(b"STAT pid 1234".view())
  assert_eq(simple.name, "pid")
  assert_eq(simple.value, "1234")

  // A value may contain spaces, so only the first one separates the fields.
  let versioned = parse_stat_line(b"STAT libevent 2.1.12-stable".view())
  assert_eq(versioned.name, "libevent")
  assert_eq(versioned.value, "2.1.12-stable")

  // A section nests its dimension into the name rather than into a new field.
  let nested = parse_stat_line(b"STAT items:1:number 2".view())
  assert_eq(nested.name, "items:1:number")
  assert_eq(nested.value, "2")

  assert_eq(stat_outcome(b"STAT noseparator".view()), "malformed")
  assert_eq(stat_outcome(b"STAT ".view()), "malformed")
  assert_eq(stat_outcome(b"STORED".view()), "malformed")
  // The first space separates the fields, so one that opens the name leaves
  // the entry without a name to report.
  assert_eq(stat_outcome(b"STAT  pid 1".view()), "malformed")
  assert_eq(stat_outcome(b"STAT  1".view()), "malformed")
}

///|
test "an error message escapes and cuts the peer data it quotes" {
  assert_eq(quote("STAT pid 1".view()), "STAT pid 1")
  assert_eq(quote("VALUE \r\n k".view()), "VALUE \\r\\n k")
  assert_eq(quote("\u{7F}".view()), "\\u{7f}")
  // A long line is cut so that the reason for the failure stays readable.
  assert_eq(quote(ascii_key(100).view()), ascii_key(64) + "...")
}

///|
test "the first STAT line belongs to the section" {
  let input = b"STAT pid 1234\r\nEND\r\n"
  match decode_stats(input.view()) {
    Some((Response::Stats(entries), consumed)) => {
      assert_eq(entries.length(), 1)
      assert_eq(entries[0].name, "pid")
      assert_eq(consumed, input.length())
    }
    _ => abort("expected a stats response")
  }
  assert_eq(stats_outcome(b"STAT pid 1\r\n"), "ok")
  assert_eq(stats_outcome(b"STAT pid 1\r\nEND"), "ok")
  assert_eq(stats_outcome(b"STAT pid 1\r\nSTORED\r\n"), "malformed")
}

///|
test "a version line keeps the text that follows its prefix" {
  let input = b"VERSION 1.6.21\r\n"
  match decode_response(input.view(), DEFAULT_BUFFER_LIMIT) {
    Some((Response::Version(version), consumed)) => {
      // The prefix is eight bytes long, so a shorter offset would keep part of
      // it (`" 1.6.21"`) inside the version string.
      assert_eq(version, "1.6.21")
      assert_eq(consumed, input.length())
    }
    _ => abort("expected a version response")
  }
  assert_eq(response_outcome(b"VERSION"), "ok")
}

///|
test "a decoder reports the buffer limit it was given" {
  assert_eq(Decoder::new().limit(), DEFAULT_BUFFER_LIMIT)
  assert_eq(Decoder::with_limit(16).limit(), 16)
}

///|
test "a decoder below its limit keeps waiting" {
  // The header asks for 100 bytes and the limit holds them together with their
  // framing, so the three bytes that arrived are only a prefix and the decoder
  // waits for the rest.
  let decoder = Decoder::with_limit(128)
  decoder.feed(b"VALUE k 0 100\r\nabc")
  assert_true(decoder.next() is None)
  assert_eq(decoder.buffered(), 18)
}

///|
test "a decoder past its limit reports a desynchronised stream" {
  // Here the block and its framing all fit in the limit - it is the bytes that
  // keep piling up after it without ever closing the retrieval that break the
  // cap, which is what `Desynchronised` is for.
  let decoder = Decoder::with_limit(24)
  decoder.feed(b"VALUE k 0 4\r\nabcd\r\nstill no END")
  try {
    ignore(decoder.next())
    abort("expected a desynchronised error")
  } catch {
    ProtocolError::Desynchronised(limit, buffered) => {
      assert_eq(limit, 24)
      assert_eq(buffered, 31)
    }
    _ => abort("expected a desynchronised error")
  }
}

///|
test "a retrieval of several blocks is measured per header, not as a total" {
  // Every header is measured against the whole limit, so two blocks of 11 + 4 +
  // 9 = 24 bytes each pass a 30-byte limit. The retrieval they build is 43 bytes
  // long, and that is not what the limit bounds: it bounds what is *waiting* to
  // be decoded, so a reply that arrives whole is decoded as it stands.
  let whole = Decoder::with_limit(30)
  whole.feed(b"VALUE k 0 4\r\nabcd\r\nVALUE k 0 4\r\nabcd\r\nEND\r\n")
  match whole.next() {
    Some(Response::Values(values)) => assert_eq(values.length(), 2)
    _ => abort("expected the whole retrieval to decode")
  }
  // Arriving in pieces it is a different story: 36 bytes buffered without an END
  // is more than this decoder holds. No header was refused along the way, so the
  // report names the buffer rather than the block.
  let partial = Decoder::with_limit(30)
  partial.feed(b"VALUE k 0 4\r\nabcd\r\nVALUE k 0 4\r\nabcd")
  try {
    ignore(partial.next())
    abort("expected a desynchronised error")
  } catch {
    ProtocolError::Desynchronised(limit, buffered) => {
      assert_eq(limit, 30)
      assert_eq(buffered, 36)
    }
    _ => abort("expected a desynchronised error")
  }
}

///|
test "resync drops a fragment that lost its framing" {
  let decoder = Decoder::with_limit(24)
  decoder.feed(b"VALUE k 0 4\r\nabcd\r\nstill no END")
  assert_eq(decoder.buffered(), 31)
  decoder.resync()
  assert_eq(decoder.buffered(), 0)
  decoder.feed(b"STORED\r\n")
  assert_true(decoder.next() is Some(Response::Status(Status::Stored)))
}

///|
test "request validation covers the administrative commands" {
  assert_eq(
    request_outcome(Request::CacheMemlimit(megabytes=64, noreply=false)),
    "ok",
  )
  assert_eq(
    request_outcome(Request::CacheMemlimit(megabytes=0, noreply=true)),
    "ok",
  )
  assert_eq(
    request_outcome(Request::CacheMemlimit(megabytes=-1, noreply=false)),
    "malformed",
  )
  assert_eq(
    request_outcome(Request::SlabsReassign(src=1, dst=2, noreply=false)),
    "ok",
  )
  assert_eq(
    request_outcome(Request::SlabsReassign(src=-1, dst=-1, noreply=false)),
    "ok",
  )
  assert_eq(
    request_outcome(Request::SlabsReassign(src=-2, dst=1, noreply=false)),
    "malformed",
  )
  assert_eq(
    request_outcome(Request::SlabsReassign(src=1, dst=-2, noreply=false)),
    "malformed",
  )
  assert_eq(
    request_outcome(Request::SlabsAutomove(mode=0, noreply=false)),
    "ok",
  )
  assert_eq(
    request_outcome(Request::SlabsAutomove(mode=2, noreply=false)),
    "ok",
  )
  assert_eq(
    request_outcome(Request::SlabsAutomove(mode=3, noreply=false)),
    "malformed",
  )
  assert_eq(
    request_outcome(Request::SlabsAutomove(mode=-1, noreply=false)),
    "malformed",
  )
}

///|
/// How `validate_pipeline` reacts to `requests`.
fn pipeline_outcome(requests : Array[Request]) -> String {
  try {
    validate_pipeline(requests)
    "ok"
  } catch {
    err => name_of(err)
  }
}

///|
/// How `Decoder::next` reacts to the bytes already fed into `decoder`.
fn next_outcome(decoder : Decoder) -> String {
  try {
    ignore(decoder.next())
    "ok"
  } catch {
    err => name_of(err)
  }
}

///|
test "a remote line is consumed and a malformed one is kept" {
  let remote = Decoder::new()
  remote.feed(b"ERROR\r\nSTORED\r\n")
  assert_eq(next_outcome(remote), "generic")
  // The reported line is behind the reader now, which is what lets the reply
  // that followed it be read at all.
  assert_eq(remote.buffered(), 8)
  match remote.next() {
    Some(Response::Status(Status::Stored)) => ()
    _ => abort("expected the reply behind the error line")
  }

  let malformed = Decoder::new()
  malformed.feed(b"WHAT\r\nSTORED\r\n")
  assert_eq(next_outcome(malformed), "malformed")
  // A line that cannot be read as a response stays where it is: nothing here
  // knows where the next response would begin, so resync is the way out.
  assert_eq(malformed.buffered(), 14)
}

///|
test "a batch reads one reply per answering slot, in order" {
  let connection = ScriptedConnection::new([b"STORED\r\n", b"OK\r\n"])
  let client = Client::new(connection)
  // The middle slot is a `noreply` request, so it costs no read at all and the
  // second response on the wire belongs to the third slot.
  let responses = client.read_replies([true, false, true])
  assert_eq(responses.length(), 3)
  match responses[0] {
    Some(Response::Status(Status::Stored)) => ()
    _ => abort("expected the first slot to hold STORED")
  }
  assert_true(responses[1] is None)
  match responses[2] {
    Some(Response::Status(Status::Ok)) => ()
    _ => abort("expected the third slot to hold OK")
  }
}

///|
test "a batch counts the replies it is still owed from a slot on" {
  assert_eq(remaining_reply_count([true, false, true], 0), 2)
  assert_eq(remaining_reply_count([true, false, true], 1), 1)
  assert_eq(remaining_reply_count([true, false, true], 2), 1)
  assert_eq(remaining_reply_count([true, false, true], 3), 0)
  assert_eq(remaining_reply_count([false, false], 0), 0)
  assert_eq(remaining_reply_count([true, true], 1), 1)
}

///|
test "a pipeline refuses quit wherever it sits and checks every request" {
  assert_eq(pipeline_outcome([]), "ok")
  assert_eq(pipeline_outcome([Request::Version]), "ok")
  assert_eq(pipeline_outcome([Request::Quit]), "malformed")
  assert_eq(pipeline_outcome([Request::Quit, Request::Version]), "malformed")
  assert_eq(pipeline_outcome([Request::Version, Request::Quit]), "malformed")
  // The check that a single request gets is applied to every member of the
  // batch, so a bad request is found wherever it sits.
  assert_eq(
    pipeline_outcome([Request::Version, Request::Delete(key="", noreply=true)]),
    "malformed",
  )
}

///|
test "dropping replies leaves the next response to be read" {
  let connection = ScriptedConnection::new([
    b"STORED\r\n", b"NOT_STORED\r\n", b"OK\r\n",
  ])
  let client = Client::new(connection)
  client.discard_replies(2)
  match client.read_response() {
    Response::Status(Status::Ok) => ()
    _ => abort("expected the third reply")
  }
}

///|
test "dropping replies swallows a failure a dead connection causes" {
  let connection = ScriptedConnection::new([])
  let client = Client::new(connection)
  // Nothing is left to read, so the drop fails at once and says nothing: the
  // reply it could not read is worthless to whoever is about to hear why the
  // pipeline stopped.
  client.discard_replies(3)
}
