module DLCenter
  class Streamer
    # Max buffer size: 10MB - prevents memory exhaustion
    MAX_BUFFER_SIZE = 10 * 1024 * 1024

    attr_reader :share, :buffer, :uuid, :out
    def initialize(share, out)
      @uuid = SecureRandom.uuid
      @share = share
      @out = out
      @buffer = ""
      @closed = false
    end

    def got_chunk(chunk)
      return if @closed
      # Check buffer size limit
      if @buffer.bytesize + chunk.bytesize > MAX_BUFFER_SIZE
        puts "Buffer overflow prevented for stream #{@uuid}"
        close
        raise IOError, "Buffer size exceeded"
      end
      @buffer += chunk
    end

    def drain_buffer
      return if @closed
      buffer = @buffer
      @buffer = ""
      EM.next_tick {
        begin
            @out << buffer
        rescue IOError
            puts "error on out stream"
        end
      }
    end

    def close
      return if @closed
      @closed = true
      EM.next_tick {
        @out.close
      }
    end
  end
end
