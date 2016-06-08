require 'stringio'
require 'dlcenter/streamer'

RSpec.describe DLCenter::Streamer do
  let(:client) { DLCenter::Client.new }
  let(:share) { DLCenter::Share.new client }
  let(:output) { StringIO.new }
  let(:streamer) { DLCenter::Streamer.new share, output}

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
