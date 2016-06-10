module DLCenter
  class Client
    attr_reader :shares
    def initialize
      @shares = {}
      @streams = {}
    end
    def add_share(share)
      @shares[share.uuid] = share
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
      raise NotImplementedError
    end
  end

  class WSClient < Client
  end
end
