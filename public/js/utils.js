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

function streamChunk(share, streamUuid, start, length, ws, cb) {
  const reader = new FileReader();
  reader.onload = function (e) {
    if (length === 0) {
      console.error("can't stream chunk of length 0");
      return;
    }
    const close = (start + length) === share.file.size;
    ws.send(JSON.stringify({
      type: "chunk",
      uuid: streamUuid,
      close: close,
      chunk: btoa(e.target.result)
    }));
    if (cb) cb(close);
  };
  const blob = share.file.slice(start, start + length);
  reader.readAsBinaryString(blob);
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
  } else {
    let position = 0;
    function chunkStreamed(done) {
      if (done) {
        if (cb) cb();
        return;
      }
      const start = position;
      const length = Math.min(1024000, share.size - position);
      position += length;
      streamChunk(share, streamUuid, start, length, ws, chunkStreamed);
    }
    chunkStreamed(false);
  }
}
