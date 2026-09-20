// Single-connection memcached client.
//
// The client keeps one [`Connection`] open and moves requests over it one at a
// time: write the encoded request, then pull one complete response off the
// decoder. [`Client::execute`] keeps that request/response pairing obvious for
// a single command, while [`Client::pipeline`] writes a whole batch before it
// reads any of the replies.

///|
/// A client bound to a single connection.
pub struct Client {
  conn : &Connection
  decoder : Decoder
}

///|
/// Wrap an open connection.
pub fn Client::new(conn : &Connection) -> Client {
  { conn, decoder: Decoder::new() }
}

///|
/// Wrap an open connection with a decoder that accepts `limit` buffered bytes
/// before it declares the stream out of sync.
pub fn Client::with_limit(conn : &Connection, limit : Int) -> Client {
  { conn, decoder: Decoder::with_limit(limit) }
}

///|
/// Send `request` and return the response it produces.
///
/// The reply is read whole before it is returned, so a response split across
/// several packets is reassembled transparently.
///
/// `request` has to be one the server answers; a command whose reply is
/// suppressed by `noreply` has nothing to read, and waiting for it would block
/// until the connection died. Those go through [`Client::send`], and a batch of
/// them through [`Client::pipeline`].
pub fn Client::execute(self : Client, request : Request) -> Response raise {
  validate_request(request)
  guard request.expects_reply() else {
    raise ProtocolError::Malformed(
      "this command has no reply to read; use 'send' for it",
    )
  }
  self.conn.write(request.to_bytes().view())
  self.read_response()
}

///|
/// Pull one whole response off the connection, reading until it is complete.
///
/// A read may deliver half a response or several of them, so the decoder is
/// asked first and only fed when it is still waiting for the rest. A read that
/// returns no byte means the peer hung up mid-response: there is nothing left to
/// frame, so the stream is reported as broken rather than as a short reply.
fn Client::read_response(self : Client) -> Response raise {
  while true {
    match self.decoder.next() {
      Some(response) => return response
      None => {
        let chunk = self.conn.read(READ_CHUNK_SIZE)
        if chunk.length() == 0 {
          raise TransportError::Io("server closed the connection mid-response")
        }
        self.decoder.feed(chunk.view())
      }
    }
  }
  abort("unreachable")
}

///|
/// Write `request` without reading an answer back.
///
/// Only accepts the commands that produce no reply: `quit`, and a mutation
/// that carries `noreply`. Anything else has to go through
/// [`Client::execute`], otherwise its reply would stay in the stream and be
/// mistaken for the answer to the next command.
pub fn Client::send(self : Client, request : Request) -> Unit raise {
  validate_request(request)
  guard !request.expects_reply() else {
    raise ProtocolError::Malformed(
      "this command has a reply to read; use 'execute' for it",
    )
  }
  self.conn.write(request.to_bytes().view())
}

///|
/// Run `requests` as one pipeline: write every request, then read one reply back
/// for each request the server answers.
///
/// The result holds one element per request, in the order the requests were
/// given: `Some(response)` for a request that has a reply, and `None` for one
/// whose reply the protocol suppresses, which is a mutation carrying `noreply`.
/// Pairing is therefore the index, and the question it asks is
/// [`Request::expects_reply`], so the caller never counts replies by hand.
///
/// Writing the whole batch before reading any of it is where the round-trip
/// saving comes from: the server works on the requests behind the one whose
/// reply is travelling back. Nothing is validated halfway either - every request
/// is checked before the first byte goes out, so a batch holding a bad request
/// leaves the connection untouched.
///
/// `quit` is refused wherever it appears in a batch. The server stops answering
/// once it reads one, so a request behind it would be dropped with nothing to
/// report the loss, and closing is [`Client::quit`]' job anyway.
///
/// A `Remote` failure is itself a whole response line, so the framing is intact
/// and the server still answers every remaining request; the replies after it
/// are read and dropped before the error is raised, because leaving them in the
/// stream would hand them to the next call as its own answers. Their content is
/// lost along the way, so a batch whose every reply has to be accounted for is
/// better run as one [`Client::execute`] per request.
///
/// A failure part way through the batch leaves the connection spent, and the
/// batch stops there. Either the write itself failed, in which case the requests
/// that did go out are answered by the server regardless, or a reply could not be
/// framed at all, in which case the loop stopped before reading the rest. Both
/// leave replies on the wire that no call here will take back: a later call on
/// the same [`Client`] would read them as its own answers, and
/// [`Client::resync`] only clears the decoder, never the wire. The owner has to
/// drop it and build a new one.
///
/// An empty batch writes nothing, reads nothing and returns nothing: building
/// the list request by request is a normal way to use this, and the empty list
/// has no command to send.
pub fn Client::pipeline(
  self : Client,
  requests : Array[Request],
) -> Array[Response?] raise {
  // The batch is a snapshot, because validation and the writes below have to see
  // the same requests: `Array` is mutable, so a batch edited between the two
  // passes would let a request through unchecked and then put it on the wire.
  let batch = requests.copy()
  validate_pipeline(batch)
  // Whether the server answers a request is decided once, next to the write it
  // belongs to, and that flag list is the only thing read back afterwards. A
  // second pass over the batch would have to reach the same answer again, and
  // nothing here would hold it to that.
  let wanted : Array[Bool] = []
  for request in batch {
    self.conn.write(request.to_bytes().view())
    wanted.push(request.expects_reply())
  }
  self.read_replies(wanted)
}

///|
/// How many replies `wanted` still asks the server for from `from` on.
fn remaining_reply_count(wanted : Array[Bool], from : Int) -> Int {
  let mut count = 0
  let mut index = from
  while index < wanted.length() {
    if wanted[index] {
      count = count + 1
    }
    index = index + 1
  }
  count
}

///|
/// Read one response per `true` in `wanted`, and return a list as long as
/// `wanted`: `Some(response)` where the flag is set, `None` where the server was
/// asked not to answer. Pairing a reply with its request is therefore the index,
/// and a silent request costs no read at all.
///
/// A `Remote` failure is a response of its own: the stream keeps its framing and
/// the server still owes one reply per remaining request, so those replies are
/// read and dropped before the error is raised, which leaves the connection
/// ready for the next call. Any other failure says the bytes cannot be framed at
/// all, so reading on would only pile up whatever follows a stream that is
/// already lost; that error is raised as it came, and the batch ends with replies
/// still unread on the wire, which makes the connection spent - see
/// [`Client::pipeline`] for what the caller has to do about it.
fn Client::read_replies(
  self : Client,
  wanted : Array[Bool],
) -> Array[Response?] raise {
  let responses : Array[Response?] = []
  for _ in wanted {
    responses.push(None)
  }
  let mut slot = 0
  while slot < wanted.length() {
    if wanted[slot] {
      let reply = self.read_response() catch {
        err =>
          match err {
            Remote(_, _) => {
              self.discard_replies(remaining_reply_count(wanted, slot + 1))
              raise err
            }
            _ => raise err
          }
      }
      responses[slot] = Some(reply)
    }
    slot = slot + 1
  }
  responses
}

///|
/// Read and drop `count` responses.
///
/// This is how a pipeline keeps its stream framed once one of its replies had to
/// be reported as a failure: the server still sends one reply per remaining
/// request, and those bytes would otherwise be waiting in the stream to be read
/// as the answers of some later call.
///
/// A failure while dropping is swallowed. The replies are of no use to whoever
/// is about to hear why the pipeline stopped, and that first error is the one
/// that explains the batch - the same reason [`Client::quit`] swallows a failed
/// close. Dropping also stops at that failure, because a stream that just
/// refused to produce a reply has nothing left worth reading.
fn Client::discard_replies(self : Client, count : Int) -> Unit {
  let mut index = 0
  while index < count {
    let _ = self.read_response() catch { _ => return () }
    index = index + 1
  }
}

///|
/// `get` for one or more keys.
pub fn Client::get(
  self : Client,
  keys : Array[String],
) -> Array[RetrievedValue] raise {
  expect_values(self.execute(Request::Get(keys~, with_cas=false)))
}

///|
/// `gets` for one or more keys, including each item's CAS token.
pub fn Client::gets(
  self : Client,
  keys : Array[String],
) -> Array[RetrievedValue] raise {
  expect_values(self.execute(Request::Get(keys~, with_cas=true)))
}

///|
/// `gat`: fetch `keys` and reset the expiry of every hit to `exptime`.
pub fn Client::gat(
  self : Client,
  keys : Array[String],
  exptime : Int,
) -> Array[RetrievedValue] raise {
  expect_values(self.execute(Request::Gat(keys~, exptime~, with_cas=false)))
}

///|
/// `gats`: like [`Client::gat`], but each block carries its CAS token.
pub fn Client::gats(
  self : Client,
  keys : Array[String],
  exptime : Int,
) -> Array[RetrievedValue] raise {
  expect_values(self.execute(Request::Gat(keys~, exptime~, with_cas=true)))
}

///|
/// Run a storage command with explicit flags, expiry and CAS token.
pub fn Client::store(
  self : Client,
  op : StorageOp,
  key : String,
  value : Bytes,
  flags : Int,
  exptime : Int,
  cas : UInt64?,
) -> Status raise {
  expect_status(
    self.execute(
      Request::Storage(op~, key~, flags~, exptime~, value~, cas~, noreply=false),
    ),
  )
}

///|
/// `set`: store `value` under `key`, ignoring any existing value.
///
/// `flags` and `exptime` default to `0`; pass either to override.
pub fn Client::set(
  self : Client,
  key : String,
  value : Bytes,
  flags? : Int = 0,
  exptime? : Int = 0,
) -> Status raise {
  self.store(StorageOp::Set, key, value, flags, exptime, None)
}

///|
/// `add`: store `value` under `key` only if the key does not exist yet.
///
/// `flags` and `exptime` default to `0`; pass either to override.
pub fn Client::add(
  self : Client,
  key : String,
  value : Bytes,
  flags? : Int = 0,
  exptime? : Int = 0,
) -> Status raise {
  self.store(StorageOp::Add, key, value, flags, exptime, None)
}

///|
/// `replace`: store `value` under `key` only if the key already exists.
///
/// `flags` and `exptime` default to `0`; pass either to override.
pub fn Client::replace(
  self : Client,
  key : String,
  value : Bytes,
  flags? : Int = 0,
  exptime? : Int = 0,
) -> Status raise {
  self.store(StorageOp::Replace, key, value, flags, exptime, None)
}

///|
/// `append`: append `value` to the item stored under `key`.
///
/// `flags` and `exptime` default to `0`; pass either to override.
pub fn Client::append(
  self : Client,
  key : String,
  value : Bytes,
  flags? : Int = 0,
  exptime? : Int = 0,
) -> Status raise {
  self.store(StorageOp::Append, key, value, flags, exptime, None)
}

///|
/// `prepend`: prepend `value` to the item stored under `key`.
///
/// `flags` and `exptime` default to `0`; pass either to override.
pub fn Client::prepend(
  self : Client,
  key : String,
  value : Bytes,
  flags? : Int = 0,
  exptime? : Int = 0,
) -> Status raise {
  self.store(StorageOp::Prepend, key, value, flags, exptime, None)
}

///|
/// `cas`: store `value` under `key` only if its CAS token is still `cas`.
///
/// `flags` and `exptime` default to `0`; pass either to override.
pub fn Client::cas(
  self : Client,
  key : String,
  value : Bytes,
  cas : UInt64,
  flags? : Int = 0,
  exptime? : Int = 0,
) -> Status raise {
  self.store(StorageOp::Cas, key, value, flags, exptime, Some(cas))
}

///|
/// `delete`: remove `key`.
pub fn Client::delete(self : Client, key : String) -> Status raise {
  expect_status(self.execute(Request::Delete(key~, noreply=false)))
}

///|
/// `incr`: add `delta` to the counter stored under `key`.
pub fn Client::incr(
  self : Client,
  key : String,
  delta : UInt64,
) -> UInt64 raise {
  expect_counter(self.execute(Request::Incr(key~, delta~, noreply=false)))
}

///|
/// `decr`: subtract `delta` from the counter stored under `key`.
pub fn Client::decr(
  self : Client,
  key : String,
  delta : UInt64,
) -> UInt64 raise {
  expect_counter(self.execute(Request::Decr(key~, delta~, noreply=false)))
}

///|
/// `touch`: reset the expiry of `key` to `exptime` without fetching it.
pub fn Client::touch(
  self : Client,
  key : String,
  exptime : Int,
) -> Status raise {
  expect_status(self.execute(Request::Touch(key~, exptime~, noreply=false)))
}

///|
/// `version`: the version string the server reports.
pub fn Client::version(self : Client) -> String raise {
  expect_version(self.execute(Request::Version))
}

///|
/// `stats`: the general statistics of the server, one entry per `STAT` line.
pub fn Client::stats(self : Client) -> Array[StatEntry] raise {
  expect_stats(self.execute(Request::Stats(sub=None)))
}

///|
/// `stats <section>`: one section of the server statistics, such as `items`,
/// `slabs` or `settings`.
///
/// A section nests its dimension into the entry name, so `stats items` yields
/// entries named `items:1:number` and friends.
///
/// `section` may be several words separated by single spaces, which is how the
/// server spells the sections that take an argument: `stats detail on`,
/// `stats cachedump <slab> <limit>`.
pub fn Client::stats_of(
  self : Client,
  section : String,
) -> Array[StatEntry] raise {
  expect_stats(self.execute(Request::Stats(sub=Some(section))))
}

///|
/// `flush_all`: invalidate every item after `delay` seconds.
///
/// `None` flushes immediately.
pub fn Client::flush_all(self : Client, delay : Int?) -> Status raise {
  expect_status(self.execute(Request::FlushAll(delay~, noreply=false)))
}

///|
/// `verbosity <level>`: change how much the server logs.
pub fn Client::verbosity(self : Client, level : Int) -> Status raise {
  expect_status(self.execute(Request::Verbosity(level~, noreply=false)))
}

///|
/// `cache_memlimit <megabytes>`: cap the memory the server uses for items.
pub fn Client::cache_memlimit(self : Client, megabytes : Int) -> Status raise {
  expect_status(self.execute(Request::CacheMemlimit(megabytes~, noreply=false)))
}

///|
/// `slabs reassign <src> <dst>`: move a slab page from class `src` to class
/// `dst`. A `src` of `-1` lets the server pick the source slab itself.
pub fn Client::slabs_reassign(
  self : Client,
  src : Int,
  dst : Int,
) -> Status raise {
  expect_status(self.execute(Request::SlabsReassign(src~, dst~, noreply=false)))
}

///|
/// `slabs automove <mode>`: set the slab automover - `0` off, `1` on,
/// `2` aggressive.
pub fn Client::slabs_automove(self : Client, mode : Int) -> Status raise {
  expect_status(self.execute(Request::SlabsAutomove(mode~, noreply=false)))
}

///|
/// `quit`: ask the server to hang up, then release the local channel.
///
/// The server sends no reply to `quit`, so nothing is read back. The channel is
/// closed even when the command cannot be written, so a failed send does not
/// leak it; the send error is re-raised afterwards. A failure of that closing
/// is swallowed, because the send error is the one that explains why the
/// connection is being given up in the first place.
pub fn Client::quit(self : Client) -> Unit raise {
  self.send(Request::Quit) catch {
    err => {
      self.conn.close() catch {
        _ => ()
      }
      raise err
    }
  }
  self.conn.close()
}

///|
/// Drop every byte the decoder still holds.
///
/// This is the client's handle on [`Decoder::resync`]: once a stream has lost
/// its framing ([`ProtocolError::Desynchronised`]) and is known to have
/// restarted - typically after a reconnect - the buffered fragment has to go
/// before the next [`Client::execute`]. Calling it on a healthy stream
/// discards bytes that were never consumed.
pub fn Client::resync(self : Client) -> Unit {
  self.decoder.resync()
}

///|
fn expect_values(response : Response) -> Array[RetrievedValue] raise {
  match response {
    Values(values) => values
    _ => raise ProtocolError::Malformed("expected a retrieval response")
  }
}

///|
fn expect_status(response : Response) -> Status raise {
  match response {
    Status(status) => status
    _ => raise ProtocolError::Malformed("expected a status line")
  }
}

///|
fn expect_counter(response : Response) -> UInt64 raise {
  match response {
    Counter(value) => value
    _ => raise ProtocolError::Malformed("expected a counter value")
  }
}

///|
fn expect_version(response : Response) -> String raise {
  match response {
    Version(text) => text
    _ => raise ProtocolError::Malformed("expected a version response")
  }
}

///|
fn expect_stats(response : Response) -> Array[StatEntry] raise {
  match response {
    Stats(entries) => entries
    _ => raise ProtocolError::Malformed("expected a stats response")
  }
}

///|
/// How many bytes one read is asked for while a response is being assembled.
///
/// This is a fetch size, not a cap: [`Decoder`] holds the bytes until a whole
/// response is framed, so what may accumulate is bounded by the decoder's own
/// limit (`DEFAULT_BUFFER_LIMIT` by default), never by this number.
const READ_CHUNK_SIZE : Int = 4096

///|
/// Longest key memcached accepts, in bytes.
const MAX_KEY_LENGTH : Int = 250

///|
/// Whether `code` may stand inside a word of a command line.
///
/// The server splits the command line on spaces, so a word may hold anything
/// that is neither a space nor a control character. A key is one such word, and
/// so is every word of a `stats` section.
fn is_word_byte(code : Int) -> Bool {
  code > 0x20 && code != 0x7F
}

///|
/// Reject a key that cannot be carried in a command line.
///
/// A key is one word of the command line, so it must be non-empty, no longer
/// than the bytes the server accepts for a key, and free of the bytes that
/// would end the word early. The length is measured in UTF-8 bytes, which is
/// the unit the server counts.
///
/// Every rejection names the key and, where there is a number to give, its
/// byte count: the key comes from application data, so the caller has to be
/// able to find it there. A byte the command line cannot carry is rendered the
/// same way `quote` renders peer data, so a tab or a delete stays visible
/// instead of reaching the message as itself.
fn validate_key(key : String) -> Unit raise ProtocolError {
  let bytes = @utf8.encode(key.view())
  let shown = quote(key.view())
  guard bytes.length() > 0 else { raise Malformed("a key cannot be empty") }
  guard bytes.length() <= MAX_KEY_LENGTH else {
    raise Malformed(
      "key '\{shown}' is \{bytes.length()} bytes, more than the \{MAX_KEY_LENGTH} bytes a key may hold",
    )
  }
  for byte in bytes {
    guard is_word_byte(byte.to_int()) else {
      raise Malformed(
        "key '\{shown}' holds a blank or control byte a command line cannot carry: '\{byte.to_char().escape(quote=false)}'",
      )
    }
  }
}

///|
/// Reject a `stats` section that cannot be written into a command line.
///
/// A section is one or more words separated by single spaces, and the words
/// are what the server reads, so a space may only appear between two of them:
/// an empty word (leading, trailing or doubled space, or no section at all)
/// would leave the command line with a hole in it. Every other word byte is
/// the same one a key may hold, and every rejection quotes the section so that
/// the offending byte can be found in the message.
///
/// The length cap is borrowed from keys: memcached sets no separate limit on a
/// section, but the command line is read as one run of words, so a section no
/// longer than a key is certainly accepted and a longer one is refused as a
/// conservative guard against a runaway section.
fn validate_subcommand(section : String) -> Unit raise ProtocolError {
  let bytes = @utf8.encode(section.view())
  let shown = quote(section.view())
  guard bytes.length() > 0 && bytes.length() <= MAX_KEY_LENGTH else {
    raise Malformed(
      "stats section is \{bytes.length()} bytes, outside the 1..\{MAX_KEY_LENGTH} bytes this client allows: '\{shown}'",
    )
  }
  // A word holds at least one byte, so every space must have a word byte on
  // both sides of it; a space that does not leaves an empty word behind. The
  // same scan records that and rejects the bytes a command line cannot carry.
  let mut after_space = true
  let mut empty_word = false
  for byte in bytes {
    let is_space = byte.to_int() == 0x20
    guard is_space || is_word_byte(byte.to_int()) else {
      raise Malformed(
        "stats section has a byte a command line cannot carry: '\{shown}'",
      )
    }
    empty_word = empty_word || (is_space && after_space)
    after_space = is_space
  }
  guard !(empty_word || after_space) else {
    raise Malformed("stats section has an empty word: '\{shown}'")
  }
}

///|
/// Reject a retrieval whose key list cannot be written out.
///
/// The command line carries the keys one after another, so an empty list would
/// encode a bare `get` with no key at all.
fn validate_keys(keys : Array[String]) -> Unit raise ProtocolError {
  guard keys.length() > 0 else {
    raise Malformed("a retrieval needs at least one key")
  }
  for key in keys {
    validate_key(key)
  }
}

///|
/// Reject a batch a pipeline cannot run.
///
/// Every request is held to the same rule as a single one, for the same reason
/// [`Client::execute`] checks first: encoding only says what a request looks
/// like on the wire, so a request that could not be expressed as a command line
/// has to be refused before the batch starts, not after part of it went out.
///
/// `quit` is refused wherever it sits in the batch. The server stops answering
/// once it reads one, so every request behind it would be dropped without the
/// reply that would have reported it, and a `quit` at the very end would close
/// the connection behind [`Client`]' back. [`Client::quit`] owns that job.
fn validate_pipeline(requests : Array[Request]) -> Unit raise ProtocolError {
  for request in requests {
    guard !(request is Quit) else {
      raise Malformed(
        "a pipeline cannot hold 'quit': the server stops answering behind it, so a request after it would be dropped with no reply to report it; use 'Client::quit' to close",
      )
    }
    validate_request(request)
  }
}

///|
/// Reject a request that the text protocol cannot express.
///
/// Encoding only reports what a request looks like on the wire, so the client
/// checks the invariants that the command line relies on before writing.
fn validate_request(request : Request) -> Unit raise ProtocolError {
  match request {
    Storage(key~, ..) => validate_key(key)
    Get(keys~, ..) => validate_keys(keys)
    Gat(keys~, ..) => validate_keys(keys)
    Delete(key~, ..) => validate_key(key)
    Incr(key~, ..) => validate_key(key)
    Decr(key~, ..) => validate_key(key)
    Touch(key~, ..) => validate_key(key)
    Stats(sub~) =>
      // The section is a run of words of the command line, so each word obeys
      // the same rules as a key; an empty word would leave a hole behind.
      if sub is Some(section) {
        validate_subcommand(section)
      }
    FlushAll(delay~, ..) =>
      if delay is Some(seconds) {
        guard seconds >= 0 else {
          raise Malformed("flush_all delay cannot be negative: \{seconds}")
        }
      }
    Verbosity(level~, ..) =>
      if level < 0 {
        raise Malformed("verbosity level cannot be negative: \{level}")
      }
    CacheMemlimit(megabytes~, ..) =>
      if megabytes < 0 {
        raise Malformed(
          "cache_memlimit megabytes cannot be negative: \{megabytes}",
        )
      }
    SlabsReassign(src~, dst~, ..) => {
      // `-1` asks the server to pick the source slab itself; anything below
      // is not a slab class at all.
      guard src >= -1 else {
        raise Malformed("slab class cannot be below -1: \{src}")
      }
      guard dst >= -1 else {
        raise Malformed("slab class cannot be below -1: \{dst}")
      }
    }
    SlabsAutomove(mode~, ..) => {
      guard 0 <= mode && mode <= 2 else {
        raise Malformed("slabs automove mode must be 0, 1 or 2: \{mode}")
      }
    }
    Version => ()
    Quit => ()
  }
}
