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
        @memcached.ProtocolError::Desynchronised(_, _) => "desynchronised"
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
    noreply=false,
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
    noreply=false,
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
    noreply=false,
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
  let delete : @memcached.Request = @memcached.Request::Delete(
    key="foo",
    noreply=false,
  )
  let incr : @memcached.Request = @memcached.Request::Incr(
    key="counter",
    delta=3UL,
    noreply=false,
  )
  let decr : @memcached.Request = @memcached.Request::Decr(
    key="counter",
    delta=3UL,
    noreply=false,
  )
  let quit : @memcached.Request = @memcached.Request::Quit
  assert_true(delete.to_bytes() == b"delete foo\r\n")
  assert_true(incr.to_bytes() == b"incr counter 3\r\n")
  assert_true(decr.to_bytes() == b"decr counter 3\r\n")
  assert_true(quit.to_bytes() == b"quit\r\n")
}

///|
test "touch, gat and gats encode their exptime ahead of the keys" {
  let touch : @memcached.Request = @memcached.Request::Touch(
    key="foo",
    exptime=30,
    noreply=false,
  )
  let gat : @memcached.Request = @memcached.Request::Gat(
    keys=["foo", "bar"],
    exptime=30,
    with_cas=false,
  )
  let gats : @memcached.Request = @memcached.Request::Gat(
    keys=["foo"],
    exptime=0,
    with_cas=true,
  )
  assert_true(touch.to_bytes() == b"touch foo 30\r\n")
  assert_true(gat.to_bytes() == b"gat 30 foo bar\r\n")
  assert_true(gats.to_bytes() == b"gats 0 foo\r\n")
}

///|
test "the administrative commands encode their optional arguments" {
  let version : @memcached.Request = @memcached.Request::Version
  let stats : @memcached.Request = @memcached.Request::Stats(sub=None)
  let stats_items : @memcached.Request = @memcached.Request::Stats(
    sub=Some("items"),
  )
  let flush_now : @memcached.Request = @memcached.Request::FlushAll(
    delay=None,
    noreply=false,
  )
  let flush_later : @memcached.Request = @memcached.Request::FlushAll(
    delay=Some(10),
    noreply=false,
  )
  let verbosity : @memcached.Request = @memcached.Request::Verbosity(
    level=2,
    noreply=false,
  )
  assert_true(version.to_bytes() == b"version\r\n")
  assert_true(stats.to_bytes() == b"stats\r\n")
  assert_true(stats_items.to_bytes() == b"stats items\r\n")
  assert_true(flush_now.to_bytes() == b"flush_all\r\n")
  assert_true(flush_later.to_bytes() == b"flush_all 10\r\n")
  assert_true(verbosity.to_bytes() == b"verbosity 2\r\n")
}

///|
test "noreply is appended last and suppresses the expected reply" {
  let storage : @memcached.Request = @memcached.Request::Storage(
    op=@memcached.StorageOp::Set,
    key="foo",
    flags=0,
    exptime=0,
    value=b"bar",
    cas=None,
    noreply=true,
  )
  let delete : @memcached.Request = @memcached.Request::Delete(
    key="foo",
    noreply=true,
  )
  let flush : @memcached.Request = @memcached.Request::FlushAll(
    delay=Some(5),
    noreply=true,
  )
  assert_true(storage.to_bytes() == b"set foo 0 0 3 noreply\r\nbar\r\n")
  assert_true(delete.to_bytes() == b"delete foo noreply\r\n")
  assert_true(flush.to_bytes() == b"flush_all 5 noreply\r\n")
  assert_true(!storage.expects_reply())
  assert_true(!delete.expects_reply())
  assert_true(!flush.expects_reply())
}

///|
test "terminal status lines decode to their status" {
  assert_true(decode_status(b"STORED\r\n") == @memcached.Status::Stored)
  assert_true(decode_status(b"NOT_STORED\r\n") == @memcached.Status::NotStored)
  assert_true(decode_status(b"EXISTS\r\n") == @memcached.Status::Exists)
  assert_true(decode_status(b"NOT_FOUND\r\n") == @memcached.Status::NotFound)
  assert_true(decode_status(b"DELETED\r\n") == @memcached.Status::Deleted)
  assert_true(decode_status(b"TOUCHED\r\n") == @memcached.Status::Touched)
  assert_true(decode_status(b"OK\r\n") == @memcached.Status::Ok)
}

///|
test "a version reply decodes to its version string" {
  match decode(b"VERSION 1.6.21\r\n") {
    @memcached.Response::Version(version) => assert_true(version == "1.6.21")
    _ => abort("expected a version response")
  }
}

///|
test "a stats reply decodes every STAT line up to END" {
  match
    decode(
      b"STAT pid 1234\r\nSTAT libevent 2.1.12-stable\r\nSTAT items:1:number 2\r\nEND\r\n",
    ) {
    @memcached.Response::Stats(entries) => {
      assert_true(entries.length() == 3)
      assert_true(entries[0].name == "pid")
      assert_true(entries[0].value == "1234")
      assert_true(entries[1].name == "libevent")
      assert_true(entries[1].value == "2.1.12-stable")
      assert_true(entries[2].name == "items:1:number")
      assert_true(entries[2].value == "2")
    }
    _ => abort("expected a stats response")
  }
}

///|
test "a truncated version reply waits for the rest of the line" {
  let decoder = @memcached.Decoder::new()
  decoder.feed(b"VERSION 1.6")
  assert_true(decoder.next() is None)
  decoder.feed(b".21\r\n")
  match decoder.next() {
    Some(@memcached.Response::Version(version)) =>
      assert_true(version == "1.6.21")
    _ => abort("expected a version response")
  }
}

///|
test "stats lines without a value are rejected" {
  assert_true(reaction(b"STAT noseparator\r\nEND\r\n") == "malformed")
  assert_true(reaction(b"STAT \r\nEND\r\n") == "malformed")
}

///|
test "a stats block that never ends waits for more data" {
  assert_true(reaction(b"STAT pid 1\r\n") == "accepted")
  assert_true(reaction(b"STAT pid 1\r\nSTA") == "accepted")
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
test "client storage conveniences forward flags and exptime" {
  let connection : @memcached.ScriptedConnection = @memcached.ScriptedConnection::new([
      b"STORED\r\n", b"STORED\r\n",
    ],
  )
  let client = @memcached.Client::new(connection)
  assert_true(
    client.set("foo", b"bar", flags=7, exptime=60) == @memcached.Status::Stored,
  )
  assert_true(
    client.cas("foo", b"bar", 42UL, exptime=30) == @memcached.Status::Stored,
  )
  assert_true(
    connection.written() ==
    b"set foo 7 60 3\r\nbar\r\ncas foo 0 30 3 42\r\nbar\r\n",
  )
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
test "client touch, gat and gats drive their commands" {
  let connection : @memcached.ScriptedConnection = @memcached.ScriptedConnection::new([
      b"TOUCHED\r\n", b"VALUE foo 0 3\r\nbar\r\nEND\r\n", b"END\r\n",
    ],
  )
  let client = @memcached.Client::new(connection)
  assert_true(client.touch("foo", 30) == @memcached.Status::Touched)
  let hits = client.gat(["foo"], 30)
  assert_true(hits.length() == 1)
  assert_true(hits[0].data == b"bar")
  assert_true(client.gats(["nope"], 30).length() == 0)
  assert_true(
    connection.written() == b"touch foo 30\r\ngat 30 foo\r\ngats 30 nope\r\n",
  )
}

///|
test "client reads the version and the statistics" {
  let connection : @memcached.ScriptedConnection = @memcached.ScriptedConnection::new([
      b"VERSION 1.6.21\r\nSTAT pid 1234\r\nEND\r\n", b"STAT items:1:number 2\r\nEND\r\n",
    ],
  )
  let client = @memcached.Client::new(connection)
  assert_true(client.version() == "1.6.21")
  let stats = client.stats()
  assert_true(stats.length() == 1)
  assert_true(stats[0].name == "pid")
  assert_true(stats[0].value == "1234")
  let items = client.stats_of("items")
  assert_true(items.length() == 1)
  assert_true(items[0].name == "items:1:number")
  assert_true(connection.written() == b"version\r\nstats\r\nstats items\r\n")
}

///|
test "client flush_all and verbosity read the OK acknowledgement" {
  let connection : @memcached.ScriptedConnection = @memcached.ScriptedConnection::new([
      b"OK\r\n", b"OK\r\n",
    ],
  )
  let client = @memcached.Client::new(connection)
  assert_true(client.flush_all(None) == @memcached.Status::Ok)
  assert_true(client.verbosity(2) == @memcached.Status::Ok)
  assert_true(connection.written() == b"flush_all\r\nverbosity 2\r\n")
}

///|
test "client send writes a noreply command without reading an answer" {
  let connection : @memcached.ScriptedConnection = @memcached.ScriptedConnection::new([],
  )
  let client = @memcached.Client::new(connection)
  client.send(@memcached.Request::Delete(key="quiet", noreply=true))
  assert_true(connection.written() == b"delete quiet noreply\r\n")
}

///|
test "a command without a reply cannot be executed" {
  let connection : @memcached.ScriptedConnection = @memcached.ScriptedConnection::new([
      b"STORED\r\n",
    ],
  )
  let client = @memcached.Client::new(connection)
  let outcome = try {
    let _ = client.execute(@memcached.Request::Quit)
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
test "a command that has a reply cannot be sent blind" {
  let connection : @memcached.ScriptedConnection = @memcached.ScriptedConnection::new([],
  )
  let client = @memcached.Client::new(connection)
  let outcome = try {
    client.send(@memcached.Request::Version)
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

///|
test "a stream that never frames is refused instead of buffered forever" {
  let connection : @memcached.ScriptedConnection = @memcached.ScriptedConnection::new([
      b"VALUE foo 0 1000000\r\n",
    ],
  )
  let client = @memcached.Client::with_limit(connection, 16)
  let outcome = try {
    let _ = client.get(["foo"])
    "accepted"
  } catch {
    err =>
      match err {
        @memcached.ProtocolError::Malformed(_) => "malformed"
        @memcached.ProtocolError::Desynchronised(_, _) => "desynchronised"
        _ => "other"
      }
  }
  // A 16-byte decoder can never hold a million-byte block, and the header says
  // so on its own, so the block is named as the fault instead of the buffer
  // being filled up first and the stream called lost afterwards.
  assert_true(outcome == "malformed")
}

///|
/// Describe how a decoder with `limit` bytes of room reacts to `input`:
/// `"accepted"` when a response came out, `"none"` while it keeps waiting for
/// more bytes, `"<limit>/<buffered>"` when it declares the stream out of sync,
/// or `"malformed"` when it refuses the bytes instead of waiting for the rest.
fn limited_reaction(limit : Int, input : Bytes) -> String {
  let decoder = @memcached.Decoder::with_limit(limit)
  decoder.feed(input.view())
  try {
    match decoder.next() {
      Some(_) => "accepted"
      None => "none"
    }
  } catch {
    err =>
      match err {
        @memcached.ProtocolError::Desynchronised(cap, buffered) =>
          "\{cap}/\{buffered}"
        @memcached.ProtocolError::Malformed(_) => "malformed"
        _ => "other"
      }
  }
}

///|
test "a decoder with no room still decodes a whole response" {
  // The cap is only consulted while the decoder is waiting, so a response that
  // is already complete comes out of a decoder of any size.
  assert_true(limited_reaction(0, b"STORED\r\n") == "accepted")
  // A prefix has no room to wait in, and the error names the cap it broke.
  assert_true(limited_reaction(0, b"STORED") == "0/6")
}

///|
test "the buffer cap is inclusive, so a full buffer may still wait" {
  assert_true(limited_reaction(8, b"12345678") == "none")
  assert_true(limited_reaction(8, b"123456789") == "8/9")
}

///|
test "a block larger than the limit is refused without filling the buffer" {
  // The header alone says the block can never arrive whole in this decoder, so
  // even a decoder with no room at all reports the block rather than waiting
  // for a cap it would break anyway.
  assert_true(
    limited_reaction(0, b"VALUE k 0 1\r\nx\r\nEND\r\n") == "malformed",
  )
  assert_true(limited_reaction(64, b"VALUE k 0 100\r\nabc") == "malformed")
  // A declaration the limit can hold is a block still on its way, not a fault.
  assert_true(limited_reaction(128, b"VALUE k 0 100\r\nabc") == "none")
}

///|
test "a client limit that fits its replies leaves the client working" {
  let connection : @memcached.ScriptedConnection = @memcached.ScriptedConnection::new([
      b"STORED\r\n", b"VALUE foo 0 3\r\nbar\r\nEND\r\n",
    ],
  )
  let client = @memcached.Client::with_limit(connection, 64)
  assert_true(client.set("foo", b"bar") == @memcached.Status::Stored)
  assert_true(client.get(["foo"])[0].data == b"bar")
  assert_true(connection.written() == b"set foo 0 0 3\r\nbar\r\nget foo\r\n")
}

///|
/// A connection whose writes always fail, used to probe send-error cleanup.
struct FailingWriteConnection {
  mut closed : Bool
}

///|
impl @memcached.Connection for FailingWriteConnection with fn write(self, _data) {
  ignore(self)
  raise @memcached.TransportError::Io("write failed")
}

///|
impl @memcached.Connection for FailingWriteConnection with fn read(self, _max) {
  ignore(self)
  b""
}

///|
impl @memcached.Connection for FailingWriteConnection with fn close(self) {
  self.closed = true
}

///|
test "quit releases the connection when the command cannot be written" {
  let connection : FailingWriteConnection = { closed: false }
  let client = @memcached.Client::new(connection)
  let outcome = try {
    client.quit()
    "accepted"
  } catch {
    err =>
      match err {
        @memcached.TransportError::Io(_) => "io"
        _ => "other"
      }
  }
  assert_true(outcome == "io")
  assert_true(connection.closed)
}
