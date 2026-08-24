const { useState, useEffect, useRef, useCallback } = React;

function App() {
  const [connected, setConnected] = useState(false);
  const [remoteShares, setRemoteShares] = useState([]);
  const [localShares, setLocalShares] = useState({});
  const [qrModal, setQrModal] = useState(null);
  const [textValue, setTextValue] = useState('');
  const wsRef = useRef(null);
  const pingRef = useRef(null);
  const reconnectTimerRef = useRef(null);
  const reconnectDelayRef = useRef(1000);
  const setupRef = useRef(null);
  // Keep a synchronous ref of local shares for streaming lookups
  const localSharesRef = useRef({});
  const downloadHost = `${document.location.protocol}//${document.location.host}`;

  const addFileShare = useCallback((file) => {
    if (file.size >= 5000 * 1024 * 1024) {
      console.error("File size too high: " + file.size);
      alert("File size too high: " + file.size);
      return;
    }

    const uuid = generateUUID();
    console.log("add file to store, uuid:", uuid);

    const share = {
      name: file.name,
      size: file.size,
      type: file.type,
      uuid: uuid,
      file: file,
    };

    // Update ref synchronously before sending WebSocket message
    localSharesRef.current[uuid] = share;
    setLocalShares(prev => ({ ...prev, [uuid]: share }));

    if (wsRef.current && wsRef.current.readyState === WebSocket.OPEN) {
      wsRef.current.send(JSON.stringify({
        type: "register_share",
        uuid: uuid,
        name: file.name,
        content_type: file.type,
        size: file.size
      }));
    }
  }, []);

  const addContentShare = useCallback((content) => {
    const uuid = generateUUID();
    console.log("add content to store, uuid:", uuid);

    const share = {
      name: "clipboard",
      size: content.length,
      type: "text/plain",
      uuid: uuid,
      content: content,
    };

    // Update ref synchronously before sending WebSocket message
    localSharesRef.current[uuid] = share;
    setLocalShares(prev => ({ ...prev, [uuid]: share }));

    if (wsRef.current && wsRef.current.readyState === WebSocket.OPEN) {
      wsRef.current.send(JSON.stringify({
        type: "register_share",
        uuid: uuid,
        name: ellipseAt(content, 100),
        content: content,
        content_type: "text/plain",
        size: content.length
      }));
    }
  }, []);

  const removeShare = useCallback((share) => {
    // Update ref synchronously
    delete localSharesRef.current[share.uuid];
    setLocalShares(prev => {
      const newShares = { ...prev };
      delete newShares[share.uuid];
      return newShares;
    });

    if (wsRef.current && wsRef.current.readyState === WebSocket.OPEN) {
      wsRef.current.send(JSON.stringify({
        type: "unregister_share",
        uuid: share.uuid
      }));
    }
  }, []);

  const handleStream = useCallback((msg) => {
    console.log("Should stream file " + msg.share + " to stream " + msg.uuid);
    // Use ref for synchronous lookup
    const share = localSharesRef.current[msg.share];
    if (share) {
      streamShare(share, msg.uuid, wsRef.current);
    } else {
      console.log("can't find share " + msg.share + " in shares", localSharesRef.current);
    }
  }, []);

  // Announce every local share to the server (on connect and after every
  // reconnect, since the server forgets us when the socket drops).
  const registerLocalShares = useCallback((ws) => {
    Object.values(localSharesRef.current).forEach((share) => {
      if (share.file) {
        ws.send(JSON.stringify({
          type: "register_share",
          uuid: share.uuid,
          name: share.name,
          content_type: share.type,
          size: share.size
        }));
      } else if (share.content) {
        ws.send(JSON.stringify({
          type: "register_share",
          uuid: share.uuid,
          name: ellipseAt(share.content, 100),
          content: share.content,
          content_type: "text/plain",
          size: share.size
        }));
      }
    });
  }, []);

  // Exactly one reconnect attempt is ever pending, with exponential backoff.
  // (Scheduling one from both onerror and onclose doubled the number of
  // sockets on every failure and saturated the server's per-IP limit.)
  const scheduleReconnect = useCallback(() => {
    if (reconnectTimerRef.current) return;
    const delay = reconnectDelayRef.current;
    reconnectDelayRef.current = Math.min(delay * 2, 30000);
    console.log("Reconnecting in " + delay + "ms");
    reconnectTimerRef.current = setTimeout(() => {
      reconnectTimerRef.current = null;
      if (setupRef.current) setupRef.current();
    }, delay);
  }, []);

  const setupWebSocket = useCallback(() => {
    const previous = wsRef.current;
    if (previous && previous.readyState !== WebSocket.CLOSED) {
      previous.onclose = null;
      previous.onerror = null;
      previous.close();
    }
    if (pingRef.current) {
      clearInterval(pingRef.current);
      pingRef.current = null;
    }

    const protocol = document.location.protocol === "https:" ? "wss:" : "ws:";
    const ws = new WebSocket(protocol + '//' + window.location.host + "/ws");
    wsRef.current = ws;

    ws.onopen = () => {
      setConnected(true);
      reconnectDelayRef.current = 1000;
      console.log('websocket opened');
      registerLocalShares(ws);
      pingRef.current = setInterval(() => {
        if (ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify({ type: "ping" }));
        }
      }, 10000);
    };

    ws.onclose = () => {
      console.log("Websocket closed");
      setConnected(false);
      setRemoteShares([]);
      streamAbortAll();
      if (pingRef.current) {
        clearInterval(pingRef.current);
        pingRef.current = null;
      }
      scheduleReconnect();
    };

    ws.onerror = () => {
      // A close event always follows an error; reconnection is handled there.
      console.log("Websocket error");
    };

    ws.onmessage = (m) => {
      const msg = JSON.parse(m.data);
      switch (msg.type) {
        case "shares":
          setRemoteShares(msg.shares);
          break;
        case "hello":
          console.log("Hello: " + msg.text);
          break;
        case "stream":
          handleStream(msg);
          break;
        case "ack":
          streamAck(msg.uuid);
          break;
        case "stream_close":
          streamAbort(msg.uuid);
          break;
        case "ping":
          ws.send(JSON.stringify({ type: "pong" }));
          break;
        case "pong":
          break;
        default:
          console.warn("Unknown message: " + msg.type);
      }
    };
  }, [handleStream, registerLocalShares, scheduleReconnect]);
  setupRef.current = setupWebSocket;

  useEffect(() => {
    setupWebSocket();
    return () => {
      if (reconnectTimerRef.current) {
        clearTimeout(reconnectTimerRef.current);
        reconnectTimerRef.current = null;
      }
      if (wsRef.current) {
        wsRef.current.onclose = null;
        wsRef.current.close();
      }
      if (pingRef.current) {
        clearInterval(pingRef.current);
        pingRef.current = null;
      }
    };
  }, []);

  useEffect(() => {
    const dropZone = document.querySelector('.dropzone');

    const handleDragOver = (e) => {
      e.stopPropagation();
      e.preventDefault();
      dropZone.classList.add("dropzone--dropping");
      e.dataTransfer.dropEffect = 'copy';
    };

    const handleDragEnter = (e) => {
      dropZone.classList.add("dropzone--dropping");
      return false;
    };

    const handleDragLeave = (e) => {
      e.preventDefault();
      e.stopPropagation();
      dropZone.classList.remove("dropzone--dropping");
      return false;
    };

    const handleDrop = (e) => {
      e.stopPropagation();
      e.preventDefault();
      dropZone.classList.remove("dropzone--dropping");
      const files = e.dataTransfer.files;
      if (files.length > 0) {
        for (let i = 0; i < files.length; i++) {
          addFileShare(files[i]);
        }
      } else {
        const text = e.dataTransfer.getData("Text");
        if (text) {
          addContentShare(text);
        }
      }
      return false;
    };

    dropZone.addEventListener('dragover', handleDragOver);
    dropZone.addEventListener('dragenter', handleDragEnter);
    dropZone.addEventListener('dragleave', handleDragLeave);
    dropZone.addEventListener('drop', handleDrop);

    return () => {
      dropZone.removeEventListener('dragover', handleDragOver);
      dropZone.removeEventListener('dragenter', handleDragEnter);
      dropZone.removeEventListener('dragleave', handleDragLeave);
      dropZone.removeEventListener('drop', handleDrop);
    };
  }, [addFileShare, addContentShare]);

  const handleTextShare = () => {
    if (textValue.length > 0) {
      addContentShare(textValue);
      setTextValue('');
    }
  };

  return (
    <>
      <Header />

      {!connected && (
        <div className="error-message">Disconnected, trying to reconnect...</div>
      )}

      <SharesList
        remoteShares={remoteShares}
        localShares={localShares}
        downloadHost={downloadHost}
        onRemove={removeShare}
        onShowQR={setQrModal}
      />

      {qrModal && (
        <QRCodeModal
          share={qrModal}
          downloadHost={downloadHost}
          onClose={() => setQrModal(null)}
        />
      )}

      <div className="uploads">
        <FileUpload onFileSelect={addFileShare} />
        <TextUpload
          value={textValue}
          onChange={setTextValue}
          onShare={handleTextShare}
        />
      </div>

      <HowTo />
      <Footer />
    </>
  );
}

const root = ReactDOM.createRoot(document.getElementById('root'));
root.render(<App />);
