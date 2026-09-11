// Single-connection memcached client.
//
// The client keeps one [`Connection`] open and serialises requests over it:
// write the encoded request, then pull one complete response off the decoder.
// Requests are not pipelined yet, which keeps the request/response pairing
// obvious; the decoder already supports it.

///|
/// A client bound to a single connection.
pub struct Client {
  conn : &Connection
  decoder : Decoder
}

///|
/// Wrap an open connection.
pub fn Client::new(conn : &Connection) -> Client {
  { conn, decoder: Decoder::new(), }
}

///|
/// Send `request` and return the response it produces.
///
/// Reads are retried until a whole response is buffered, so a response split
/// across several packets is reassembled transparently.
pub fn Client::execute(self : Client, request : Request) -> Response raise {
  validate_request(request)
  self.conn.write(request.to_bytes().view())
  while true {
    match self.decoder.next() {
      Some(response) => return response
      None => {
        let chunk = self.conn.read(4096)
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
    self.execute(Request::Storage(op~, key~, flags~, exptime~, value~, cas~)),
  )
}

///|
/// `set`: store `value` under `key`, ignoring any existing value.
pub fn Client::set(self : Client, key : String, value : Bytes) -> Status raise {
  self.store(StorageOp::Set, key, value, 0, 0, None)
}

///|
/// `add`: store `value` under `key` only if the key does not exist yet.
pub fn Client::add(self : Client, key : String, value : Bytes) -> Status raise {
  self.store(StorageOp::Add, key, value, 0, 0, None)
}

///|
/// `replace`: store `value` under `key` only if the key already exists.
pub fn Client::replace(
  self : Client,
  key : String,
  value : Bytes,
) -> Status raise {
  self.store(StorageOp::Replace, key, value, 0, 0, None)
}

///|
/// `append`: append `value` to the item stored under `key`.
pub fn Client::append(
  self : Client,
  key : String,
  value : Bytes,
) -> Status raise {
  self.store(StorageOp::Append, key, value, 0, 0, None)
}

///|
/// `prepend`: prepend `value` to the item stored under `key`.
pub fn Client::prepend(
  self : Client,
  key : String,
  value : Bytes,
) -> Status raise {
  self.store(StorageOp::Prepend, key, value, 0, 0, None)
}

///|
/// `cas`: store `value` under `key` only if its CAS token is still `cas`.
pub fn Client::cas(
  self : Client,
  key : String,
  value : Bytes,
  cas : UInt64,
) -> Status raise {
  self.store(StorageOp::Cas, key, value, 0, 0, Some(cas))
}

///|
/// `delete`: remove `key`.
pub fn Client::delete(self : Client, key : String) -> Status raise {
  expect_status(self.execute(Request::Delete(key~)))
}

///|
/// `incr`: add `delta` to the counter stored under `key`.
pub fn Client::incr(
  self : Client,
  key : String,
  delta : UInt64,
) -> UInt64 raise {
  expect_counter(self.execute(Request::Incr(key~, delta~)))
}

///|
/// `decr`: subtract `delta` from the counter stored under `key`.
pub fn Client::decr(
  self : Client,
  key : String,
  delta : UInt64,
) -> UInt64 raise {
  expect_counter(self.execute(Request::Decr(key~, delta~)))
}

///|
/// `quit`: ask the server to hang up, then release the local channel.
///
/// The server sends no reply to `quit`, so nothing is read back. The channel is
/// closed even when the command cannot be written, so a failed send does not
/// leak it; the send error is re-raised afterwards.
pub fn Client::quit(self : Client) -> Unit raise {
  errdefer self.conn.close()
  self.conn.write(Request::Quit.to_bytes().view())
  self.conn.close()
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
/// Longest key memcached accepts, in bytes.
const MAX_KEY_LENGTH : Int = 250

///|
/// Whether `key` can be carried in a command line.
///
/// Keys must be non-empty, at most 250 bytes long, and free of whitespace and
/// control characters, because the server splits the command line on spaces.
/// The length is measured in UTF-8 bytes, which is the unit the server counts.
fn is_valid_key(key : String) -> Bool {
  let bytes = @utf8.encode(key.view())
  if bytes.length() == 0 || bytes.length() > MAX_KEY_LENGTH {
    return false
  }
  for byte in bytes {
    let code = byte.to_int()
    if code <= 0x20 || code == 0x7F {
      return false
    }
  }
  true
}

///|
fn validate_key(key : String) -> Unit raise ProtocolError {
  guard is_valid_key(key) else {
    raise Malformed("key cannot be sent in a command line")
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
    Get(keys~, ..) => {
      guard keys.length() > 0 else {
        raise Malformed("a retrieval needs at least one key")
      }
      for key in keys {
        validate_key(key)
      }
    }
    Delete(key~) => validate_key(key)
    Incr(key~, ..) => validate_key(key)
    Decr(key~, ..) => validate_key(key)
    Quit => ()
  }
}
