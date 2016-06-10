require 'ffaker'

describe "My Sinatra Application" do
  let(:registry) { app.settings.registry.tap { |registry| registry.reset } }
  let(:dctx_dnamespace) { registry.context_for("127.0.0.1").namespace_for(:default) }
  let(:client) {
    DLCenter::Client.new
      .tap { |client| dctx_dnamespace.add_client(client) }
  }
  let(:share) { DLCenter::Share.new(client).tap {|share| client.add_share share } }
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
    share
    test = self
    client.define_singleton_method(:send_msg) do |msg, options={}|
        test.expect(@streams.length).to test.eq(1)
        out = @streams.values[0].out
        out << test.fake_content
        out.close
    end
    expect(registry.share_count).to eq(1)
    get "/g"
    expect(last_response).to be_ok
    expect(last_response.body).to eq(fake_content)
  end

  it "Can't download if no file" do
    registry
    get "/g"
    puts last_response.body
    expect(last_response.ok?).to eq(false)
  end

end
