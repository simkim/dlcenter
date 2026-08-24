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

### Browser support and why the direct path may not activate

Browsers only advertise their LAN address as an mDNS `.local` name, so a direct
transfer needs both sides to *resolve* mDNS. Verified on a UniFi home network:

| sender \ receiver | Chrome / Safari (desktop, Android, iOS) | Firefox desktop | Firefox Android |
|---|---|---|---|
| Chrome / Safari / Firefox desktop | direct | direct | **relay** |
| Firefox Android | **relay** | **relay** | **relay** |

Firefox Android does not resolve mDNS candidates (no Android multicast lock),
so any transfer involving it falls back to the relay within a second. This is
a browser limitation; the only workarounds (a STUN server, or camera
permission to expose raw IPs) were deliberately rejected.

If a Chrome/Safari pair still uses the relay, check the network:

- **Client isolation** on the Wi-Fi (UniFi: *Client Device Isolation*):
  `ping <other device>` fails → no direct traffic is possible at all.
- **Multicast blocked** (UniFi: *Block LAN to WLAN Multicast and Broadcast
  Data*, or mDNS not reflected across VLANs): `ping` works but
  `dns-sd -B _services._dns-sd._udp` (macOS) lists no other device → mDNS
  can't resolve. Enable *Multicast DNS* / stop blocking multicast on that SSID.
- **VPN or firewall** on one device swallowing multicast or inbound UDP.

The browser console shows the outcome of every attempt
(`rtc receiver session ended: done|timeout|ice-failed (...)`) with the
candidates exchanged, which pinpoints which side failed.

