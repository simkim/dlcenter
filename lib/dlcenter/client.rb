require 'base64'
require 'ipaddr'

module DLCenter
  # Input validation constants
  MAX_FILENAME_LENGTH = 255
  MAX_CONTENT_TYPE_LENGTH = 256
  MAX_INLINE_CONTENT_LENGTH = 10_000
  MAX_SHARES_PER_CLIENT = 100
  MAX_CHUNK_SIZE = 2 * 1024 * 1024  # 2MB max chunk size
  UUID_FORMAT = /\A[a-f0-9\-]{36}\z/i

  # WebRTC signaling limits
  MAX_RTC_SESSIONS_PER_CLIENT = 8
  MAX_RTC_SDP_LENGTH = 16 * 1024
  MAX_RTC_CANDIDATE_LENGTH = 1024
  MAX_RTC_CANDIDATES_PER_SESSION = 64

  class Client
    attr_reader :shares
    attr_accessor :namespace
    def initialize namespace
      @namespace = namespace
      @shares = {}
      @streams = {}
    end
    def add_share(share)
      @shares[share.uuid] = share
    end
    def remove_share_by_uuid(uuid)
      @shares.delete(uuid)
    end
    def get_shares_json
      @shares.values.map do |share|
        {
          uuid: share.uuid,
          name: share.name,
          content_type: share.content_type,
          content: share.inline_content,
          size: share.size,
          link: share.link?
        }
      end
    end
    def get_share_by_uuid uuid
      @shares[uuid]
    end
    def ask_for_stream(stream)
      @streams[stream.uuid] = stream
      send_msg(:stream, uuid: stream.uuid, share: stream.share.uuid)
      return stream
    end
    def active_streams
      @streams
    end
    # The downloader of `stream` went away: forget the stream and tell the
    # sender to stop pushing data for it.
    def abort_stream(stream)
      return unless @streams.delete(stream.uuid)
      stream.abort
      send_msg(:stream_close, uuid: stream.uuid)
    end
    # The sender is gone: end every download it was feeding.
    def close_streams
      streams = @streams.values
      @streams.clear
      streams.each(&:close)
    end
    def send_msg(msg, options={})
      raise NotImplementedError.new(msg)
    end
  end

  class IOClient < Client
    def initialize namespace, io_in, io_out, options = {}
        super(namespace)
        @io_in = io_in
        @io_out = io_out
        share = Share.new(self, {
          content_type: options[:content_type],
          size: options[:size],
          name: options[:filename],
          oneshot: true
          })
        self.add_share(share)
    end
    # Runs in a worker thread (Sinatra streams are deferred on EventMachine):
    # pace the reads on the downloader actually consuming the data.
    def flush_io(uuid)
      stream = @streams[uuid]
      drained = Queue.new
      begin
        while (data = @io_in.read 1024*1024)
          break if stream.closed?
          stream.got_chunk(data)
          stream.drain_buffer
          stream.when_drained { drained.push(true) }
          drained.pop
        end
      rescue IOError => e
        puts "Error while flushing #{e}"
      end
      stream.close
      @streams.delete(uuid)
      @io_out.close
      @namespace.remove_client(self)
    end
    def send_msg(msg, params={})
      case msg
      when :shares then nil
      when :hello  then nil
      when :stream then flush_io(params[:uuid])
      when :stream_close then nil
      else
        raise "Invalid msg type #{msg} with params #{params}"
      end
    end
  end

  class WSClient < Client
    HEARTBEAT_INTERVAL = 30  # seconds between pings
    HEARTBEAT_TIMEOUT = 30   # seconds to wait for pong (slow uplinks may delay it behind chunks)

    # `on_close` is invoked once when the socket is gone (after the client
    # has been removed from its namespace).
    def initialize namespace, ws, &on_close
      super(namespace)
      @ws = ws
      @on_close = on_close
      @alive = true
      @rtc_sessions = {}
      @heartbeat_timer = nil
      @timeout_timer = nil

      ws.onopen do
        guard("onopen") do
          self.send_msg(:hello, text: "Hello World!")
          self.send_msg(:shares, shares: @namespace.get_shares_json)
          start_heartbeat
        end
      end
      ws.onmessage do |tmsg|
        guard("onmessage") do
          # Any traffic proves the client is alive
          @alive = true
          begin
            msg = JSON.parse(tmsg, symbolize_names: true)
          rescue JSON::ParserError
            puts "Can't parse JSON message"
            next
          end
          self.handle_ws_msg(msg) if msg.is_a?(Hash)
        end
      end
      ws.onclose do
        guard("onclose") do
          puts "WS closed"
          stop_heartbeat
          close_rtc_sessions
          @namespace.remove_client(self)
          @on_close.call if @on_close
        end
      end
    end

    # A raised exception in an EventMachine callback or timer takes the whole
    # server down with it (and every connected user). Never let that happen
    # because of one misbehaving client.
    def guard(context)
      yield
    rescue StandardError => e
      puts "Error in WebSocket #{context}: #{e.class}: #{e.message}"
      puts e.backtrace.first(5).join("\n") if e.backtrace
    end

    def start_heartbeat
      @heartbeat_timer = EM.add_periodic_timer(self.class::HEARTBEAT_INTERVAL) do
        guard("heartbeat") do
          if @alive
            @alive = false
            send({type: :ping}.to_json)
            @timeout_timer = EM.add_timer(self.class::HEARTBEAT_TIMEOUT) do
              guard("heartbeat timeout") do
                unless @alive
                  puts "Heartbeat timeout, closing connection"
                  close_ws
                end
              end
            end
          else
            puts "No pong received, closing connection"
            close_ws
          end
        end
      end
    end

    def stop_heartbeat
      EM.cancel_timer(@heartbeat_timer) if @heartbeat_timer
      EM.cancel_timer(@timeout_timer) if @timeout_timer
      @heartbeat_timer = nil
      @timeout_timer = nil
    end

    def close_ws
      stop_heartbeat
      if @ws.respond_to?(:close_websocket)
        @ws.close_websocket
      elsif @ws.respond_to?(:close)
        @ws.close
      end
    rescue StandardError => e
      puts "Can't close websocket: #{e.message}"
    end

    def send_msg(msg, params={})
      case msg
      when :shares then send({type: :shares, shares: params[:shares]}.to_json)
      when :hello  then send({type: :hello, text: params[:text]}.to_json)
      when :stream then send({type: :stream}.merge(params).to_json)
      when :stream_close then send({type: :stream_close, uuid: params[:uuid]}.to_json)
      when :rtc then send(params.to_json)
      else
        raise "Invalid msg type #{msg} with params #{params}"
      end
    end

    def send(ws_msg)
      begin
        @ws.send(ws_msg)
      rescue StandardError
        puts "Can't send message to #{@ws}"
      end
    end

    def handle_register_share(msg)
      # Validate share count limit
      if @shares.size >= MAX_SHARES_PER_CLIENT
        puts "Client exceeded max shares limit"
        return
      end

      # Validate and sanitize name
      name = msg[:name]
      unless name.is_a?(String) && name.length > 0 && name.length <= MAX_FILENAME_LENGTH
        puts "Invalid share name"
        return
      end
      # Sanitize filename: remove control characters, path separators
      sanitized_name = name.gsub(/[\x00-\x1f\x7f"\\\/\r\n]/, '_').strip

      # Validate content_type
      content_type = msg[:content_type]
      if content_type
        unless content_type.is_a?(String) && content_type.length <= MAX_CONTENT_TYPE_LENGTH &&
               content_type.match?(/\A[\w\-]+\/[\w\-\.\+]+\z/)
          content_type = 'application/octet-stream'
        end
      end

      # Validate size
      size = msg[:size]
      if size && (!size.is_a?(Integer) || size < 0)
        size = nil
      end

      # Validate inline content (for links/text shares)
      inline_content = msg[:content]
      if inline_content
        unless inline_content.is_a?(String) && inline_content.length <= MAX_INLINE_CONTENT_LENGTH
          inline_content = nil
        end
      end

      # Validate client-provided UUID format
      uuid = msg[:uuid]
      if uuid.is_a?(String) && uuid.match?(/\A[a-f0-9\-]{36}\z/i)
        sanitized_uuid = uuid
      else
        sanitized_uuid = nil  # Let Share generate one
      end

      sanitized_msg = {
        uuid: sanitized_uuid,
        name: sanitized_name,
        content_type: content_type,
        size: size,
        content: inline_content,
        oneshot: msg[:oneshot] == true
      }

      share = Share.new(self, sanitized_msg)
      self.add_share(share)
      @namespace.broadcast_available_shares
      return
    end

    def handle_unregister_share(msg)
      uuid = msg[:uuid]
      # Validate UUID format
      unless uuid.is_a?(String) && uuid.match?(/\A[a-f0-9\-]{36}\z/i)
        puts "Invalid UUID format"
        return
      end
      self.remove_share_by_uuid(uuid)
      @namespace.broadcast_available_shares
    end

    def handle_chunk(msg)
      uuid = msg[:uuid]
      # Validate UUID format
      unless uuid.is_a?(String) && uuid.match?(/\A[a-f0-9\-]{36}\z/i)
        puts "Invalid UUID format in chunk"
        return false
      end

      encoded_chunk = msg[:chunk]
      unless encoded_chunk.is_a?(String)
        puts "Invalid chunk data"
        return false
      end

      stream = @streams[uuid]
      unless stream
        puts "Unknown stream #{uuid}"
        return false
      end

      chunk = Base64.decode64(encoded_chunk)
      # Validate chunk size
      if chunk.length > MAX_CHUNK_SIZE
        puts "Chunk too large: #{chunk.length} bytes"
        return false
      end

      begin
        stream.got_chunk(chunk)
        stream.drain_buffer
      rescue IOError
        puts "ERROR: can't send data to client"
        @streams.delete(uuid)
        return false
      end

      if msg[:close]
        stream.close
        @streams.delete(uuid)
      else
        # Flow control: only ask the sender for more once the downloader has
        # actually consumed what we already have.
        stream.when_drained do
          send({type: :ack, uuid: uuid}.to_json) unless stream.closed?
        end
      end
      return true
    end

    # --- WebRTC signaling ---------------------------------------------------
    #
    # Two browsers on the same LAN can transfer directly over a DataChannel
    # instead of relaying through us. The server only routes the handshake:
    # a session can only be opened toward the owner of a share visible in the
    # requester's own namespace (the same authorization as GET /share/:uuid),
    # session ids are minted here, and peers never learn each other's client
    # identity. Only LAN host candidates are relayed (mDNS names or private
    # addresses, no STUN/TURN), so the direct path can only succeed on the
    # actual local network and no public address is disclosed to anybody.

    attr_reader :rtc_sessions

    def valid_uuid?(uuid)
      uuid.is_a?(String) && uuid.match?(UUID_FORMAT)
    end

    def valid_rtc_sdp?(sdp)
      sdp.is_a?(String) && !sdp.empty? && sdp.length <= MAX_RTC_SDP_LENGTH
    end

    PRIVATE_RANGES = %w[10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 fc00::/7 fe80::/10]
      .map { |cidr| IPAddr.new(cidr) }.freeze

    # A host candidate that can only be reached from the local network: an
    # mDNS name (Chrome, Safari) or a private / link-local address (Firefox
    # doesn't obfuscate host candidates by default). Never a public address,
    # never a server-reflexive or relay candidate.
    def lan_address?(address)
      return true if address.match?(/\.local\z/i)
      ip = IPAddr.new(address)
      PRIVATE_RANGES.any? { |range| range.include?(ip) }
    rescue IPAddr::Error, ArgumentError
      false
    end

    # "candidate:<foundation> <component> <proto> <priority> <address> <port> typ <type> ..."
    # An empty candidate string is the end-of-candidates marker.
    def lan_candidate?(candidate)
      return true if candidate.empty?
      fields = candidate.split(' ')
      fields[6] == 'typ' && fields[7] == 'host' && lan_address?(fields[4].to_s)
    end

    # Drops any candidate line that is not a LAN host candidate, so that a
    # modified client can't advertise a routable address through us.
    def scrub_rtc_sdp(sdp)
      sdp.each_line.reject do |line|
        line.start_with?('a=candidate:') && !lan_candidate?(line.chomp.delete_prefix('a='))
      end.join
    end

    def rtc_open_session(session, peer)
      @rtc_sessions[session] = { peer: peer, candidates: 0 }
    end

    def handle_rtc_offer(msg)
      share_uuid = msg[:share]
      return puts("Invalid RTC offer") unless valid_uuid?(share_uuid) && valid_rtc_sdp?(msg[:sdp])
      return puts("Too many RTC sessions") if @rtc_sessions.size >= MAX_RTC_SESSIONS_PER_CLIENT
      share = @namespace.get_share_by_uuid(share_uuid)
      owner = share&.client
      # IOClient (curl uploads) has no browser to answer, and downloading
      # one's own share directly makes no sense: both stay on the relay.
      return puts("No RTC peer for share #{share_uuid}") unless owner.is_a?(WSClient) && owner != self
      return puts("Peer has too many RTC sessions") if owner.rtc_sessions.size >= MAX_RTC_SESSIONS_PER_CLIENT

      session = SecureRandom.uuid
      rtc_open_session(session, owner)
      owner.rtc_open_session(session, self)
      send_msg(:rtc, type: :rtc_session, session: session, share: share_uuid)
      owner.send_msg(:rtc, type: :rtc_offer, session: session, share: share_uuid, sdp: scrub_rtc_sdp(msg[:sdp]))
    end

    def handle_rtc_answer(msg)
      state = @rtc_sessions[msg[:session]]
      return unless state && valid_rtc_sdp?(msg[:sdp])
      state[:peer].send_msg(:rtc, type: :rtc_answer, session: msg[:session], sdp: scrub_rtc_sdp(msg[:sdp]))
    end

    def handle_rtc_ice(msg)
      state = @rtc_sessions[msg[:session]]
      return unless state
      candidate = msg[:candidate]
      return puts("Invalid ICE candidate") unless candidate.is_a?(Hash)
      candidate_str = candidate[:candidate]
      return puts("Invalid ICE candidate") unless candidate_str.is_a?(String) && candidate_str.length <= MAX_RTC_CANDIDATE_LENGTH
      return puts("Dropping non-LAN ICE candidate") unless lan_candidate?(candidate_str)
      state[:candidates] += 1
      return puts("Too many ICE candidates") if state[:candidates] > MAX_RTC_CANDIDATES_PER_SESSION

      # Rebuild the candidate from whitelisted fields only.
      forwarded = { candidate: candidate_str }
      forwarded[:sdpMid] = candidate[:sdpMid][0, 64] if candidate[:sdpMid].is_a?(String)
      forwarded[:sdpMLineIndex] = candidate[:sdpMLineIndex] if candidate[:sdpMLineIndex].is_a?(Integer)
      forwarded[:usernameFragment] = candidate[:usernameFragment][0, 256] if candidate[:usernameFragment].is_a?(String)
      state[:peer].send_msg(:rtc, type: :rtc_ice, session: msg[:session], candidate: forwarded)
    end

    def handle_rtc_close(msg)
      session = msg[:session]
      state = @rtc_sessions.delete(session)
      return unless state
      # The reason ends up in the logs: keep it to a harmless token.
      reason = msg[:reason].is_a?(String) ? msg[:reason].gsub(/[^\w\-]/, '')[0, 32] : 'unknown'
      # Instrumentation: how often does the direct path actually work?
      puts "RTC session #{session} closed: #{reason}"
      state[:peer].rtc_peer_closed(session)
    end

    def rtc_peer_closed(session)
      return unless @rtc_sessions.delete(session)
      send_msg(:rtc, type: :rtc_close, session: session)
    end

    def close_rtc_sessions
      sessions = @rtc_sessions
      @rtc_sessions = {}
      sessions.each { |session, state| state[:peer].rtc_peer_closed(session) }
    end

    def handle_ws_msg(msg)
      #puts msg
      case msg[:type]
      when 'register_share' then handle_register_share(msg)
      when 'unregister_share' then handle_unregister_share(msg)
      when 'chunk' then handle_chunk(msg)
      when 'ping' then send({type: :pong}.to_json)
      when 'pong' then nil # liveness already recorded in onmessage
      when 'rtc_offer' then handle_rtc_offer(msg)
      when 'rtc_answer' then handle_rtc_answer(msg)
      when 'rtc_ice' then handle_rtc_ice(msg)
      when 'rtc_close' then handle_rtc_close(msg)
      else puts "Unkown msg : #{msg}"
      end
    end
  end
end
