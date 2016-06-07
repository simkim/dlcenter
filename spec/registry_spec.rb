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
