module DLCenter
  class Namespace
    def initialize(namespace_token)
      @namespace_token = namespace_token
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
