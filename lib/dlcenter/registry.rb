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

    def shares
      @clients.flat_map { |client| client.shares }
    end

    def get_share_by_uuid uuid
      @clients.each do |client|
        share = client.get_share_by_uuid(uuid)
        return share if share
      end
    end

  end

  class SecurityContext
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
      @security_contexts = {}
    end
    def context_for(security_token)
      @security_contexts[security_token] ||= SecurityContext.new(security_token)
    end
  end
end
