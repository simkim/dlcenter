module DLCenter
  class Streamer
    attr_reader :share, :buffer, :uuid, :out
    def initialize(share, out)
      @uuid = SecureRandom.uuid
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
