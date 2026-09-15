// Runnable tour of the memcached text protocol codec and of the single
// connection client. Run with `moon run cmd/main`.

///|
/// Render `bytes` as text, escaping control bytes so the framing stays visible.
///
/// The bytes are escaped one at a time instead of being handed to
/// `Bytes::to_string`, which renders a `Bytes` value (`b"..."`) rather than
/// decoding it.
fn render(bytes : Bytes) -> String {
  let out = StringBuilder()
  for byte in bytes {
    out.write_string(byte.to_char().escape(quote=false))
  }
  out.to_string()
}

///|
/// Human readable name of a terminal status line.
fn status_name(status : @lib.Status) -> String {
  if status == @lib.Status::Stored {
    "STORED"
  } else if status == @lib.Status::NotStored {
    "NOT_STORED"
  } else if status == @lib.Status::Exists {
    "EXISTS"
  } else if status == @lib.Status::NotFound {
    "NOT_FOUND"
  } else if status == @lib.Status::Deleted {
    "DELETED"
  } else if status == @lib.Status::Touched {
    "TOUCHED"
  } else {
    "OK"
  }
}

///|
/// Render an optional CAS token, using `-` when the server did not send one.
fn cas_text(cas : UInt64?) -> String {
  match cas {
    Some(unique) => unique.to_string()
    None => "-"
  }
}

///|
fn run() -> Unit raise {
  println("== request encoding ==")
  let set_request : @lib.Request = @lib.Request::Storage(
    op=@lib.StorageOp::Set,
    key="foo",
    flags=0,
    exptime=0,
    value=b"bar",
    cas=None,
    noreply=false,
  )
  println("set  -> \{render(set_request.to_bytes())}")
  let gets_request : @lib.Request = @lib.Request::Get(
    keys=["foo", "bar"],
    with_cas=true,
  )
  println("gets -> \{render(gets_request.to_bytes())}")
  let delete_request : @lib.Request = @lib.Request::Delete(
    key="foo",
    noreply=false,
  )
  println("del  -> \{render(delete_request.to_bytes())}")
  let gat_request : @lib.Request = @lib.Request::Gat(
    keys=["foo"],
    exptime=30,
    with_cas=false,
  )
  println("gat  -> \{render(gat_request.to_bytes())}")
  let quiet_delete : @lib.Request = @lib.Request::Delete(
    key="foo",
    noreply=true,
  )
  println("del! -> \{render(quiet_delete.to_bytes())}")
  let stats_request : @lib.Request = @lib.Request::Stats(sub=Some("items"))
  println("stat -> \{render(stats_request.to_bytes())}")
  println(
    "flush-> \{render(@lib.Request::FlushAll(delay=Some(10), noreply=false).to_bytes())}",
  )

  println("")
  println("== single-connection client ==")
  let connection = @lib.ScriptedConnection::new([
    b"STORED\r\n", b"VALUE foo 0 3\r\nbar\r\nEND\r\n",
  ])
  let client = @lib.Client::new(connection)
  println("set  -> \{status_name(client.set("foo", b"bar"))}")
  let values = client.get(["foo"])
  println("get  -> \{values.length()} value(s)")
  for value in values {
    println(
      "  key=\{value.key} flags=\{value.flags} data=\{render(value.data)} cas=\{cas_text(value.cas)}",
    )
  }
  println("wire -> \{render(connection.written())}")

  println("")
  println("== noreply and administrative commands ==")
  let admin = @lib.ScriptedConnection::new([
    b"VERSION 1.6.21\r\nSTAT curr_items 2\r\nSTAT version 1.6.21\r\nEND\r\n", b"OK\r\n",
  ])
  let admin_client = @lib.Client::new(admin)
  println("version -> \{admin_client.version()}")
  let stats = admin_client.stats()
  for entry in stats {
    println("stat    -> \{entry.name} = \{entry.value}")
  }
  println("flush   -> \{status_name(admin_client.flush_all(None))}")
  admin_client.send(@lib.Request::Delete(key="gone", noreply=true))
  println("wire -> \{render(admin.written())}")

  println("")
  println("== incremental decoding ==")
  let decoder = @lib.Decoder::new()
  decoder.feed(b"VALUE k 0 5\r\nhel")
  println(
    "half a response buffered: next() is none -> \{decoder.next() is None}",
  )
  decoder.feed(b"lo\r\nEND\r\n")
  println("after the rest: next() is some -> \{decoder.next() is Some(_)}")
  println("bytes left in the decoder: \{decoder.buffered()}")
}

///|
fn main {
  run() catch {
    err => println("error: \{err}")
  }
}
