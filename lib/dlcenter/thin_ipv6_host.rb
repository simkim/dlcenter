require 'thin'

module DLCenter
  # Thin's C parser splits the Host header on the first ':' to fill
  # SERVER_NAME / SERVER_PORT, which mangles bracketed IPv6 hosts
  # ("[::1]:8080" becomes name "[" and port ":1]:8080"). Rack::Lint (enabled
  # by rackup in development) then rejects the request with a 500.
  module ThinIPv6Host
    IPV6_HOST = /\A(\[[^\]]+\])(?::(\d+))?\z/

    def parse(data)
      result = super
      host = @env['HTTP_HOST']
      if host && host.start_with?('[') && (m = IPV6_HOST.match(host))
        @env['SERVER_NAME'] = m[1]
        @env['SERVER_PORT'] = m[2] || (@env['HTTPS'] == 'on' ? '443' : '80')
      end
      result
    end
  end
end

Thin::Request.prepend(DLCenter::ThinIPv6Host)
