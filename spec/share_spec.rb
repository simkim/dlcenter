require 'dlcenter/share'
require 'dlcenter/client'

RSpec.describe DLCenter::Share do
  let(:client) { DLCenter::Client.new }

  it "has an uuid" do
    share = DLCenter::Share.new client
    expect(share).to respond_to(:uuid)
    expect(share.uuid).to be_instance_of(String)
    expect(share.uuid.length).to eq(36)
  end

  it "has a content type" do
    share = DLCenter::Share.new client, content_type: "text/plain"
    expect(share.content_type).to eq("text/plain")
    share.content_type = "octet/stream"
    expect(share.content_type).to eq("octet/stream")
  end

  it "has a name" do
    share = DLCenter::Share.new client, name: "foo"
    expect(share.name).to eq("foo")
    share.name = "bar"
    expect(share.name).to eq("bar")
  end

  it "has a size" do
    share = DLCenter::Share.new client, size: 1234
    expect(share.size).to eq(1234)
    share.size = "4444"
    expect(share.size).to eq(4444)
  end

  it "has a client" do
    share = DLCenter::Share.new client
    expect(share).to respond_to(:client)
  end
end