const { useState, useEffect, useRef, useCallback } = React;

function App() {
  const [connected, setConnected] = useState(false);
  const [remoteShares, setRemoteShares] = useState([]);
  const [localShares, setLocalShares] = useState({});
  const [qrModal, setQrModal] = useState(null);
  const [textValue, setTextValue] = useState('');
  const wsRef = useRef(null);
  const pingRef = useRef(null);
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
      content: content,
    };

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
    setLocalShares(current => {
      const share = current[msg.share];
      if (share) {
        streamShare(share, msg.uuid, wsRef.current);
      } else {
        console.log("can't find share " + msg.share + " in shares");
      }
      return current;
    });
  }, []);

  const setupWebSocket = useCallback(() => {
    const protocol = document.location.protocol === "https:" ? "wss:" : "ws:";
    const ws = new WebSocket(protocol + '//' + window.location.host + "/ws");
    wsRef.current = ws;

    ws.onopen = () => {
      setConnected(true);
      console.log('websocket opened');
      pingRef.current = setInterval(() => {
        ws.send(JSON.stringify({ type: "ping" }));
      }, 10000);
    };

    ws.onclose = () => {
      console.log("Websocket closed");
      setConnected(false);
      setRemoteShares([]);
      if (pingRef.current) {
        clearInterval(pingRef.current);
      }
      setTimeout(setupWebSocket, 2000);
    };

    ws.onerror = () => {
      console.log("Websocket error");
      setConnected(false);
      setRemoteShares([]);
      setTimeout(setupWebSocket, 10000);
    };

    ws.onmessage = (m) => {
      console.log('websocket message: ' + m.data);
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
        default:
          console.error("Unknown message: " + msg.type);
      }
    };
  }, [handleStream]);

  useEffect(() => {
    setupWebSocket();
    return () => {
      if (wsRef.current) {
        wsRef.current.close();
      }
      if (pingRef.current) {
        clearInterval(pingRef.current);
      }
    };
  }, [setupWebSocket]);

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
