require 'dlcenter/registry'

describe "My Sinatra Application" do
  let(:registry) { app.settings.registry }
  let(:dctx_dnamespace) { registry.context_for("127.0.0.1").namespace_for(:default) }
  let(:client) { DLCenter::Client.new }

  it "Get an index page" do
    get "/"
    expect(last_response).to be_ok
  end

  it "Has a registry" do
    expect(registry).to be_kind_of(DLCenter::Registry)
  end

  def add_share content
    share = DLCenter::Share.new client
    client.add_share share
    dctx_dnamespace.add_client(client)
    share
  end

  it "test helper method add_share" do
    share = add_share(:foo)
    expect(registry.get_share_by_uuid(share.uuid)).to eq(share)
  end

  it "Download the file" do
    add_share("THE FILE")
    get "/g"
    expect(last_response).to be_ok
    expect(last_response.body).to eq("THE FILE")
  end

  it "Can't download the file" do
    get "/g"
    expect(last_response.ok?).to eq(false)
  end

end
