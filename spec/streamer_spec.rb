require 'stringio'
require 'dlcenter/streamer'

RSpec.describe DLCenter::Streamer do
  let(:client) { DLCenter::Client.new nil }
  let(:share) { DLCenter::Share.new client, name: FFaker::Lorem.word }
  let(:output) { StringIO.new }
  let(:streamer) { DLCenter::Streamer.new share, output}

  it "has an uuid" do
    expect(share).to respond_to(:uuid)
    expect(share.uuid).to be_instance_of(String)
    expect(share.uuid.length).to eq(36)
  end

  it "has a share" do
    expect(streamer).to respond_to(:share)
  end

  it "can receive a chunk of data in his buffer" do
    expect(streamer).to respond_to(:got_chunk)

    chunk = "abc"
    streamer.got_chunk(chunk)

    expect(streamer).to respond_to(:buffer)
    expect(streamer.buffer.length).to eq(chunk.length)
  end

end
