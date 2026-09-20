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
  /// The decoder buffered more bytes than it accepts without ever seeing a
  /// whole response: the stream lost its framing.
  ///
  /// The fields are the accepted limit and the number of buffered bytes, in
  /// that order.
  Desynchronised(Int, Int)
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
///
/// Every command the server acknowledges carries a `noreply` flag: set it to
/// send the command without waiting for the answer. [`Request::expects_reply`]
/// reports that decision, so the client knows whether there is anything to
/// read back.
pub(all) enum Request {
  /// `<op> <key> <flags> <exptime> <bytes> [<cas unique>] [noreply]\r\n<data>\r\n`.
  ///
  /// The byte count is derived from `value` at encoding time.
  Storage(
    op~ : StorageOp,
    key~ : String,
    flags~ : Int,
    exptime~ : Int,
    value~ : Bytes,
    cas~ : UInt64?,
    noreply~ : Bool
  )
  /// `get <key>+` or `gets <key>+`, depending on `with_cas`.
  ///
  /// Retrievals always have an answer, so they take no `noreply`.
  Get(keys~ : Array[String], with_cas~ : Bool)
  /// `gat <exptime> <key>+` or `gats <exptime> <key>+`: fetch and touch.
  Gat(keys~ : Array[String], exptime~ : Int, with_cas~ : Bool)
  /// `delete <key> [noreply]`.
  Delete(key~ : String, noreply~ : Bool)
  /// `incr <key> <delta> [noreply]`.
  Incr(key~ : String, delta~ : UInt64, noreply~ : Bool)
  /// `decr <key> <delta> [noreply]`.
  Decr(key~ : String, delta~ : UInt64, noreply~ : Bool)
  /// `touch <key> <exptime> [noreply]`.
  Touch(key~ : String, exptime~ : Int, noreply~ : Bool)
  /// `version`, answered with a `VERSION <string>` line.
  Version
  /// `stats [<subcommand>]`, answered with `STAT` lines up to `END`.
  ///
  /// A subcommand is one or more words (`items`, `detail on`,
  /// `cachedump <slab> <limit>`); they are written out as the words appear,
  /// separated by single spaces.
  Stats(sub~ : String?)
  /// `flush_all [<delay>] [noreply]`, answered with `OK`.
  FlushAll(delay~ : Int?, noreply~ : Bool)
  /// `verbosity <level> [noreply]`, answered with `OK`.
  Verbosity(level~ : Int, noreply~ : Bool)
  /// `cache_memlimit <megabytes> [noreply]`, answered with `OK`.
  CacheMemlimit(megabytes~ : Int, noreply~ : Bool)
  /// `slabs reassign <src> <dst> [noreply]`, answered with `OK`.
  ///
  /// A `src` of `-1` lets the server pick the source slab itself.
  SlabsReassign(src~ : Int, dst~ : Int, noreply~ : Bool)
  /// `slabs automove <mode> [noreply]`, answered with `OK`.
  ///
  /// `mode` is `0` (off), `1` (on) or `2` (aggressive).
  SlabsAutomove(mode~ : Int, noreply~ : Bool)
  /// `quit`.
  Quit
} derive(Eq, @debug.Debug)

///|
/// Whether the server answers `self`.
///
/// `quit` is never answered, and a mutation that carries `noreply` suppresses
/// its terminal line, so both leave the connection without a response to read.
pub fn Request::expects_reply(self : Request) -> Bool {
  match self {
    Storage(noreply~, ..) => !noreply
    Delete(noreply~, ..) => !noreply
    Incr(noreply~, ..) => !noreply
    Decr(noreply~, ..) => !noreply
    Touch(noreply~, ..) => !noreply
    FlushAll(noreply~, ..) => !noreply
    Verbosity(noreply~, ..) => !noreply
    CacheMemlimit(noreply~, ..) => !noreply
    SlabsReassign(noreply~, ..) => !noreply
    SlabsAutomove(noreply~, ..) => !noreply
    Get(..) => true
    Gat(..) => true
    Version => true
    Stats(..) => true
    Quit => false
  }
}

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
  /// `OK`, the acknowledgement of `flush_all` and `verbosity`.
  Ok
} derive(Eq, @debug.Debug)

///|
/// One `STAT <name> <value>` line of a `stats` response.
///
/// The value is kept as text: memcached reports both numbers and free-form
/// strings (`STAT version 1.6.21`), and a section such as `stats items` nests
/// its dimension into the name (`items:1:number`).
pub struct StatEntry {
  name : String
  value : String
} derive(Eq, @debug.Debug)

///|
/// A decoded server response.
pub enum Response {
  /// Result of `get`/`gets`/`gat`/`gats`: zero or more `VALUE` blocks.
  Values(Array[RetrievedValue])
  /// Result of a storage or `delete` command.
  Status(Status)
  /// Result of `incr`/`decr`: the value the counter holds afterwards.
  Counter(UInt64)
  /// Result of `version`.
  Version(String)
  /// Result of `stats`: the `STAT` lines up to `END`.
  Stats(Array[StatEntry])
} derive(Eq, @debug.Debug)

///|
/// Prefix of the `VERSION <string>` response line.
const VERSION_PREFIX : String = "VERSION "

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
/// Append the optional `noreply` word of an acknowledged command.
fn write_noreply(buf : @buffer.Buffer, noreply : Bool) -> Unit {
  if noreply {
    buf.write_string_utf8(" noreply")
  }
}

///|
/// Encode `self` into the bytes to write to the server.
pub fn Request::to_bytes(self : Request) -> Bytes {
  let buf = @buffer.Buffer()
  match self {
    Storage(op~, key~, flags~, exptime~, value~, cas~, noreply~) => {
      buf.write_string_utf8(op.name())
      buf.write_byte(b' ')
      buf.write_string_utf8(key)
      buf.write_string_utf8(" \{flags} \{exptime} \{value.length()}")
      if cas is Some(unique) {
        buf.write_string_utf8(" \{unique}")
      }
      write_noreply(buf, noreply)
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
    Gat(keys~, exptime~, with_cas~) => {
      buf.write_string_utf8(if with_cas { "gats" } else { "gat" })
      buf.write_string_utf8(" \{exptime}")
      for key in keys {
        buf.write_byte(b' ')
        buf.write_string_utf8(key)
      }
      buf.write_bytes(b"\r\n")
    }
    Delete(key~, noreply~) => {
      buf.write_string_utf8("delete \{key}")
      write_noreply(buf, noreply)
      buf.write_bytes(b"\r\n")
    }
    Incr(key~, delta~, noreply~) => {
      buf.write_string_utf8("incr \{key} \{delta}")
      write_noreply(buf, noreply)
      buf.write_bytes(b"\r\n")
    }
    Decr(key~, delta~, noreply~) => {
      buf.write_string_utf8("decr \{key} \{delta}")
      write_noreply(buf, noreply)
      buf.write_bytes(b"\r\n")
    }
    Touch(key~, exptime~, noreply~) => {
      buf.write_string_utf8("touch \{key} \{exptime}")
      write_noreply(buf, noreply)
      buf.write_bytes(b"\r\n")
    }
    Version => buf.write_string_utf8("version\r\n")
    Stats(sub~) => {
      buf.write_string_utf8("stats")
      if sub is Some(name) {
        buf.write_byte(b' ')
        buf.write_string_utf8(name)
      }
      buf.write_bytes(b"\r\n")
    }
    FlushAll(delay~, noreply~) => {
      buf.write_string_utf8("flush_all")
      if delay is Some(seconds) {
        buf.write_string_utf8(" \{seconds}")
      }
      write_noreply(buf, noreply)
      buf.write_bytes(b"\r\n")
    }
    Verbosity(level~, noreply~) => {
      buf.write_string_utf8("verbosity \{level}")
      write_noreply(buf, noreply)
      buf.write_bytes(b"\r\n")
    }
    CacheMemlimit(megabytes~, noreply~) => {
      buf.write_string_utf8("cache_memlimit \{megabytes}")
      write_noreply(buf, noreply)
      buf.write_bytes(b"\r\n")
    }
    SlabsReassign(src~, dst~, noreply~) => {
      buf.write_string_utf8("slabs reassign \{src} \{dst}")
      write_noreply(buf, noreply)
      buf.write_bytes(b"\r\n")
    }
    SlabsAutomove(mode~, noreply~) => {
      buf.write_string_utf8("slabs automove \{mode}")
      write_noreply(buf, noreply)
      buf.write_bytes(b"\r\n")
    }
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
    raise Malformed("expected \{what}, found '\{quote(s)}'")
  }
  @string.parse_uint64(s) catch {
    _ => raise Malformed("expected \{what}, found '\{quote(s)}'")
  }
}

///|
/// Parse a non-negative decimal that has to fit in a 32-bit signed `Int`.
fn parse_decimal_int(s : StringView, what : String) -> Int raise ProtocolError {
  let n = parse_decimal(s, what)
  guard n <= 0x7FFFFFFFUL else {
    raise Malformed("\{what} out of range: '\{quote(s)}'")
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
/// Longest run of peer-supplied characters an error message quotes.
const MAX_QUOTED_CHARS : Int = 64

///|
/// Render peer-supplied text for an error message.
///
/// The text comes off the wire, so it is escaped before it is quoted: a
/// control character would otherwise reach whoever reads the error as-is, and
/// a long line would bury the reason the error was raised. A cut is marked
/// with `...`.
fn quote(text : StringView) -> String {
  let out = StringBuilder()
  let mut quoted = 0
  for c in text.iter() {
    if quoted >= MAX_QUOTED_CHARS {
      out.write_string("...")
      break
    }
    out.write_string(c.escape(quote=false))
    quoted = quoted + 1
  }
  out.to_string()
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
  } else if text == "OK" {
    (Response::Status(Status::Ok), offset)
  } else if text == "ERROR" {
    raise Remote(RemoteErrorKind::Generic, text)
  } else if text.has_prefix("CLIENT_ERROR") {
    raise Remote(RemoteErrorKind::Client, text)
  } else if text.has_prefix("SERVER_ERROR") {
    raise Remote(RemoteErrorKind::Server, text)
  } else if is_decimal(text.view()) {
    (Response::Counter(parse_decimal(text.view(), "counter value")), offset)
  } else {
    raise Malformed("unexpected response line '\{quote(line)}'")
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
/// Bytes a retrieval spends besides the block itself: the CRLF that ends the
/// `VALUE` header line, the CRLF that ends the block, and the `END` line that
/// closes the retrieval. All of them share the buffer with the data, so a block
/// can only be refused for what is left of the limit once they are paid for.
///
/// The literal is the framing itself, so its length is the count: nothing here
/// is added up by hand, and a block is measured against whatever this actually
/// holds. There are two CRLFs because `line` reaches `parse_value_header`
/// with its own already stripped: the one that ended the header is counted here
/// rather than where it was consumed.
///
/// It is named for the retrieval rather than the block because the `END` line
/// belongs to the retrieval that carries the blocks, not to any one block: the
/// smallest reply that can hold a block is what this measures.
const VALUE_RETRIEVAL_FRAMING : Bytes = b"\r\n\r\nEND\r\n"

///|
/// Parse a `VALUE <key> <flags> <bytes> [<cas unique>]` header line.
///
/// `line` is the header without its terminating CRLF, which
/// `VALUE_RETRIEVAL_FRAMING` counts in its place: a caller that passed the
/// raw line would have those two bytes counted twice.
///
/// `limit` is how many bytes the decoder that receives this block accepts
/// buffered. A retrieval has to be buffered whole before it can be decoded, and
/// the smallest reply that can carry this block is its own header line, the
/// block, the CRLF that closes it and the `END` line that closes the retrieval.
/// A declaration that leaves no room for all of that can never be satisfied: it
/// is not a block that is still on its way but a stream this decoder cannot
/// frame, and saying so from the header saves filling the buffer up to `limit`
/// first. The message names `limit`, because the number that is too small may be
/// the caller's configuration rather than the peer's data.
///
/// A retrieval of several keys runs this check once per header, and every block
/// is measured against the whole `limit`, not against what the blocks ahead of
/// it left over - `decode_value_blocks` is the loop that does so. So it is a
/// necessary condition for the sequence rather than a sufficient one: blocks
/// that each fit alone may add up to a retrieval larger than the buffer holds.
/// That a retrieval is long is not by itself a reason to refuse it here, because
/// `limit` bounds what is waiting to be decoded, not how large one response may
/// be: a reply that arrives whole is decoded as it stands. Such a retrieval
/// therefore only fails if it is still incomplete once the buffer is full, and
/// it fails as [`ProtocolError::Desynchronised`] from [`Decoder::next`] - the
/// buffer's verdict rather than a header's.
fn parse_value_header(
  line : String,
  limit : Int,
) -> ValueHeader raise ProtocolError {
  let fields = line.view().split(" ").collect()
  guard fields.length() == 4 || fields.length() == 5 else {
    raise Malformed("malformed VALUE line '\{quote(line.view())}'")
  }
  let size = parse_decimal_int(fields[3], "bytes")
  let needed = @utf8.encode(line.view()).length() +
    size +
    VALUE_RETRIEVAL_FRAMING.length()
  guard needed <= limit else {
    raise Malformed(
      "a VALUE block of \{size} bytes needs \{needed} bytes with its header and the END line, more than the \{limit}-byte block limit",
    )
  }
  {
    key: fields[1].to_owned(),
    flags: parse_decimal_int(fields[2], "flags"),
    size,
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
/// `bytes` is the whole input buffer and `pos` points at the first byte of the
/// first data block, whose header is `header`. The blocks are collected by a
/// loop rather than by recursion, so a retrieval of many keys costs no stack.
/// `limit` is passed on to every header this block sequence turns out to hold,
/// each measured against the whole of it rather than against what the blocks
/// ahead of it left over - `parse_value_header` carries the why and the
/// consequence for a retrieval that outgrows the buffer.
fn decode_value_blocks(
  bytes : BytesView,
  header : ValueHeader,
  pos : Int,
  limit : Int,
) -> (Response, Int)? raise ProtocolError {
  let values : Array[RetrievedValue] = []
  let mut current = header
  let mut cursor = pos
  while true {
    guard cursor <= bytes.length() else { return None }
    let remaining = bytes.length() - cursor
    guard remaining >= 2 && current.size <= remaining - 2 else { return None }
    guard bytes.view(start=cursor + current.size).has_prefix(b"\r\n") else {
      raise Malformed(
        "data block of key '\{quote(current.key.view())}' is not terminated by CRLF",
      )
    }
    values.push({
      key: current.key,
      flags: current.flags,
      data: bytes.view(start=cursor, end=cursor + current.size).to_owned(),
      cas: current.cas,
    })
    // The CRLF that closes the block: the second of the three pieces
    // `VALUE_RETRIEVAL_FRAMING` accounts for. The first is the header's own
    // CRLF, stripped before the line was decoded, and the third is the `END`
    // line further down.
    let next = cursor + current.size + 2
    guard find_crlf(bytes.view(start=next)) is Some(eol) else { return None }
    let line = decode_line(bytes.view(start=next, end=next + eol))
    if line == "END" {
      return Some((Response::Values(values), next + eol + 2))
    }
    guard line.has_prefix("VALUE ") else {
      raise Malformed(
        "expected 'VALUE' or 'END', found '\{quote(line.view())}'",
      )
    }
    current = parse_value_header(line, limit)
    cursor = next + eol + 2
  }
  abort("unreachable")
}

///|
/// Parse one `STAT <name> <value>` line.
///
/// Only the first space separates the two fields, because a value may contain
/// spaces of its own (`STAT libevent 2.1.12-stable` and friends). The name is
/// still a whole word, so a line whose first space opens it (`STAT  pid 1`)
/// has no name to report.
fn parse_stat_line(line : BytesView) -> StatEntry raise ProtocolError {
  let text = decode_line(line)
  guard line.has_prefix(b"STAT ") else {
    raise Malformed("expected a STAT line, found '\{quote(text.view())}'")
  }
  let body = line.view(start=5)
  guard body.find(b" ") is Some(separator) else {
    raise Malformed("malformed STAT line '\{quote(text.view())}'")
  }
  guard separator > 0 else {
    raise Malformed("a STAT line needs a name: '\{quote(text.view())}'")
  }
  {
    name: decode_line(body.view(end=separator)),
    value: decode_line(body.view(start=separator + 1)),
  }
}

///|
/// Decode the `STAT`/`END` block of a `stats` response.
///
/// Unlike a retrieval, a `stats` reply has no header line of its own: the very
/// first line is already a `STAT` line. The section runs until an `END` line.
fn decode_stats(bytes : BytesView) -> (Response, Int)? raise ProtocolError {
  let entries : Array[StatEntry] = []
  let mut cursor = 0
  while true {
    guard cursor <= bytes.length() else { return None }
    guard find_crlf(bytes.view(start=cursor)) is Some(eol) else { return None }
    let line = bytes.view(start=cursor, end=cursor + eol)
    let text = decode_line(line)
    let next = cursor + eol + 2
    if text == "END" {
      return Some((Response::Stats(entries), next))
    }
    guard text.has_prefix("STAT ") else {
      raise Malformed("expected 'STAT' or 'END', found '\{quote(text.view())}'")
    }
    entries.push(parse_stat_line(line))
    cursor = next
  }
  abort("unreachable")
}

///|
/// Decode one complete response from `bytes`.
///
/// Returns the response together with the number of bytes it occupies, or
/// `None` when `bytes` holds only a prefix of a response.
///
/// `limit` is the buffer cap of the decoder that owns `bytes`: a `VALUE` header
/// claiming more than that can never be satisfied, so it is refused here
/// instead of after the buffer was filled.
fn decode_response(
  bytes : BytesView,
  limit : Int,
) -> (Response, Int)? raise ProtocolError {
  guard find_crlf(bytes) is Some(eol) else { return None }
  let line = decode_line(bytes.view(end=eol))
  let offset = eol + 2
  if line.has_prefix("VALUE ") {
    decode_value_blocks(bytes, parse_value_header(line, limit), offset, limit)
  } else if line.has_prefix("STAT ") {
    // Every line of a `stats` reply is a `STAT` line, including this first
    // one, so the section is decoded from the start of the buffer.
    decode_stats(bytes)
  } else if line.has_prefix(VERSION_PREFIX) {
    // The prefix is pure ASCII, so its character length is also its byte
    // length and can be used as a byte offset into the line.
    let payload = decode_line(
      bytes.view(start=VERSION_PREFIX.length(), end=eol),
    )
    Some((Response::Version(payload), offset))
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
///
/// The buffered bytes are capped by `limit`: a stream that never completes a
/// response is a stream that lost its framing, and waiting for more of it only
/// grows the buffer. [`Decoder::next`] reports that as
/// [`ProtocolError::Desynchronised`], and [`Decoder::resync`] clears the buffer.
pub struct Decoder {
  mut buffer : Bytes
  limit : Int
}

///|
/// Buffered bytes a decoder accepts before it declares the stream out of sync.
///
/// memcached caps a single item at 1 MiB by default, and a multi-key retrieval
/// concatenates one `VALUE` block per hit, so the default leaves room for a
/// retrieval of a few full-size items.
const DEFAULT_BUFFER_LIMIT : Int = 8 * 1024 * 1024

///|
/// A decoder that accepts up to `DEFAULT_BUFFER_LIMIT` buffered bytes.
pub fn Decoder::new() -> Decoder {
  { buffer: Bytes::new(0), limit: DEFAULT_BUFFER_LIMIT }
}

///|
/// A decoder that accepts up to `limit` buffered bytes.
pub fn Decoder::with_limit(limit : Int) -> Decoder {
  { buffer: Bytes::new(0), limit }
}

///|
/// Buffer size this decoder accepts, in bytes.
pub fn Decoder::limit(self : Decoder) -> Int {
  self.limit
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
/// Drop every buffered byte.
///
/// Once [`Decoder::next`] reports [`ProtocolError::Desynchronised`] the buffer
/// holds a fragment that will never complete, so the bytes in front of the next
/// response have to be discarded before decoding can resume. Only call this on
/// a stream whose framing is known to have restarted, such as after the
/// connection was re-established.
pub fn Decoder::resync(self : Decoder) -> Unit {
  self.buffer = Bytes::new(0)
}

///|
/// Drop the first line of the buffer, its terminator included.
///
/// An error line is the one response that is both decoded and reported in the
/// same step, so whoever reports it has to take it out of the buffer itself:
/// unlike a decoded response there is no `(response, consumed)` pair to carry
/// the length back, and leaving the bytes in place would make every later decode
/// find the same line again. The line is known to end in CRLF, because that is
/// what let it be read as a line at all.
fn Decoder::drop_line(self : Decoder) -> Unit {
  match find_crlf(self.buffer.view()) {
    Some(eol) => self.buffer = self.buffer.view(start=eol + 2).to_owned()
    // Unreachable in practice, since that very separator is what let the line be
    // read at all. Doing nothing is the safe answer if that ever changes:
    // dropping a prefix of unknown length would lose framing that may still be
    // good.
    None => ()
  }
}

///|
/// Decode the next complete response.
///
/// Returns `None` when the buffered bytes are only a prefix of a response, in
/// which case the caller should `feed` more data. The decoded bytes are
/// consumed from the buffer, so responses can be pulled in a loop.
///
/// A `Remote` failure is a whole response of its own, and it is consumed before
/// it is raised: the reply it reports has been answered, so the buffer moves past
/// it. Were the line left where it was, the same error would be raised for every
/// response asked for afterwards, and a client could never get back to the
/// replies the server did send.
///
/// Raises [`ProtocolError::Desynchronised`] instead of returning `None` when the
/// buffered bytes already exceed the decoder's limit: a response that has not
/// completed by then is not a response, and waiting for the rest of it would
/// only grow the buffer without bound.
///
/// Raises [`ProtocolError::Malformed`] when a `VALUE` header declares a block
/// larger than that same limit, because such a block could never be buffered
/// whole; the header is refused before any of the block is kept, so the buffer
/// does not have to fill up before the stream is called lost. A malformed line
/// is not consumed, unlike a `Remote` one: the bytes could not be read as a
/// response at all, so where the next response starts is exactly what is no
/// longer known - that is what [`Decoder::resync`] is for.
pub fn Decoder::next(self : Decoder) -> Response? raise ProtocolError {
  let decoded = decode_response(self.buffer.view(), self.limit) catch {
    Remote(kind, text) => {
      self.drop_line()
      raise Remote(kind, text)
    }
    err => raise err
  }
  match decoded {
    None => {
      let buffered = self.buffer.length()
      guard buffered <= self.limit else {
        raise Desynchronised(self.limit, buffered)
      }
      None
    }
    Some((response, consumed)) => {
      self.buffer = self.buffer.view(start=consumed).to_owned()
      Some(response)
    }
  }
}
