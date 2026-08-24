require 'ffaker'

describe "My Sinatra Application" do
  let(:registry) { app.settings.registry.tap { |registry| registry.reset } }
  let(:dctx_dnamespace) { registry.context_for("127.0.0.1").namespace_for(:default) }
  let(:client) {
    DLCenter::Client.new(dctx_dnamespace)
      .tap { |client| dctx_dnamespace.add_client(client) }
  }
  let(:share) { DLCenter::Share.new(client, name: FFaker::Lorem.word).tap {|share| client.add_share share } }
  let(:fake_content) { FFaker::Lorem.sentence }

  it "Get an index page" do
    get "/"
    expect(last_response).to be_ok
  end

  it "Has a registry" do
    expect(registry).to be_kind_of(DLCenter::Registry)
  end

  it "client let is registred in registry" do
    expect(registry.get_share_by_uuid(share.uuid)).to eq(share)
  end

  it "Download the file" do
    skip("test doesn't work, async ?")
    share
    test = self
    client.define_singleton_method(:send_msg) do |msg, options={}|
        test.expect(@streams.length).to test.eq(1)
        stream = @streams.values.first
        stream.got_chunk(test.fake_content)
        stream.drain_buffer
        stream.close
    end
    expect(registry.share_count).to eq(1)
    get "/g"
    expect(last_response).to be_ok
    expect(last_response.body).to eq(fake_content)
  end

  it "Can't download if no file" do
    registry
    get "/g"
    expect(last_response.ok?).to eq(false)
  end

end

describe "WebSocket endpoint" do
  let(:counts) { app.settings.connection_counts }
  before { counts.clear }

  def ws_headers(connection: 'Upgrade')
    {
      'HTTP_CONNECTION' => connection,
      'HTTP_UPGRADE' => 'websocket',
      'HTTP_SEC_WEBSOCKET_KEY' => 'dGhlIHNhbXBsZSBub25jZQ==',
      'HTTP_SEC_WEBSOCKET_VERSION' => '13'
    }
  end

  it "rejects non-websocket requests without leaking a connection slot" do
    get "/ws"
    expect(last_response.status).to eq(400)
    expect(counts).to be_empty
  end

  it "releases the connection slot when the handshake fails" do
    # Outside Thin there is no async callback: the handshake raises (like
    # em-websocket's HandshakeError does) after the slot was taken.
    60.times { get "/ws", {}, ws_headers(connection: 'upgrade') }
    expect(last_response.status).to eq(400)
    expect(counts).to be_empty
    get "/ws", {}, ws_headers
    expect(last_response.status).not_to eq(429)
  end

  it "normalizes a lowercase Connection header before the handshake" do
    seen = nil
    SinatraWebsocket::Connection.stubs(:from_env).with { |env, *| seen = env['HTTP_CONNECTION']; true }
      .returns([400, {}, ['stubbed']])
    get "/ws", {}, ws_headers(connection: 'keep-alive, upgrade')
    expect(seen).to eq('Upgrade')
  end

  it "still enforces the per-IP limit for live connections" do
    counts['127.0.0.1'] = app.settings.max_connections_per_ip
    get "/ws", {}, ws_headers
    expect(last_response.status).to eq(429)
  end
end

describe "Downloads" do
  let(:registry) { app.settings.registry.tap { |registry| registry.reset } }
  let(:namespace) { registry.context_for("127.0.0.1").namespace_for(:default) }
  let(:client) { DLCenter::Client.new(namespace).tap { |c| namespace.add_client(c) } }
  let(:share) { DLCenter::Share.new(client, name: 'a"b/c.txt', size: 5, content_type: 'text/plain').tap { |s| client.add_share(s) } }

  before do
    # Complete the stream synchronously so the (non-EM) test scheduler finishes.
    client.define_singleton_method(:send_msg) do |msg, params = {}|
      next unless msg == :stream
      stream = @streams[params[:uuid]]
      stream.got_chunk("hello")
      stream.drain_buffer
      stream.close
    end
    EM.stubs(:next_tick).yields
  end

  it "serves a share with headers that disable proxy buffering" do
    get "/share/#{share.uuid}"
    expect(last_response).to be_ok
    expect(last_response.headers['X-Accel-Buffering']).to eq('no')
    expect(last_response.headers['Content-Length']).to eq('5')
    expect(last_response.headers['Content-Disposition']).to eq('attachment; filename="a_b_c.txt"')
    expect(last_response.body).to eq("hello")
  end

  it "returns 404 for an unknown share" do
    get "/share/#{SecureRandom.uuid}"
    expect(last_response.status).to eq(404)
  end

  # The client IP is the whole authorization model (namespaces are keyed by
  # it), so pin down how Rack resolves it behind the nginx-proxy container.
  describe "client IP resolution" do
    let(:namespace) { registry.context_for("198.51.100.7").namespace_for(:default) }

    it "uses X-Forwarded-For when the request comes through the proxy" do
      share
      get "/g", {}, 'REMOTE_ADDR' => '172.18.0.2', 'HTTP_X_FORWARDED_FOR' => '198.51.100.7'
      expect(last_response).to be_ok
      expect(last_response.body).to eq("hello")
    end

    it "ignores X-Forwarded-For sent directly by a public address" do
      share
      get "/g", {}, 'REMOTE_ADDR' => '203.0.113.5', 'HTTP_X_FORWARDED_FOR' => '198.51.100.7'
      expect(last_response.status).to eq(404)
    end

    it "keeps the last untrusted hop when several proxies are chained" do
      share
      get "/g", {}, 'REMOTE_ADDR' => '172.18.0.2', 'HTTP_X_FORWARDED_FOR' => '10.0.0.9, 198.51.100.7, 172.18.0.3'
      expect(last_response).to be_ok
    end
  end
end
