require 'dlcenter/registry'

RSpec.describe DLCenter::Registry do
  it "cache security context" do
    registry = DLCenter::Registry.new

    context = registry.context_for("192.168.1.1")
    context2 = registry.context_for("192.168.1.1")

    expect(context).to eq(context2)
  end
end

RSpec.describe DLCenter::SecurityContext do
  it "cache namespace" do
    registry = DLCenter::Registry.new
    context = registry.context_for(:test)

    ns1 = context.namespace_for(:test)
    ns2 = context.namespace_for(:test)

    expect(ns1).to eq(ns2)
  end
end

RSpec.describe DLCenter::Namespace do
  let(:namespace) { DLCenter::Namespace.new :ns1 }
  let(:client) { DLCenter::Client.new }
  let(:share) { DLCenter::Share.new client}

  it "has a list of clients" do
    expect(namespace).to respond_to(:clients)
    expect(namespace.clients.length).to eq(0)
  end

  it "can reference a client" do
    expect(namespace).to respond_to(:add_client)
    namespace.add_client(client)
    expect(namespace.clients.length).to eq(1)
  end

  it "has an empty list of shares" do
    expect(namespace).to respond_to(:shares)
    expect(namespace.shares.length).to be(0)
  end

  it "can give a client share" do
    client.add_share(share)
    namespace.add_client(client)

    expect(namespace.shares.length).to eq(1)
  end

  it "can retrieve the shares by uuid" do
    uuid = share.uuid
    
    client.add_share(share)
    namespace.add_client(client)

    expect(namespace.get_share_by_uuid(uuid)).to eq(share)
  end
end
