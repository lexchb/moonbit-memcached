// Codec for the memcached *text* protocol.
//
// The package only deals with the wire format: encoding requests into bytes
// and decoding responses out of bytes. It is transport agnostic, so it can be
// exercised without a running memcached server.

///|
/// Kind of error reported by the server on a `*_ERROR` response line.
pub enum RemoteErrorKind {
  /// `ERROR`: the server did not recognise the command.
  Generic
  /// `CLIENT_ERROR`: the request line was malformed.
  Client
  /// `SERVER_ERROR`: the server failed while executing the request.
  Server
} derive(Eq, @debug.Debug)

///|
/// Raised when a response cannot be decoded.
pub suberror ProtocolError {
  /// The server answered `ERROR`, `CLIENT_ERROR` or `SERVER_ERROR`.
  Remote(RemoteErrorKind, String)
  /// The bytes on the wire do not follow the memcached text protocol.
  Malformed(String)
} derive(@debug.Debug)

///|
/// Storage commands of the text protocol.
pub(all) enum StorageOp {
  Set
  Add
  Replace
  Append
  Prepend
  Cas
} derive(Eq, @debug.Debug)

///|
/// A single memcached text protocol request.
pub(all) enum Request {
  /// `<op> <key> <flags> <exptime> <bytes> [<cas unique>]\r\n<data>\r\n`.
  ///
  /// The byte count is derived from `value` at encoding time.
  Storage(
    op~ : StorageOp,
    key~ : String,
    flags~ : Int,
    exptime~ : Int,
    value~ : Bytes,
    cas~ : UInt64?
  )
  /// `get <key>+` or `gets <key>+`, depending on `with_cas`.
  Get(keys~ : Array[String], with_cas~ : Bool)
  /// `delete <key>`.
  Delete(key~ : String)
  /// `incr <key> <delta>`.
  Incr(key~ : String, delta~ : UInt64)
  /// `decr <key> <delta>`.
  Decr(key~ : String, delta~ : UInt64)
  /// `quit`.
  Quit
} derive(Eq, @debug.Debug)

///|
/// One `VALUE` block of a retrieval response.
pub struct RetrievedValue {
  key : String
  flags : Int
  data : Bytes
  /// Present only for `gets`.
  cas : UInt64?
} derive(Eq, @debug.Debug)

///|
/// Terminal status line of a mutation command.
pub(all) enum Status {
  Stored
  NotStored
  Exists
  NotFound
  Deleted
  Touched
} derive(Eq, @debug.Debug)

///|
/// A decoded server response.
pub enum Response {
  /// Result of `get`/`gets`: zero or more `VALUE` blocks.
  Values(Array[RetrievedValue])
  /// Result of a storage or `delete` command.
  Status(Status)
  /// Result of `incr`/`decr`: the value the counter holds afterwards.
  Counter(UInt64)
} derive(Eq, @debug.Debug)

///|
/// The command word sent for a storage operation.
fn StorageOp::name(self : StorageOp) -> StringView {
  match self {
    Set => "set"
    Add => "add"
    Replace => "replace"
    Append => "append"
    Prepend => "prepend"
    Cas => "cas"
  }
}

///|
/// Encode `self` into the bytes to write to the server.
pub fn Request::to_bytes(self : Request) -> Bytes {
  let buf = @buffer.Buffer()
  match self {
    Storage(op~, key~, flags~, exptime~, value~, cas~) => {
      buf.write_string_utf8(op.name())
      buf.write_byte(b' ')
      buf.write_string_utf8(key)
      buf.write_string_utf8(" \{flags} \{exptime} \{value.length()}")
      if cas is Some(unique) {
        buf.write_string_utf8(" \{unique}")
      }
      buf.write_bytes(b"\r\n")
      buf.write_bytes(value)
      buf.write_bytes(b"\r\n")
    }
    Get(keys~, with_cas~) => {
      buf.write_string_utf8(if with_cas { "gets" } else { "get" })
      for key in keys {
        buf.write_byte(b' ')
        buf.write_string_utf8(key)
      }
      buf.write_bytes(b"\r\n")
    }
    Delete(key~) => {
      buf.write_string_utf8("delete ")
      buf.write_string_utf8(key)
      buf.write_bytes(b"\r\n")
    }
    Incr(key~, delta~) => buf.write_string_utf8("incr \{key} \{delta}\r\n")
    Decr(key~, delta~) => buf.write_string_utf8("decr \{key} \{delta}\r\n")
    Quit => buf.write_string_utf8("quit\r\n")
  }
  buf.to_bytes()
}

///|
/// Offset of the first `\r\n` in `bytes`, if there is one.
fn find_crlf(bytes : BytesView) -> Int? {
  bytes.find(b"\r\n")
}

///|
/// Whether `s` is a non-empty run of ASCII digits.
fn is_decimal(s : StringView) -> Bool {
  if s.length() == 0 {
    return false
  }
  for c in s.iter() {
    if !c.is_ascii_digit() {
      return false
    }
  }
  true
}

///|
/// Parse a non-negative decimal `UInt64` from `s`.
///
/// `what` names the field and is only used to build the error message.
fn parse_decimal(s : StringView, what : String) -> UInt64 raise ProtocolError {
  guard is_decimal(s) else {
    raise Malformed("expected \{what}, found '\{s.to_owned()}'")
  }
  @string.parse_uint64(s) catch {
    _ => raise Malformed("expected \{what}, found '\{s.to_owned()}'")
  }
}

///|
/// Parse a non-negative decimal that has to fit in a 32-bit signed `Int`.
fn parse_decimal_int(s : StringView, what : String) -> Int raise ProtocolError {
  let n = parse_decimal(s, what)
  guard n <= 0x7FFFFFFFUL else {
    raise Malformed("\{what} out of range: '\{s.to_owned()}'")
  }
  n.to_int()
}

///|
/// Decode a response line into a string.
///
/// Header lines are ASCII, but keys travel as UTF-8, so the bytes are decoded
/// as UTF-8. `BytesView::to_string` must not be used here: it goes through
/// `Show` and yields the `b"..."` rendering of the bytes, not the text.
fn decode_line(bytes : BytesView) -> String {
  @utf8.decode_lossy(bytes)
}

///|
/// Decode a single non-`VALUE` response line.
fn decode_status(
  line : StringView,
  offset : Int,
) -> (Response, Int) raise ProtocolError {
  let text = line.to_owned()
  if text == "STORED" {
    (Response::Status(Status::Stored), offset)
  } else if text == "NOT_STORED" {
    (Response::Status(Status::NotStored), offset)
  } else if text == "EXISTS" {
    (Response::Status(Status::Exists), offset)
  } else if text == "NOT_FOUND" {
    (Response::Status(Status::NotFound), offset)
  } else if text == "DELETED" {
    (Response::Status(Status::Deleted), offset)
  } else if text == "TOUCHED" {
    (Response::Status(Status::Touched), offset)
  } else if text == "ERROR" {
    raise Remote(RemoteErrorKind::Generic, text)
  } else if text.has_prefix("CLIENT_ERROR") {
    raise Remote(RemoteErrorKind::Client, text)
  } else if text.has_prefix("SERVER_ERROR") {
    raise Remote(RemoteErrorKind::Server, text)
  } else if is_decimal(text.view()) {
    (Response::Counter(parse_decimal(text.view(), "counter value")), offset)
  } else {
    raise Malformed("unexpected response line '\{text}'")
  }
}

///|
/// The fields of one `VALUE <key> <flags> <bytes> [<cas unique>]` header line.
priv struct ValueHeader {
  key : String
  flags : Int
  size : Int
  cas : UInt64?
}

///|
/// Parse a `VALUE <key> <flags> <bytes> [<cas unique>]` header line.
fn parse_value_header(line : String) -> ValueHeader raise ProtocolError {
  let fields = line.view().split(" ").collect()
  guard fields.length() == 4 || fields.length() == 5 else {
    raise Malformed("malformed VALUE line '\{line}'")
  }
  {
    key: fields[1].to_owned(),
    flags: parse_decimal_int(fields[2], "flags"),
    size: parse_decimal_int(fields[3], "bytes"),
    cas: if fields.length() == 5 {
      Some(parse_decimal(fields[4], "cas unique"))
    } else {
      None
    },
  }
}

///|
/// Decode the `VALUE`/`END` blocks of a retrieval response.
///
/// `bytes` is the whole input buffer, `header` is the already-parsed `VALUE`
/// line and `pos` points at the first byte of its data block. `values`
/// accumulates the blocks decoded so far.
fn decode_value_blocks(
  bytes : BytesView,
  header : ValueHeader,
  pos : Int,
  values : Array[RetrievedValue],
) -> (Response, Int)? raise ProtocolError {
  guard pos <= bytes.length() else { return None }
  let remaining = bytes.length() - pos
  guard remaining >= 2 && header.size <= remaining - 2 else { return None }
  guard bytes.view(start=pos + header.size).has_prefix(b"\r\n") else {
    raise Malformed(
      "data block of key '\{header.key}' is not terminated by CRLF",
    )
  }
  values.push({
    key: header.key,
    flags: header.flags,
    data: bytes.view(start=pos, end=pos + header.size).to_owned(),
    cas: header.cas,
  })
  let next = pos + header.size + 2
  guard find_crlf(bytes.view(start=next)) is Some(eol) else { return None }
  let line = decode_line(bytes.view(start=next, end=next + eol))
  if line == "END" {
    return Some((Response::Values(values), next + eol + 2))
  }
  guard line.has_prefix("VALUE ") else {
    raise Malformed("expected 'VALUE' or 'END', found '\{line}'")
  }
  decode_value_blocks(bytes, parse_value_header(line), next + eol + 2, values)
}

///|
/// Decode one complete response from `bytes`.
///
/// Returns the response together with the number of bytes it occupies, or
/// `None` when `bytes` holds only a prefix of a response.
fn decode_response(bytes : BytesView) -> (Response, Int)? raise ProtocolError {
  guard find_crlf(bytes) is Some(eol) else { return None }
  let line = decode_line(bytes.view(end=eol))
  let offset = eol + 2
  if line.has_prefix("VALUE ") {
    decode_value_blocks(bytes, parse_value_header(line), offset, [])
  } else if line == "END" {
    Some((Response::Values([]), offset))
  } else {
    Some(decode_status(line.view(), offset))
  }
}

///|
/// Incremental decoder for server responses.
///
/// A single read may deliver a partial response, and a single read may deliver
/// several responses at once; feeding bytes and pulling complete responses
/// keeps the two concerns apart.
pub struct Decoder {
  mut buffer : Bytes
}

///|
pub fn Decoder::new() -> Decoder {
  { buffer: Bytes::new(0) }
}

///|
/// Append freshly received bytes to the decoder.
pub fn Decoder::feed(self : Decoder, data : BytesView) -> Unit {
  self.buffer = Bytes::add(self.buffer, data.to_owned())
}

///|
/// Number of buffered bytes that have not been consumed yet.
pub fn Decoder::buffered(self : Decoder) -> Int {
  self.buffer.length()
}

///|
/// Decode the next complete response.
///
/// Returns `None` when the buffered bytes are only a prefix of a response, in
/// which case the caller should `feed` more data. The decoded bytes are
/// consumed from the buffer, so responses can be pulled in a loop.
pub fn Decoder::next(self : Decoder) -> Response? raise ProtocolError {
  match decode_response(self.buffer.view()) {
    None => None
    Some((response, consumed)) => {
      self.buffer = self.buffer.view(start=consumed).to_owned()
      Some(response)
    }
  }
}
