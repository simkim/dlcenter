require 'sinatra'
require 'sinatra-websocket'
require 'sinatra/streaming'
require 'securerandom'
require 'json'
require 'dlcenter'

module DLCenter
  class App < Sinatra::Base
    helpers Sinatra::Streaming
    set :server, 'thin'
    set :static, true
    set :registry, DLCenter::Registry.new

    # Rate limiting: max connections per IP
    set :max_connections_per_ip, Integer(ENV.fetch('DLCENTER_MAX_CONNECTIONS_PER_IP', 50))
    set :connection_counts, Hash.new(0)

    # Security headers
    before do
      headers \
        'X-Content-Type-Options' => 'nosniff',
        'X-Frame-Options' => 'DENY',
        'X-XSS-Protection' => '1; mode=block',
        'Referrer-Policy' => 'strict-origin-when-cross-origin'

      # HTTPS enforcement (when behind proxy with X-Forwarded-Proto)
      if ENV['DLCENTER_FORCE_HTTPS'] && request.env['HTTP_X_FORWARDED_PROTO'] == 'http'
        redirect "https://#{request.host}#{request.fullpath}", 301
      end
    end

    # CSRF protection helper
    helpers do
      def sanitize_filename(filename)
        return 'download' if filename.nil? || filename.empty?
        # Remove control characters, quotes, and path separators
        filename.gsub(/[\x00-\x1f\x7f"\\\/\r\n]/, '_').strip[0, 255]
      end

      def valid_content_type?(content_type)
        return false if content_type.nil?
        # Allow only safe content types, default to octet-stream
        content_type.match?(/\A[\w\-]+\/[\w\-\.\+]+\z/) && content_type.length < 256
      end

      def safe_content_type(content_type)
        valid_content_type?(content_type) ? content_type : 'application/octet-stream'
      end

      def check_rate_limit(ip)
        count = settings.connection_counts[ip]
        if count >= settings.max_connections_per_ip
          halt 429, 'Too many connections'
        end
        settings.connection_counts[ip] += 1
      end

      def release_rate_limit(ip)
        settings.connection_counts[ip] -= 1
        settings.connection_counts.delete(ip) if settings.connection_counts[ip] <= 0
      end

      def check_csrf
        # CSRF protection: verify Origin/Referer for state-changing requests
        origin = request.env['HTTP_ORIGIN']
        referer = request.env['HTTP_REFERER']

        # Allow requests with no Origin (same-origin requests from some browsers)
        return if origin.nil? && referer.nil?

        host = request.host
        port = request.port

        # Check Origin header
        if origin
          origin_uri = URI.parse(origin) rescue nil
          if origin_uri
            origin_host = origin_uri.host
            origin_port = origin_uri.port
            return if origin_host == host && (origin_port == port || [80, 443].include?(origin_port))
          end
        end

        # Check Referer header as fallback
        if referer
          referer_uri = URI.parse(referer) rescue nil
          if referer_uri
            referer_host = referer_uri.host
            return if referer_host == host
          end
        end

        halt 403, 'CSRF check failed'
      end
    end

    get '/ws' do
      check_rate_limit(request.ip)
      begin
          request.websocket do |ws|
            namespace = namespace_for_request(request)
            client = WSClient.new namespace, ws
            namespace.add_client client
            ws.onclose do
              release_rate_limit(request.ip)
            end
          end
      rescue SinatraWebsocket::Error::ConnectionError
          release_rate_limit(request.ip)
          puts "Not a websocket"
      end
    end

    post '/p/:filename' do
      check_csrf
      check_rate_limit(request.ip)
      stream(:keep_open) do |out|
        namespace = namespace_for_request(request)
        client = IOClient.new namespace, request.env['data.input'], out,
          filename: sanitize_filename(params[:filename]),
          size: request.env["CONTENT_LENGTH"],
          content_type: safe_content_type(request.env["CONTENT_TYPE"])
        namespace.add_client client
        namespace.broadcast_available_shares
        release_rate_limit(request.ip)
      end
    end

    get '/' do
      File.read(settings.public_folder+'/index.html')
    end

    def namespace_for_request(request)
      ctx_key = ENV.fetch("DLCENTER_COMMON_CONTEXT", nil) ? :default : request.ip
      settings.registry.context_for(ctx_key).namespace_for(:default)
    end

    get '/g' do
      namespace = namespace_for_request(request)
      share = namespace.shares.first
      if share
        options = {
          "Cache-Control" => "no-cache, private",
          "Pragma"        => "no-cache",
          "Content-type"  => safe_content_type(share.content_type),
          "Content-Disposition" => "attachment; filename=\"#{sanitize_filename(share.name)}\""
        }
        options["Content-Length"] = "#{share.size}" unless share.size.nil?
        headers options
        stream(:keep_open) do |out|
          share.content(out)
          nil
        end
      else
        status 404
      end
    end
    get '/all' do
      namespace = namespace_for_request(request)
      shares = namespace.shares
      if shares.size > 0
        options = {
          "Cache-Control" => "no-cache, private",
          "Pragma"        => "no-cache",
          "Content-type"  => "application/zip",
          "Content-Disposition" => "attachment; filename=\"dlcenter-pack-#{Time.now.strftime '%F'}.zip\""
        }
        headers options
        stream(:keep_open) do |out|
          Share.content(shares, out)
          nil
        end
      else
        status 404
      end
    end
    get '/share/:uuid' do
      uuid = params[:uuid]
      # Validate UUID format to prevent log injection
      halt 400, 'Invalid UUID' unless uuid.match?(/\A[a-f0-9\-]{36}\z/i)
      share = settings.registry.get_share_by_uuid uuid
      if share
        headers \
        "Cache-Control" => "no-cache, private",
        "Pragma"        => "no-cache",
        "Content-type"  => safe_content_type(share.content_type),
        "Content-Length" => "#{share.size}",
        "Content-Disposition" => "attachment; filename=\"#{sanitize_filename(share.name)}\""

        stream(:keep_open) do |out|
          share.content(out)
          nil
        end
      else
        status 404
      end
    end
  end
end
