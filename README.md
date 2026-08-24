Share file with people on the same network

## Direct transfers

Devices that see each other's shares (same public IP) are usually on the same
local network. When both sides are browsers, clicking **Download** first tries
a direct WebRTC DataChannel between them, signaled over the existing
WebSocket:

- Only LAN host candidates are used: mDNS `.local` names (Chrome, Safari) or
  private / link-local addresses (Firefox doesn't hide host candidates behind
  mDNS). No STUN, no TURN, no public address ever: the direct path can only
  succeed on the actual LAN. The server enforces this too and drops any other
  candidate. The only thing a peer in your namespace can learn is your private
  LAN address.
- A session can only be opened toward the owner of a share visible in your own
  namespace, i.e. exactly what `GET /share/:uuid` already allows.
- The channel is DTLS-encrypted end to end; the server only relays the
  handshake and never sees the content.
- If the channel is not open within 5 seconds (guest Wi-Fi client isolation,
  VLANs, different networks...), the download silently falls back to the
  server relay, exactly as before. `curl`, the QR code and `/all` always use
  the relay.

A service worker (`public/sw.js`) streams direct transfers straight into a
regular browser download, so file size is not limited by memory. Without it
(unsupported browser, insecure context), files up to 200 MB are saved from
memory and bigger ones use the relay.

Server logs report how each direct session ended (`RTC session ... closed:
done|timeout|...`), which tells you how often the direct path actually works.

