module DLCenter
  class Streamer
    attr_accessor :share, :buffer
    def initialize(share, out)
      @share = share
      @out = out
      @buffer = ""
    end
    def got_chunk(chunk)
      @buffer += chunk
    end
    def drain_buffer
      @out << @buffer
      @buffer = ""
    end
    def close
      @out.close
    end
  end
end
