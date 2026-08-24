// --- Direct browser-to-browser transfer (WebRTC DataChannel) ---------------
//
// Devices behind the same public IP are usually on the same LAN. Instead of
// relaying the file through the server (up the uplink and back down), the
// receiver opens a DataChannel to the sender, signaled over the existing
// WebSocket. Only LAN host candidates are used (mDNS names or private
// addresses; no STUN, no TURN): the direct path can only succeed on the actual
// local network and no public address is disclosed to anybody. If the channel isn't open within RTC_CONNECT_TIMEOUT
// the download silently falls back to the relay (GET /share/:uuid), exactly
// as before. The server never sees the content: DTLS encrypts the channel
// end to end.
//
// Wire protocol on the channel (sender -> receiver):
//   text   {"size": <bytes>}     header
//   binary <chunk> ...           file content, in order
//   text   {"done": true}        end of file
//   text   {"error": true}       sender gave up

const RTC_CONNECT_TIMEOUT = 5000;              // ms from offer to open channel (mDNS on Wi-Fi can take 1-2 s)
const RTC_CHUNK_SIZE = 64 * 1024;              // safe SCTP message size everywhere
const RTC_HIGH_WATER = 4 * 1024 * 1024;        // sender pauses above this bufferedAmount
const RTC_LOW_WATER = 1024 * 1024;             // ...and resumes below this
const RTC_BLOB_MAX = 200 * 1024 * 1024;        // in-memory sink limit without a service worker
const RTC_SENDER_LINGER = 60000;               // ms a sender waits for the receiver to close

const rtcSessions = {};        // session uuid => state (either role)
const rtcPendingOffers = {};   // share uuid => receiver state waiting for its session id

function rtcSupported() {
  return typeof RTCPeerConnection === 'function' && typeof MessageChannel === 'function';
}

// An address that can only be reached from the local network: an mDNS name
// (Chrome, Safari) or a private / link-local address (Firefox doesn't hide
// host candidates behind mDNS by default). Never a public address.
function rtcIsLanAddress(address) {
  if (/\.local$/i.test(address)) return true;
  const v4 = address.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
  if (v4) {
    const a = Number(v4[1]), b = Number(v4[2]);
    return a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 169 && b === 254);
  }
  // IPv6: unique local (fc00::/7) or link-local (fe80::/10)
  return /^f[cd][0-9a-f]{2}:/i.test(address) || /^fe[89ab][0-9a-f]:/i.test(address);
}

// "candidate:<foundation> <component> <proto> <priority> <address> <port> typ <type> ..."
// An empty string is the end-of-candidates marker. The server enforces the
// same rule; filtering here too keeps the LAN-only guarantee explicit.
function rtcIsLanCandidate(candidate) {
  if (!candidate) return true;
  const f = candidate.split(' ');
  return f[6] === 'typ' && f[7] === 'host' && rtcIsLanAddress(f[4] || '');
}

function rtcSignal(state, msg) {
  const ws = state.ws;
  if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(msg));
}

function rtcNewPeer(state) {
  const pc = new RTCPeerConnection({ iceServers: [] });
  state.pc = pc;
  state.pendingLocalIce = [];
  state.pendingRemoteIce = [];
  state.stats = { local: 0, localDropped: 0, remote: 0 };
  pc.onicecandidate = (e) => {
    const c = e.candidate;
    const candidate = c
      ? { candidate: c.candidate, sdpMid: c.sdpMid, sdpMLineIndex: c.sdpMLineIndex, usernameFragment: c.usernameFragment }
      : { candidate: '' };
    if (!rtcIsLanCandidate(candidate.candidate)) {
      state.stats.localDropped++;
      console.log('rtc: dropping non-LAN candidate: ' + candidate.candidate);
      return;
    }
    if (c) state.stats.local++;
    console.log('rtc ' + state.role + ': local candidate ' + (candidate.candidate || '(end)'));
    if (state.session) {
      rtcSignal(state, { type: 'rtc_ice', session: state.session, candidate });
    } else {
      state.pendingLocalIce.push(candidate);
    }
  };
  pc.onconnectionstatechange = () => {
    console.log('rtc ' + state.role + ': connection ' + pc.connectionState);
    if (pc.connectionState === 'failed') rtcFail(state, 'ice-failed');
  };
  pc.oniceconnectionstatechange = () => console.log('rtc ' + state.role + ': ice ' + pc.iceConnectionState);
  return pc;
}

function rtcAddRemoteIce(state, candidate) {
  if (!state.pc || !state.pc.remoteDescription) {
    state.pendingRemoteIce.push(candidate);
    return;
  }
  if (candidate.candidate) state.stats.remote++;
  console.log('rtc ' + state.role + ': remote candidate ' + (candidate.candidate || '(end)') + ' mid=' + candidate.sdpMid + ' idx=' + candidate.sdpMLineIndex);
  state.pc.addIceCandidate(candidate).catch((err) => console.warn('addIceCandidate failed', err));
}

function rtcFlushRemoteIce(state) {
  const pending = state.pendingRemoteIce;
  state.pendingRemoteIce = [];
  pending.forEach((candidate) => rtcAddRemoteIce(state, candidate));
}

function rtcTeardown(state, reason) {
  if (state.closed) return;
  state.closed = true;
  clearTimeout(state.timer);
  if (state.share && rtcPendingOffers[state.share.uuid] === state) delete rtcPendingOffers[state.share.uuid];
  if (state.session) {
    delete rtcSessions[state.session];
    if (!state.peerClosed) rtcSignal(state, { type: 'rtc_close', session: state.session, reason });
  }
  const pc = state.pc;
  const stats = state.stats || {};
  console.log('rtc ' + state.role + ' session ended: ' + reason +
    (pc ? ' (ice ' + pc.iceConnectionState + ', gathering ' + pc.iceGatheringState +
      ', local LAN candidates ' + stats.local + ', dropped ' + stats.localDropped +
      ', remote ' + stats.remote + ', session ' + (state.session ? 'yes' : 'no') + ')' : ''));
  try { if (state.dc) state.dc.close(); } catch (e) { /* already closed */ }
  try { if (state.pc) state.pc.close(); } catch (e) { /* already closed */ }
}

// The direct path is over for this transfer. For a receiver that hasn't
// finished, that means going back to the relay.
function rtcDumpPairs(pc, role) {
  if (!pc || !pc.getStats) return;
  pc.getStats().then((report) => {
    const byId = {};
    report.forEach((r) => { byId[r.id] = r; });
    report.forEach((r) => {
      if (r.type !== 'candidate-pair') return;
      const l = byId[r.localCandidateId] || {}, m = byId[r.remoteCandidateId] || {};
      console.log('rtc ' + role + ': pair ' + r.state + ' ' + (l.address || l.ip) + ':' + l.port + '/' + l.protocol +
        ' -> ' + (m.address || m.ip) + ':' + m.port + '/' + m.protocol + ' sent=' + r.requestsSent + ' recv=' + r.responsesReceived);
    });
  }).catch(() => {});
}

function rtcFail(state, reason) {
  if (state.closed || state.done) return;
  rtcDumpPairs(state.pc, state.role);
  rtcTeardown(state, reason);
  if (state.role === 'receiver') {
    if (state.sink) state.sink.abort();
    state.handlers.onFallback(reason);
  }
}

// --- Receiver ----------------------------------------------------------------

async function rtcDownload(share, ws, handlers) {
  if (rtcPendingOffers[share.uuid]) return; // already in progress
  const sink = await rtcCreateSink(share);
  if (!sink) {
    handlers.onFallback('no-sink');
    return;
  }
  const state = {
    role: 'receiver', share, ws, handlers, sink,
    session: null, received: 0, size: share.size, started: false, done: false, closed: false
  };
  sink.oncancel = () => {
    // The user cancelled the download in the browser UI: don't fall back.
    state.done = true;
    rtcTeardown(state, 'cancelled');
    handlers.onAbort();
  };
  const pc = rtcNewPeer(state);
  const dc = pc.createDataChannel('file', { ordered: true });
  dc.binaryType = 'arraybuffer';
  state.dc = dc;
  dc.onopen = () => {
    clearTimeout(state.timer);
    state.connected = true;
    handlers.onConnected();
  };
  dc.onmessage = (e) => rtcReceiverMessage(state, e.data);
  dc.onclose = () => rtcFail(state, 'channel-closed');
  dc.onerror = () => rtcFail(state, 'channel-error');

  rtcPendingOffers[share.uuid] = state;
  state.timer = setTimeout(() => rtcFail(state, 'timeout'), RTC_CONNECT_TIMEOUT);
  try {
    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    if (state.closed) return;
    rtcSignal(state, { type: 'rtc_offer', share: share.uuid, sdp: pc.localDescription.sdp });
  } catch (err) {
    console.warn('rtc offer failed', err);
    rtcFail(state, 'offer-error');
  }
}

function rtcReceiverMessage(state, data) {
  if (state.closed) return;
  if (typeof data === 'string') {
    let msg;
    try { msg = JSON.parse(data); } catch (e) { return rtcFail(state, 'protocol'); }
    if (!state.started && typeof msg.size === 'number') {
      state.started = true;
      state.size = msg.size;
      // The filename comes from the share list (sanitized by the server), not
      // from the peer.
      Promise.resolve(state.sink.start(state.share.name, msg.size))
        .catch((err) => { console.warn('sink failed', err); rtcFail(state, 'sink-error'); });
    } else if (msg.done) {
      if (state.received !== state.size) return rtcFail(state, 'incomplete');
      state.done = true;
      state.sink.close();
      state.handlers.onDone();
      rtcTeardown(state, 'done');
    } else if (msg.error) {
      rtcFail(state, 'sender-error');
    }
    return;
  }
  if (!state.started) return rtcFail(state, 'protocol');
  state.received += data.byteLength;
  if (state.received > state.size) return rtcFail(state, 'overflow');
  state.sink.write(data);
  state.handlers.onProgress(state.received, state.size);
}

// --- Receiver sinks ----------------------------------------------------------
//
// A sink is { start(name, size), write(ArrayBuffer), close(), abort() } plus an
// `oncancel` callback. Preferred: a service worker streams the bytes straight
// into a regular browser download (no size limit, real progress bar).
// Fallback: buffer in memory and save a Blob, only for small files. Without
// either, the relay is used.

async function rtcCreateSink(share) {
  if (await rtcServiceWorkerReady()) return rtcStreamSink();
  if (typeof share.size === 'number' && share.size <= RTC_BLOB_MAX) return rtcBlobSink();
  return null;
}

async function rtcServiceWorkerReady() {
  if (!('serviceWorker' in navigator)) return false;
  try {
    if (navigator.serviceWorker.controller) return true;
    const registration = await navigator.serviceWorker.getRegistration('/');
    if (!registration) return false;
    // A freshly registered worker claims open pages on activation; give it a moment.
    await Promise.race([navigator.serviceWorker.ready, new Promise((r) => setTimeout(r, 1000))]);
    return !!navigator.serviceWorker.controller;
  } catch (e) {
    return false;
  }
}

function rtcStreamSink() {
  const id = generateUUID();
  const queue = [];
  let port = null;
  let ready = false;
  let iframe = null;
  const sink = { oncancel: null };

  const post = (msg, transfer) => port.postMessage(msg, transfer || []);
  const removeIframe = () => { if (iframe) { iframe.remove(); iframe = null; } };

  sink.start = (name, size) => new Promise((resolve, reject) => {
    const channel = new MessageChannel();
    port = channel.port1;
    const timer = setTimeout(() => reject(new Error('service worker did not answer')), 2000);
    port.onmessage = (e) => {
      const msg = e.data || {};
      if (msg.type === 'dl-ready') {
        clearTimeout(timer);
        ready = true;
        while (queue.length) { const buf = queue.shift(); post(buf, [buf]); }
        // Navigating a hidden iframe to the worker-served URL starts a normal
        // browser download without leaving the page.
        iframe = document.createElement('iframe');
        iframe.hidden = true;
        iframe.src = '/dl/' + id;
        document.body.appendChild(iframe);
        resolve();
      } else if (msg.type === 'dl-cancel') {
        if (sink.oncancel) sink.oncancel();
      }
    };
    navigator.serviceWorker.controller.postMessage({ type: 'dl-open', id, name, size }, [channel.port2]);
  });
  sink.write = (buf) => {
    if (ready) post(buf, [buf]);
    else queue.push(buf);
  };
  sink.close = () => {
    post({ type: 'dl-end' });
    setTimeout(removeIframe, RTC_SENDER_LINGER);
  };
  sink.abort = () => {
    if (port) post({ type: 'dl-abort' });
    removeIframe();
  };
  return sink;
}

function rtcBlobSink() {
  const chunks = [];
  let name = 'download';
  return {
    oncancel: null,
    start(n) { name = n; },
    write(buf) { chunks.push(buf); },
    close() {
      const url = URL.createObjectURL(new Blob(chunks));
      const a = document.createElement('a');
      a.href = url;
      a.download = name;
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(url), RTC_SENDER_LINGER);
    },
    abort() { chunks.length = 0; }
  };
}

// --- Sender ------------------------------------------------------------------

async function rtcHandleOffer(msg, ws, localShares) {
  const share = localShares[msg.share];
  const state = { role: 'sender', share, ws, session: msg.session, closed: false };
  if (!share) {
    rtcSignal(state, { type: 'rtc_close', session: msg.session, reason: 'unknown-share' });
    return;
  }
  rtcSessions[msg.session] = state;
  const pc = rtcNewPeer(state);
  pc.ondatachannel = (e) => {
    const dc = e.channel;
    dc.binaryType = 'arraybuffer';
    dc.bufferedAmountLowThreshold = RTC_LOW_WATER;
    state.dc = dc;
    dc.onclose = () => rtcTeardown(state, 'channel-closed');
    dc.onerror = () => rtcTeardown(state, 'channel-error');
    // Chrome may hand us a channel that is already open: onopen won't fire then.
    if (dc.readyState === 'open') rtcPump(state);
    else dc.onopen = () => rtcPump(state);
  };
  state.timer = setTimeout(() => {
    if (!state.dc || state.dc.readyState !== 'open') rtcTeardown(state, 'timeout');
  }, RTC_CONNECT_TIMEOUT * 2);
  try {
    await pc.setRemoteDescription({ type: 'offer', sdp: msg.sdp });
    rtcFlushRemoteIce(state);
    const answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    if (state.closed) return;
    rtcSignal(state, { type: 'rtc_answer', session: msg.session, sdp: pc.localDescription.sdp });
    state.pendingLocalIce.forEach((candidate) => rtcSignal(state, { type: 'rtc_ice', session: state.session, candidate }));
    state.pendingLocalIce = [];
  } catch (err) {
    console.warn('rtc answer failed', err);
    rtcTeardown(state, 'answer-error');
  }
}

function rtcBufferedLow(dc) {
  return new Promise((resolve) => {
    if (dc.readyState !== 'open' || dc.bufferedAmount <= RTC_LOW_WATER) return resolve();
    const done = () => {
      dc.removeEventListener('bufferedamountlow', done);
      dc.removeEventListener('close', done);
      resolve();
    };
    dc.addEventListener('bufferedamountlow', done);
    dc.addEventListener('close', done);
  });
}

async function rtcPump(state) {
  const { dc, share } = state;
  clearTimeout(state.timer);
  const source = share.file || new Blob([share.content || ''], { type: 'text/plain' });
  try {
    dc.send(JSON.stringify({ size: source.size }));
    let pos = 0;
    while (pos < source.size) {
      if (state.closed || dc.readyState !== 'open') return;
      if (dc.bufferedAmount > RTC_HIGH_WATER) {
        await rtcBufferedLow(dc);
        continue;
      }
      const buf = await source.slice(pos, pos + RTC_CHUNK_SIZE).arrayBuffer();
      if (state.closed || dc.readyState !== 'open') return;
      dc.send(buf);
      pos += buf.byteLength;
    }
    dc.send(JSON.stringify({ done: true }));
    // The receiver closes the session once it has everything.
    state.timer = setTimeout(() => rtcTeardown(state, 'linger-timeout'), RTC_SENDER_LINGER);
  } catch (err) {
    console.warn('rtc send failed', err);
    try { dc.send(JSON.stringify({ error: true })); } catch (e) { /* channel gone */ }
    rtcTeardown(state, 'send-error');
  }
}

// --- Signaling messages from the server -------------------------------------

function rtcHandleMessage(msg, ws, localShares) {
  switch (msg.type) {
    case 'rtc_session': {
      const state = rtcPendingOffers[msg.share];
      if (!state) return;
      delete rtcPendingOffers[msg.share];
      state.session = msg.session;
      rtcSessions[msg.session] = state;
      state.pendingLocalIce.forEach((candidate) => rtcSignal(state, { type: 'rtc_ice', session: msg.session, candidate }));
      state.pendingLocalIce = [];
      break;
    }
    case 'rtc_offer':
      rtcHandleOffer(msg, ws, localShares);
      break;
    case 'rtc_answer': {
      const state = rtcSessions[msg.session];
      if (!state || state.role !== 'receiver') return;
      state.pc.setRemoteDescription({ type: 'answer', sdp: msg.sdp })
        .then(() => rtcFlushRemoteIce(state))
        .catch((err) => { console.warn('rtc setRemoteDescription failed', err); rtcFail(state, 'answer-error'); });
      break;
    }
    case 'rtc_ice': {
      const state = rtcSessions[msg.session];
      if (state) rtcAddRemoteIce(state, msg.candidate);
      break;
    }
    case 'rtc_close': {
      const state = rtcSessions[msg.session];
      if (!state) return;
      state.peerClosed = true;
      if (state.done) rtcTeardown(state, 'peer-closed');
      else rtcFail(state, 'peer-closed');
      break;
    }
    default:
      break;
  }
}

// The WebSocket dropped: handshakes in flight can't complete. Established
// channels don't need the socket and carry on.
function rtcSocketClosed() {
  Object.values(rtcPendingOffers).forEach((state) => rtcFail(state, 'socket-closed'));
  Object.values(rtcSessions).forEach((state) => {
    if (!state.connected && state.role === 'receiver') rtcFail(state, 'socket-closed');
  });
}
