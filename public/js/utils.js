function generateUUID() {
  let d = new Date().getTime();
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (c) {
    const r = (d + Math.random() * 16) % 16 | 0;
    d = Math.floor(d / 16);
    return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
  });
}

function ellipseAt(str, length) {
  return str.length > length ? str.substring(0, length) + "..." : str;
}

// --- Upload streaming with flow control -------------------------------------
//
// A share is streamed to the server in chunks over the WebSocket. The server
// acknowledges each chunk once the downloader has actually consumed it, and we
// keep at most STREAM_WINDOW chunks unacknowledged. Without this, a big file
// would be read entirely into the socket's send queue (gigabytes of memory in
// the tab, the same on the server) and the heartbeat pong would be stuck
// behind it, getting the connection killed.

const STREAM_CHUNK_SIZE = 1024000;
const STREAM_WINDOW = 4;                    // chunks in flight before waiting for acks
const STREAM_MAX_BUFFERED = 8 * 1024 * 1024; // don't push more if the socket queue is this big
const activeStreams = {};

function readChunkAsBase64(file, start, length, cb) {
  const reader = new FileReader();
  reader.onload = (e) => cb(btoa(e.target.result));
  reader.onerror = () => cb(null);
  reader.readAsBinaryString(file.slice(start, start + length));
}

function pumpStream(streamUuid) {
  const s = activeStreams[streamUuid];
  if (!s || s.reading) return;
  if (s.ws.readyState !== WebSocket.OPEN) {
    delete activeStreams[streamUuid];
    return;
  }
  if (s.inflight >= STREAM_WINDOW) return;
  if (s.ws.bufferedAmount > STREAM_MAX_BUFFERED) {
    setTimeout(() => pumpStream(streamUuid), 50);
    return;
  }

  const start = s.position;
  const length = Math.min(STREAM_CHUNK_SIZE, s.share.size - start);
  const close = start + length >= s.share.size;
  s.position += length;
  s.reading = true;

  const sendChunk = (b64) => {
    s.reading = false;
    if (!activeStreams[streamUuid]) return; // aborted meanwhile
    if (b64 === null) {
      console.error("can't read file chunk for stream " + streamUuid);
      delete activeStreams[streamUuid];
      return;
    }
    s.inflight++;
    s.ws.send(JSON.stringify({
      type: "chunk",
      uuid: streamUuid,
      close: close,
      chunk: b64
    }));
    if (close) {
      delete activeStreams[streamUuid];
      if (s.cb) s.cb();
    } else {
      pumpStream(streamUuid);
    }
  };

  if (length === 0) {
    sendChunk(""); // empty file: a single closing chunk
  } else {
    readChunkAsBase64(s.share.file, start, length, sendChunk);
  }
}

function streamShare(share, streamUuid, ws, cb) {
  console.log("stream share " + streamUuid + " (" + share.size + ")");
  if (share.content) {
    ws.send(JSON.stringify({
      type: "chunk",
      uuid: streamUuid,
      close: true,
      chunk: btoa(share.content)
    }));
    if (cb) cb();
    return;
  }
  activeStreams[streamUuid] = { share, ws, position: 0, inflight: 0, reading: false, cb };
  pumpStream(streamUuid);
}

// Server consumed a chunk: we may send another one.
function streamAck(streamUuid) {
  const s = activeStreams[streamUuid];
  if (!s) return;
  s.inflight = Math.max(0, s.inflight - 1);
  pumpStream(streamUuid);
}

// Downloader went away (or the socket died): stop reading the file.
function streamAbort(streamUuid) {
  delete activeStreams[streamUuid];
}

function streamAbortAll() {
  Object.keys(activeStreams).forEach((uuid) => delete activeStreams[uuid]);
}
