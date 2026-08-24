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
