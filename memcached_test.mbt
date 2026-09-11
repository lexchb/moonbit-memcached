// Blackbox tests for the memcached text protocol module.
//
// Requests are checked byte by byte, and the decoder and the single-connection
// client are driven against in-memory transcripts, so the whole suite runs
// without a memcached server.

///|
/// Decode a single response out of `input`.
fn decode(input : Bytes) -> @memcached.Response raise {
  let decoder = @memcached.Decoder::new()
  decoder.feed(input.view())
  decoder.next().unwrap()
}

///|
/// Decode a single response line into a terminal status.
fn decode_status(input : Bytes) -> @memcached.Status raise {
  match decode(input) {
    @memcached.Response::Status(status) => status
    _ => abort("expected a status response")
  }
}

///|
/// Decode a retrieval response into its `VALUE` blocks.
fn decode_values(input : Bytes) -> Array[@memcached.RetrievedValue] raise {
  match decode(input) {
    @memcached.Response::Values(values) => values
    _ => abort("expected a retrieval response")
  }
}

///|
/// Describe how the decoder reacts to `input`: `"accepted"`, `"malformed"`, or
/// the kind of server-side error it raised.
fn reaction(input : Bytes) -> String {
  let decoder = @memcached.Decoder::new()
  decoder.feed(input.view())
  try {
    let _ = decoder.next()
    "accepted"
  } catch {
    err =>
      match err {
        @memcached.ProtocolError::Remote(kind, _) =>
          match kind {
            @memcached.RemoteErrorKind::Generic => "generic"
            @memcached.RemoteErrorKind::Client => "client"
            @memcached.RemoteErrorKind::Server => "server"
          }
        @memcached.ProtocolError::Malformed(_) => "malformed"
      }
  }
}

///|
/// A string of `n` `k` characters, used to probe the key length limit.
fn key_of_length(n : Int) -> String {
  let builder = StringBuilder()
  for _ in 0..<n {
    builder.write_char('k')
  }
  builder.to_string()
}

///|
/// Describe how the client reacts to `key` used as a storage key.
///
/// A fresh connection answers `STORED`, so a key the client accepts is reported
/// as "accepted" and one it refuses as "malformed".
fn store_reaction(key : String) -> String {
  let connection : @memcached.ScriptedConnection = @memcached.ScriptedConnection::new([
      b"STORED\r\n",
    ],
  )
  let client = @memcached.Client::new(connection)
  try {
    let _ = client.set(key, b"x")
    "accepted"
  } catch {
    err =>
      match err {
        @memcached.ProtocolError::Malformed(_) => "malformed"
        _ => "other"
      }
  }
}

///|
test "storage request encodes the command line and the data block" {
  let request : @memcached.Request = @memcached.Request::Storage(
    op=@memcached.StorageOp::Set,
    key="foo",
    flags=7,
    exptime=60,
    value=b"bar",
    cas=None,
  )
  assert_true(request.to_bytes() == b"set foo 7 60 3\r\nbar\r\n")
}

///|
test "cas request appends the compare-and-swap token" {
  let request : @memcached.Request = @memcached.Request::Storage(
    op=@memcached.StorageOp::Cas,
    key="foo",
    flags=0,
    exptime=0,
    value=b"bar",
    cas=Some(42UL),
  )
  assert_true(request.to_bytes() == b"cas foo 0 0 3 42\r\nbar\r\n")
}

///|
test "an empty value still encodes a zero-length data block" {
  let request : @memcached.Request = @memcached.Request::Storage(
    op=@memcached.StorageOp::Set,
    key="empty",
    flags=0,
    exptime=0,
    value=b"",
    cas=None,
  )
  assert_true(request.to_bytes() == b"set empty 0 0 0\r\n\r\n")
}

///|
test "get and gets encode the key list" {
  let get : @memcached.Request = @memcached.Request::Get(
    keys=["foo", "bar"],
    with_cas=false,
  )
  let gets : @memcached.Request = @memcached.Request::Get(
    keys=["foo", "bar"],
    with_cas=true,
  )
  assert_true(get.to_bytes() == b"get foo bar\r\n")
  assert_true(gets.to_bytes() == b"gets foo bar\r\n")
}

///|
test "delete, incr, decr and quit encode their arguments" {
  let delete : @memcached.Request = @memcached.Request::Delete(key="foo")
  let incr : @memcached.Request = @memcached.Request::Incr(
    key="counter",
    delta=3UL,
  )
  let decr : @memcached.Request = @memcached.Request::Decr(
    key="counter",
    delta=3UL,
  )
  let quit : @memcached.Request = @memcached.Request::Quit
  assert_true(delete.to_bytes() == b"delete foo\r\n")
  assert_true(incr.to_bytes() == b"incr counter 3\r\n")
  assert_true(decr.to_bytes() == b"decr counter 3\r\n")
  assert_true(quit.to_bytes() == b"quit\r\n")
}

///|
test "terminal status lines decode to their status" {
  assert_true(decode_status(b"STORED\r\n") == @memcached.Status::Stored)
  assert_true(decode_status(b"NOT_STORED\r\n") == @memcached.Status::NotStored)
  assert_true(decode_status(b"EXISTS\r\n") == @memcached.Status::Exists)
  assert_true(decode_status(b"NOT_FOUND\r\n") == @memcached.Status::NotFound)
  assert_true(decode_status(b"DELETED\r\n") == @memcached.Status::Deleted)
  assert_true(decode_status(b"TOUCHED\r\n") == @memcached.Status::Touched)
}

///|
test "counter replies decode to their number" {
  match decode(b"42\r\n") {
    @memcached.Response::Counter(value) => assert_true(value == 42UL)
    _ => abort("expected a counter response")
  }
}

///|
test "get decodes a single VALUE block" {
  let values = decode_values(b"VALUE foo 7 3\r\nbar\r\nEND\r\n")
  assert_true(values.length() == 1)
  assert_true(values[0].key == "foo")
  assert_true(values[0].flags == 7)
  assert_true(values[0].data == b"bar")
  assert_true(values[0].cas is None)
}

///|
test "gets decodes the CAS token of every block" {
  let values = decode_values(
    b"VALUE foo 0 3 9\r\nbar\r\nVALUE baz 0 3 10\r\nqux\r\nEND\r\n",
  )
  assert_true(values.length() == 2)
  assert_true(values[0].cas == Some(9UL))
  assert_true(values[1].key == "baz")
  assert_true(values[1].data == b"qux")
  assert_true(values[1].cas == Some(10UL))
}

///|
test "a miss decodes to an empty block list" {
  assert_true(decode_values(b"END\r\n").length() == 0)
}

///|
test "data blocks are framed by the byte count, not by CRLF" {
  let values = decode_values(b"VALUE bin 0 4\r\na\r\nb\r\nEND\r\n")
  assert_true(values.length() == 1)
  assert_true(values[0].data == b"a\r\nb")
}

///|
test "a response split across two feeds is reassembled" {
  let decoder = @memcached.Decoder::new()
  decoder.feed(b"VALUE k 0 5\r\nhel")
  assert_true(decoder.next() is None)
  assert_true(decoder.buffered() == 16)
  decoder.feed(b"lo\r\nEND\r\n")
  match decoder.next() {
    Some(@memcached.Response::Values(values)) =>
      assert_true(values[0].data == b"hello")
    _ => abort("expected a retrieval response")
  }
  assert_true(decoder.buffered() == 0)
}

///|
test "several responses can be pulled from a single feed" {
  let decoder = @memcached.Decoder::new()
  decoder.feed(b"STORED\r\nDELETED\r\n")
  match decoder.next() {
    Some(@memcached.Response::Status(status)) =>
      assert_true(status == @memcached.Status::Stored)
    _ => abort("expected a status response")
  }
  match decoder.next() {
    Some(@memcached.Response::Status(status)) =>
      assert_true(status == @memcached.Status::Deleted)
    _ => abort("expected a status response")
  }
  assert_true(decoder.next() is None)
}

///|
test "server side errors are surfaced with their kind" {
  assert_true(reaction(b"ERROR\r\n") == "generic")
  assert_true(reaction(b"CLIENT_ERROR bad command line\r\n") == "client")
  assert_true(reaction(b"SERVER_ERROR out of memory\r\n") == "server")
}

///|
test "frames that break the text protocol are rejected" {
  assert_true(reaction(b"WHAT\r\n") == "malformed")
  assert_true(reaction(b"VALUE onlyonefield\r\n") == "malformed")
  assert_true(reaction(b"VALUE k 0 3\r\nbarX\r\n") == "malformed")
  assert_true(reaction(b"VALUE k 0 3\r\nbar\r\nWHAT\r\n") == "malformed")
}

///|
test "client stores and retrieves over a single connection" {
  let connection : @memcached.ScriptedConnection = @memcached.ScriptedConnection::new([
      b"STORED\r\n", b"VALUE foo 0 3\r\nbar\r\nEND\r\n",
    ],
  )
  let client = @memcached.Client::new(connection)
  assert_true(client.set("foo", b"bar") == @memcached.Status::Stored)
  let values = client.get(["foo"])
  assert_true(values.length() == 1)
  assert_true(values[0].data == b"bar")
  assert_true(connection.written() == b"set foo 0 0 3\r\nbar\r\nget foo\r\n")
}

///|
test "client cas forwards the expected token" {
  let connection : @memcached.ScriptedConnection = @memcached.ScriptedConnection::new([
      b"EXISTS\r\n",
    ],
  )
  let client = @memcached.Client::new(connection)
  assert_true(client.cas("foo", b"bar", 42UL) == @memcached.Status::Exists)
  assert_true(connection.written() == b"cas foo 0 0 3 42\r\nbar\r\n")
}

///|
test "client counter commands return the new value" {
  let connection : @memcached.ScriptedConnection = @memcached.ScriptedConnection::new([
      b"11\r\n",
    ],
  )
  let client = @memcached.Client::new(connection)
  assert_true(client.incr("counter", 1UL) == 11UL)
  assert_true(connection.written() == b"incr counter 1\r\n")
}

///|
test "client quit writes the quit command" {
  let connection : @memcached.ScriptedConnection = @memcached.ScriptedConnection::new([],
  )
  let client = @memcached.Client::new(connection)
  client.quit()
  assert_true(connection.written() == b"quit\r\n")
}

///|
test "a connection closed mid-response is reported as a transport error" {
  let connection : @memcached.ScriptedConnection = @memcached.ScriptedConnection::new([
      b"VALUE foo 0 3\r\nba",
    ],
  )
  let client = @memcached.Client::new(connection)
  let outcome = try {
    let _ = client.get(["foo"])
    "accepted"
  } catch {
    err =>
      match err {
        @memcached.TransportError::Io(_) => "io"
        _ => "other"
      }
  }
  assert_true(outcome == "io")
}

///|
test "an unrecognised response line is reported as malformed" {
  let connection : @memcached.ScriptedConnection = @memcached.ScriptedConnection::new([
      b"BOGUS\r\n",
    ],
  )
  let client = @memcached.Client::new(connection)
  let outcome = try {
    let _ = client.set("foo", b"bar")
    "accepted"
  } catch {
    err =>
      match err {
        @memcached.ProtocolError::Malformed(_) => "malformed"
        _ => "other"
      }
  }
  assert_true(outcome == "malformed")
}

///|
test "a key that fits the command line is accepted" {
  assert_true(store_reaction("foo") == "accepted")
  assert_true(store_reaction(key_of_length(250)) == "accepted")
}

///|
test "keys that cannot travel in a command line are rejected" {
  assert_true(store_reaction("") == "malformed")
  assert_true(store_reaction("has space") == "malformed")
  assert_true(store_reaction("has\ttab") == "malformed")
  assert_true(store_reaction("has\nnewline") == "malformed")
  assert_true(store_reaction(key_of_length(251)) == "malformed")
}

///|
test "a retrieval without keys is rejected before anything is written" {
  let connection : @memcached.ScriptedConnection = @memcached.ScriptedConnection::new([
      b"END\r\n",
    ],
  )
  let client = @memcached.Client::new(connection)
  let outcome = try {
    let _ = client.get([])
    "accepted"
  } catch {
    err =>
      match err {
        @memcached.ProtocolError::Malformed(_) => "malformed"
        _ => "other"
      }
  }
  assert_true(outcome == "malformed")
  assert_true(connection.written() == b"")
}

///|
test "an oversized byte count waits for more data instead of misframing" {
  let decoder = @memcached.Decoder::new()
  decoder.feed(b"VALUE k 0 1000000\r\nbar\r\nEND\r\n")
  assert_true(decoder.next() is None)
  assert_true(decoder.buffered() == 29)
}
