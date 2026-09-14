// Byte transport for the memcached text protocol client.
//
// The client owns exactly one connection and speaks the text protocol over it.
// Keeping the channel behind a trait lets the protocol logic run against an
// in-memory transcript, which is what the targets available here can verify.

///|
/// Failure raised while moving bytes to or from the server.
///
/// The variants stay constructible outside the package: a `Connection`
/// implementation living in another package has to be able to raise them.
pub(all) suberror TransportError {
  /// The underlying channel failed, e.g. it was reset or ended early.
  Io(String)
} derive(@debug.Debug)

///|
/// A duplex byte channel.
pub(open) trait Connection {
  /// Send every byte of `data` to the peer.
  fn write(Self, BytesView) -> Unit raise TransportError
  /// Receive at most `max` bytes, waiting until at least one byte is available.
  ///
  /// An empty result means the peer closed the connection.
  fn read(Self, Int) -> Bytes raise TransportError
  /// Close the channel and release its resources.
  fn close(Self) -> Unit raise TransportError
}

///|
/// An in-memory [`Connection`] that replays a canned server transcript.
///
/// Everything the client writes is recorded, so the connection doubles as a
/// spy. It stands in for a real socket in the examples and tests, since the
/// targets usable here cannot open one.
pub struct ScriptedConnection {
  chunks : Array[Bytes]
  mut index : Int
  mut pending : Bytes
  written : @buffer.Buffer
}

///|
/// Build a connection whose reads replay `chunks` in order.
///
/// Each element is handed out by a separate read (truncated to the requested
/// size), which makes it easy to force the client through partial responses.
pub fn ScriptedConnection::new(chunks : Array[Bytes]) -> ScriptedConnection {
  { chunks, index: 0, pending: Bytes::new(0), written: @buffer.Buffer() }
}

///|
/// Every byte the client has written so far.
pub fn ScriptedConnection::written(self : ScriptedConnection) -> Bytes {
  self.written.to_bytes()
}

///|
pub impl Connection for ScriptedConnection with fn write(self, data) {
  self.written.write_bytesview(data)
}

///|
pub impl Connection for ScriptedConnection with fn read(self, max) {
  while self.pending.length() == 0 {
    guard self.index < self.chunks.length() else { return Bytes::new(0) }
    self.pending = self.chunks[self.index]
    self.index += 1
  }
  let take = if self.pending.length() < max {
    self.pending.length()
  } else {
    max
  }
  let head = self.pending.view(end=take).to_owned()
  self.pending = self.pending.view(start=take).to_owned()
  head
}

///|
pub impl Connection for ScriptedConnection with fn close(self) {
  self.index = self.chunks.length()
  self.pending = Bytes::new(0)
}
