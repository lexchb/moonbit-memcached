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
/// How `parse_value_header` reacts to `line`.
fn header_outcome(line : String) -> String {
  try {
    ignore(parse_value_header(line))
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
    ignore(decode_response(input.view()))
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
  let plain = parse_value_header("VALUE foo 7 3")
  assert_eq(plain.key, "foo")
  assert_eq(plain.flags, 7)
  assert_eq(plain.size, 3)
  assert_true(plain.cas is None)

  let with_cas = parse_value_header("VALUE foo 7 3 42")
  assert_true(with_cas.cas is Some(42UL))

  let unicode = parse_value_header("VALUE 键 0 3")
  assert_eq(unicode.key, "键")

  assert_eq(header_outcome("VALUE foo 7"), "malformed")
  assert_eq(header_outcome("VALUE foo 7 3 42 99"), "malformed")
  assert_eq(header_outcome("VALUE foo x 3"), "malformed")
  assert_eq(header_outcome("VALUE foo 7 x"), "malformed")
  assert_eq(header_outcome("VALUE foo 4294967296 3"), "malformed")
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
  match decode_response(input.view()) {
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
test "request validation covers every command that carries a key" {
  let bad = "bad key"
  assert_eq(request_outcome(Request::Quit), "ok")
  assert_eq(request_outcome(Request::Delete(key="foo")), "ok")
  assert_eq(request_outcome(Request::Get(keys=["foo"], with_cas=false)), "ok")
  assert_eq(request_outcome(Request::Get(keys=[], with_cas=true)), "malformed")
  assert_eq(
    request_outcome(Request::Get(keys=["ok", bad], with_cas=false)),
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
      ),
    ),
    "malformed",
  )
  assert_eq(request_outcome(Request::Delete(key=bad)), "malformed")
  assert_eq(request_outcome(Request::Incr(key=bad, delta=1UL)), "malformed")
  assert_eq(request_outcome(Request::Decr(key=bad, delta=1UL)), "malformed")
}
