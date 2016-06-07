module DLCenter
  class Streamer
    attr_accessor :share, :buffer
    def initialize(share)
      @share = share
      @buffer = ""
    end
    def got_chunk(chunk)
      @buffer += chunk
    end
  end
end
