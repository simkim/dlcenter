require 'base64'

module DLCenter
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
    def flush_io(uuid)
      stream = @streams[uuid]
      begin
        while (data = @io_in.read 1024*1024)
          stream.got_chunk(data)
          stream.drain_buffer
        end
      rescue IOError => e
        puts "Error while flushing #{e}"
      end
      stream.close
      @io_out.close
      @namespace.remove_client(self)
    end
    def send_msg(msg, params={})
      case msg
      when :shares then nil
      when :hello  then nil
      when :stream then flush_io(params[:uuid])
      else
        raise "Invalid msg type #{msg} with params #{params}"
      end
    end
  end

  class WSClient < Client
    def initialize namespace, ws
      super(namespace)
      @ws = ws
      ws.onopen do
        self.send_msg(:hello, text: "Hello World!")
        self.send_msg(:shares, shares: @namespace.get_shares_json)
      end
      ws.onmessage do |tmsg|

        begin
          msg = JSON.parse(tmsg, symbolize_names: true)
        rescue
          puts "Can't parse JSON message"
        end
        self.handle_ws_msg(msg)

      end
      ws.onclose do
        puts "WS closed"
        @namespace.remove_client(self)
      end
    end

    def send_msg(msg, params={})
      case msg
      when :shares then send({type: :shares, shares: params[:shares]}.to_json)
      when :hello  then send({type: :hello, text: params[:text]}.to_json)
      when :stream then send({type: :stream}.merge(params).to_json)
      else
        raise "Invalid msg type #{msg} with params #{params}"
      end
    end

    def send(ws_msg)
      begin
        @ws.send(ws_msg)
      rescue
        puts "Can't send message to #{@ws}"
      end
    end

    def handle_register_share(msg)
      name = msg[:name]
      puts "Websocket #{@ws} share file #{name}"
      share = Share.new(self, msg)
      self.add_share(share)
      @namespace.broadcast_available_shares
      return
    end

    def handle_unregister_share(msg)
      uuid = msg[:uuid]
      self.remove_share_by_uuid(uuid)
      @namespace.broadcast_available_shares
    end

    def handle_chunk(msg)
      uuid = msg[:uuid]
      encoded_chunk = msg[:chunk]
      stream = @streams[uuid]
      if stream
        chunk = Base64.decode64(encoded_chunk)
        # puts "Got chunk of size #{chunk.length} for stream #{uuid}"
        stream.got_chunk(chunk)
        begin
          stream.drain_buffer
          if msg[:close] then
            stream.close
          end
          return true
        rescue IOError
          puts "ERROR: can't send data to client"
        end
      else
        puts "Unknown stream #{uuid}"
      end
      return false
    end

    def handle_ws_msg(msg)
      #puts msg
      case msg[:type]
      when 'register_share' then handle_register_share(msg)
      when 'unregister_share' then handle_unregister_share(msg)
      when 'chunk' then handle_chunk(msg)
      when 'ping' then true
      else puts "Unkown msg : #{msg}"
      end
    end
  end
end
