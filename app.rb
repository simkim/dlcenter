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

    get '/ws' do
      request.websocket do |ws|
        namespace = namespace_for_request(request)
        client = WSClient.new namespace, ws
        namespace.add_client client
      end
    end

    post '/p/:filename' do
      stream(:keep_open) do |out|
        namespace = namespace_for_request(request)
        client = IOClient.new namespace, request.env['data.input'], out, filename: params[:filename], size: request.env["CONTENT_LENGTH"], content_type: request.env["CONTENT_TYPE"]
        namespace.add_client client
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
          "Content-type"  => "#{share.content_type || "octet/stream"}",
          "Content-Disposition" => "attachment; filename=\"#{share.name}\""
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

    get '/share/:uuid' do
      uuid = params[:uuid]
      puts "Lookup file #{uuid}"
      share = settings.registry.get_share_by_uuid uuid
      if share
        headers \
        "Cache-Control" => "no-cache, private",
        "Pragma"        => "no-cache",
        "Content-type"  => "#{share.content_type}",
        "Content-Length" => "#{share.size}",
        "Content-Disposition" => "attachment; filename=\"#{share.name}\""

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
