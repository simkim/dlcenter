module DLCenter
  class Client
    attr_reader :shares
    def initialize
      @shares = {}
    end
    def add_share(share)
      @shares[share.uuid] = share
    end
    def get_share_by_uuid uuid
      @shares[uuid]
    end
  end
end
