require 'json'
require 'dlcenter'

# Minimal stand-in for SinatraWebsocket::Connection (em-websocket 0.3.x API):
# single-slot callbacks, `send`, and `close_websocket` (there is no `close`).
class FakeWS
  attr_reader :sent, :closed
  def initialize
    @sent = []
    @closed = false
  end
  def onopen(&blk);    @onopen = blk;    end
  def onmessage(&blk); @onmessage = blk; end
  def onclose(&blk);   @onclose = blk;   end
  def send(msg);       @sent << JSON.parse(msg, symbolize_names: true); end
  def close_websocket(*) @closed = true; end
  def open;            @onopen.call;     end
  def message(msg);    @onmessage.call(msg.is_a?(String) ? msg : msg.to_json); end
  def close;           @onclose.call;    end
end

class FastHeartbeatClient < DLCenter::WSClient
  HEARTBEAT_INTERVAL = 0.05
  HEARTBEAT_TIMEOUT = 0.05
end

class FakeConnection
  attr_accessor :outbound
  def initialize(outbound = 0) @outbound = outbound end
  def get_outbound_data_size; @outbound; end
end

RSpec.describe DLCenter::WSClient do
  let(:namespace) { DLCenter::Namespace.new(:default) }
  let(:ws) { FakeWS.new }
  let(:closed_calls) { [] }
  let(:client) { DLCenter::WSClient.new(namespace, ws) { closed_calls << :closed } }
  let(:uuid) { SecureRandom.uuid }

  before { namespace.add_client(client) }

  def em(timeout: 2)
    EM.run do
      EM.add_timer(timeout) { EM.stop }
      yield
    end
  end

  it "removes itself from the namespace and reports the close" do
    ws.close
    expect(namespace.clients).not_to include(client)
    expect(closed_calls).to eq([:closed])
  end

  it "closes the downloads it was feeding when it disconnects" do
    share = DLCenter::Share.new(client, name: "file", size: 3)
    client.add_share(share)
    out = StringIO.new
    stream = nil
    em do
      stream = share.content(out)
      ws.close
      EM.next_tick { EM.stop }
    end
    expect(stream).to be_closed
    expect(out).to be_closed
  end

  it "closes the socket with close_websocket when the heartbeat times out" do
    client = FastHeartbeatClient.new(namespace, ws)
    em do
      ws.open
      EM.add_timer(0.5) { EM.stop }
    end
    expect(ws.sent.map { |m| m[:type] }).to include(:ping.to_s)
    expect(ws.closed).to eq(true)
  end

  it "keeps the connection when the client answers pings" do
    client = FastHeartbeatClient.new(namespace, ws)
    em do
      ws.open
      EM.add_periodic_timer(0.02) { ws.message(type: 'pong') }
      EM.add_timer(0.4) { EM.stop }
    end
    expect(ws.closed).to eq(false)
    client.stop_heartbeat
  end

  it "does not crash the reactor when a message handler raises" do
    client.stubs(:handle_register_share).raises(RuntimeError, "boom")
    expect { ws.message(type: 'register_share', name: 'x') }.not_to raise_error
  end

  describe "streaming with flow control" do
    let(:share) { DLCenter::Share.new(client, name: "file", size: 6) }
    let(:out) { StringIO.new }

    before { client.add_share(share) }

    def chunk_msg(stream_uuid, data, close: false)
      { type: 'chunk', uuid: stream_uuid, chunk: Base64.strict_encode64(data), close: close }
    end

    it "asks the sender for a stream and acks chunks once drained" do
      stream = nil
      em do
        stream = share.content(out)
        ws.message(chunk_msg(stream.uuid, "abc"))
        EM.add_timer(0.1) { EM.stop }
      end
      stream_msg = ws.sent.find { |m| m[:type] == 'stream' }
      expect(stream_msg).to include(uuid: stream.uuid, share: share.uuid)
      expect(ws.sent).to include(type: 'ack', uuid: stream.uuid)
      expect(out.string).to eq("abc")
    end

    it "withholds the ack while the downloader's socket is backed up" do
      connection = FakeConnection.new(DLCenter::Streamer::HIGH_WATER * 2)
      stream = nil
      em do
        stream = share.content(out, connection: connection)
        ws.message(chunk_msg(stream.uuid, "abc"))
        EM.add_timer(0.2) do
          expect(ws.sent).not_to include(type: 'ack', uuid: stream.uuid)
          connection.outbound = 0
        end
        EM.add_timer(0.4) { EM.stop }
      end
      expect(ws.sent).to include(type: 'ack', uuid: stream.uuid)
    end

    it "closes the download on the final chunk" do
      stream = nil
      em do
        stream = share.content(out)
        ws.message(chunk_msg(stream.uuid, "abc"))
        ws.message(chunk_msg(stream.uuid, "def", close: true))
        EM.add_timer(0.1) { EM.stop }
      end
      expect(out.string).to eq("abcdef")
      expect(out).to be_closed
      expect(client.active_streams).to be_empty
    end

    it "tells the sender to stop when the downloader disconnects" do
      closer = EM::DefaultDeferrable.new
      stream = nil
      em do
        stream = share.content(out, closer: closer)
        closer.succeed
        EM.next_tick { EM.stop }
      end
      expect(ws.sent).to include(type: 'stream_close', uuid: stream.uuid)
      expect(stream).to be_closed
      expect(client.active_streams).to be_empty
    end
  end
end

RSpec.describe DLCenter::WSClient, "WebRTC signaling" do
  let(:namespace) { DLCenter::Namespace.new(:default) }
  let(:sender_ws) { FakeWS.new }
  let(:receiver_ws) { FakeWS.new }
  let(:sender) { DLCenter::WSClient.new(namespace, sender_ws) }
  let(:receiver) { DLCenter::WSClient.new(namespace, receiver_ws) }
  let(:share) { DLCenter::Share.new(sender, name: "file", size: 3) }
  let(:mdns) { "candidate:1 1 udp 2113937151 3f0a1c9e-2b7d-4f5a-9c1e-8a2b3c4d5e6f.local 54321 typ host generation 0" }
  let(:private_ip) { "candidate:2 1 udp 2113937151 192.168.1.10 54321 typ host generation 0" }
  let(:link_local_v6) { "candidate:4 1 udp 2113937151 fe80::1c2a:3b4c:5d6e:7f80 54321 typ host generation 0" }
  let(:public_ip) { "candidate:5 1 udp 2113937151 203.0.113.5 54321 typ host generation 0" }
  let(:srflx) { "candidate:3 1 udp 1677729535 192.168.1.10 54321 typ srflx raddr 0.0.0.0 rport 0" }

  before do
    namespace.add_client(sender)
    namespace.add_client(receiver)
    sender.add_share(share)
  end

  def offer!
    receiver_ws.message(type: 'rtc_offer', share: share.uuid, sdp: "v=0\r\n")
    receiver_ws.sent.find { |m| m[:type] == 'rtc_session' }
  end

  it "opens a session toward the share owner without exposing client identities" do
    session = offer!
    expect(session).to include(share: share.uuid)
    offer = sender_ws.sent.find { |m| m[:type] == 'rtc_offer' }
    expect(offer).to eq(type: 'rtc_offer', session: session[:session], share: share.uuid, sdp: "v=0\r\n")
    expect(sender.rtc_sessions.keys).to eq([session[:session]])
    expect(receiver.rtc_sessions.keys).to eq([session[:session]])
  end

  it "relays the answer and mDNS candidates by session" do
    session = offer![:session]
    sender_ws.message(type: 'rtc_answer', session: session, sdp: "v=0\r\nanswer")
    sender_ws.message(type: 'rtc_ice', session: session,
                      candidate: { candidate: mdns, sdpMid: '0', sdpMLineIndex: 0, extra: 'dropped' })
    receiver_ws.message(type: 'rtc_ice', session: session, candidate: { candidate: '' })
    expect(receiver_ws.sent).to include(type: 'rtc_answer', session: session, sdp: "v=0\r\nanswer")
    expect(receiver_ws.sent).to include(type: 'rtc_ice', session: session,
                                        candidate: { candidate: mdns, sdpMid: '0', sdpMLineIndex: 0 })
    expect(sender_ws.sent).to include(type: 'rtc_ice', session: session, candidate: { candidate: '' })
  end

  it "relays private and link-local host candidates (Firefox doesn't use mDNS)" do
    session = offer![:session]
    sender_ws.message(type: 'rtc_ice', session: session, candidate: { candidate: private_ip })
    sender_ws.message(type: 'rtc_ice', session: session, candidate: { candidate: link_local_v6 })
    relayed = receiver_ws.sent.select { |m| m[:type] == 'rtc_ice' }.map { |m| m[:candidate][:candidate] }
    expect(relayed).to eq([private_ip, link_local_v6])
  end

  it "drops public, server-reflexive and malformed candidates" do
    session = offer![:session]
    sender_ws.message(type: 'rtc_ice', session: session, candidate: { candidate: public_ip })
    sender_ws.message(type: 'rtc_ice', session: session, candidate: { candidate: srflx })
    sender_ws.message(type: 'rtc_ice', session: session, candidate: { candidate: "candidate:1 1 udp 1 not-an-ip 1 typ host" })
    sender_ws.message(type: 'rtc_ice', session: session, candidate: { candidate: "garbage" })
    expect(receiver_ws.sent.select { |m| m[:type] == 'rtc_ice' }).to be_empty
  end

  it "scrubs non-LAN candidate lines embedded in the SDP" do
    receiver_ws.message(type: 'rtc_offer', share: share.uuid,
                        sdp: "v=0\r\na=#{public_ip}\r\na=#{srflx}\r\na=#{mdns}\r\na=#{private_ip}\r\na=end-of-candidates\r\n")
    offer = sender_ws.sent.find { |m| m[:type] == 'rtc_offer' }
    expect(offer[:sdp]).to eq("v=0\r\na=#{mdns}\r\na=#{private_ip}\r\na=end-of-candidates\r\n")
  end

  it "refuses to signal toward a share from another namespace" do
    other = DLCenter::Namespace.new(:other)
    stranger_ws = FakeWS.new
    stranger = DLCenter::WSClient.new(other, stranger_ws)
    other.add_client(stranger)
    stranger_ws.message(type: 'rtc_offer', share: share.uuid, sdp: "v=0\r\n")
    expect(stranger_ws.sent.map { |m| m[:type] }).not_to include('rtc_session')
    expect(sender_ws.sent.map { |m| m[:type] }).not_to include('rtc_offer')
    expect(sender.rtc_sessions).to be_empty
  end

  it "refuses to open a session toward oneself or a non-browser sender" do
    sender_ws.message(type: 'rtc_offer', share: share.uuid, sdp: "v=0\r\n")
    io_client = DLCenter::IOClient.new(namespace, StringIO.new, StringIO.new, filename: 'curl.bin')
    namespace.add_client(io_client)
    receiver_ws.message(type: 'rtc_offer', share: io_client.shares.keys.first, sdp: "v=0\r\n")
    expect(sender_ws.sent.map { |m| m[:type] }).not_to include('rtc_session', 'rtc_offer')
    expect(receiver_ws.sent.map { |m| m[:type] }).not_to include('rtc_session')
  end

  it "ignores signaling for an unknown session" do
    stranger_ws = FakeWS.new
    stranger = DLCenter::WSClient.new(namespace, stranger_ws)
    namespace.add_client(stranger)
    session = offer![:session]
    stranger_ws.message(type: 'rtc_answer', session: session, sdp: "v=0\r\n")
    stranger_ws.message(type: 'rtc_ice', session: session, candidate: { candidate: mdns })
    expect(receiver_ws.sent.map { |m| m[:type] }).not_to include('rtc_answer', 'rtc_ice')
  end

  it "rejects oversized SDP" do
    receiver_ws.message(type: 'rtc_offer', share: share.uuid, sdp: "a" * (DLCenter::MAX_RTC_SDP_LENGTH + 1))
    expect(receiver_ws.sent.map { |m| m[:type] }).not_to include('rtc_session')
  end

  it "caps the number of concurrent sessions per client" do
    DLCenter::MAX_RTC_SESSIONS_PER_CLIENT.times { offer! }
    expect(receiver.rtc_sessions.size).to eq(DLCenter::MAX_RTC_SESSIONS_PER_CLIENT)
    receiver_ws.sent.clear
    expect(offer!).to be_nil
  end

  it "closes the session on both sides and tells the peer" do
    session = offer![:session]
    receiver_ws.message(type: 'rtc_close', session: session, reason: 'done')
    expect(sender_ws.sent).to include(type: 'rtc_close', session: session)
    expect(sender.rtc_sessions).to be_empty
    expect(receiver.rtc_sessions).to be_empty
    # Nothing echoes back to the side that closed
    expect(receiver_ws.sent.map { |m| m[:type] }).not_to include('rtc_close')
  end

  it "tells peers when a client disconnects mid-handshake" do
    session = offer![:session]
    sender_ws.close
    expect(receiver_ws.sent).to include(type: 'rtc_close', session: session)
    expect(receiver.rtc_sessions).to be_empty
  end
end
