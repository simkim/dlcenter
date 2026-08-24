module DLCenter
  # A Streamer pipes chunks received from a sender (WebSocket or IO client)
  # to a downloader's HTTP response body (`out`).
  #
  # Flow control: when constructed with the EventMachine `connection` of the
  # downloader, `when_drained` only fires once the connection's outbound
  # buffer is below HIGH_WATER. Senders use it to pace themselves so the
  # server never buffers more than a small window of a large file in memory.
  class Streamer
    # Max buffer size: 10MB - prevents memory exhaustion
    MAX_BUFFER_SIZE = 10 * 1024 * 1024
    # Outbound bytes queued on the downloader socket above which senders are paused
    HIGH_WATER = 4 * 1024 * 1024
    # How often to re-check the outbound buffer while paused (seconds)
    POLL_INTERVAL = 0.05

    attr_reader :share, :buffer, :uuid, :out
    def initialize(share, out, connection: nil)
      @uuid = SecureRandom.uuid
      @share = share
      @out = out
      @connection = connection
      @buffer = ""
      @closed = false
    end

    def closed?
      @closed
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

    # Bytes handed to the downloader socket but not yet written to the network.
    def pending_bytes
      return 0 unless @connection.respond_to?(:get_outbound_data_size)
      @connection.get_outbound_data_size
    rescue StandardError
      0
    end

    def drained?
      pending_bytes < HIGH_WATER
    end

    # Yields once everything scheduled so far has been flushed far enough
    # down the downloader socket (or once the stream is closed, so callers
    # waiting on it never hang). Safe to call from any thread.
    def when_drained(&blk)
      EM.next_tick { wait_drained(&blk) }
    end

    # Normal end of stream: flush and close the downloader response.
    def close
      return if @closed
      @closed = true
      EM.next_tick {
        @out.close
      }
    end

    # Downloader went away: stop accepting data, nothing more to write.
    def abort
      @closed = true
      @buffer = ""
    end

    private

    def wait_drained(&blk)
      if @closed || drained?
        blk.call
      else
        EM.add_timer(POLL_INTERVAL) { wait_drained(&blk) }
      end
    end
  end
end
