require 'dlcenter/share'

RSpec.describe DLCenter::Share do
  it "has an uuid" do
    share = DLCenter::Share.new
    expect(share).to respond_to(:uuid)
    expect(share.uuid).to be_instance_of(String)
    expect(share.uuid.length).to eq(36)
  end
  
  it "has a content type" do
    share = DLCenter::Share.new content_type: "text/plain"
    expect(share.content_type).to eq("text/plain")
    share.content_type = "octet/stream"
    expect(share.content_type).to eq("octet/stream")
  end
end
