module DLCenter
  class Namespace
    attr_reader :clients
    def initialize(namespace_token)
      @namespace_token = namespace_token
      @clients = []
    end

    def add_client(client)
      @clients.push client
    end

    def remove_client(client)
      @clients.delete client
      broadcast_available_shares
    end

    def shares
      @clients.flat_map { |client| client.shares.values }
    end

    def get_shares_json
      shares.map do |share|
        {
          uuid: share.uuid,
          name: share.name,
          size: share.size,
          oneshot: share.oneshot,
          content_type: share.content_type
        }
      end
    end

    def get_share_by_uuid uuid
      @clients.each do |client|
        share = client.get_share_by_uuid(uuid)
        return share if share
      end
      return nil
    end
    def broadcast_available_shares
      shares = get_shares_json
      @clients.each do |client|
        client.send_msg(:shares, shares: shares)
      end
    end
  end

  class SecurityContext
    attr_reader :namespaces
    def initialize(security_token)
      @security_token = security_token
      @namespaces = {}
    end
    def namespace_for(namespace_token)
      @namespaces[namespace_token] ||= Namespace.new(namespace_token)
    end
  end

  class Registry
    def initialize
      reset
    end
    def reset
      @security_contexts = {}
    end
    def context_for(security_token)
      @security_contexts[security_token] ||= SecurityContext.new(security_token)
    end
    def each_namespace
      @security_contexts.each_value do |security_context|
        security_context.namespaces.each_value do |namespace|
          yield namespace
        end
      end
    end
    # def each_share
    #   each_namespace do |namespace|
    #     namespace.shares.each do |share|
    #       yield share
    #     end
    #   end
    # end
    def share_count
      count = 0
      each_namespace do |namespace|
        count += namespace.shares.length
      end
      count
    end
    # def to_s
    #   "Registry (#{share_count} shares)"
    # end
    def get_share_by_uuid(uuid)
      # TODO: create a weak cache for retrieving in O(1) the share
      each_namespace do |namespace|
        share = namespace.get_share_by_uuid(uuid)
        return share if share
      end
      return nil
    end
  end
end
