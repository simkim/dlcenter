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
        client = WSClient.new ws
        namespace = namespace_for_request(request)
        client.namespace = namespace
        namespace.add_client client
      end
    end

    get '/' do
      File.read(settings.public_folder+'/index.html')
    end

    def namespace_for_request(request)
      settings.registry.context_for(request.ip).namespace_for(:default)
    end

    get '/g' do
      namespace = namespace_for_request(request)
      share = namespace.shares.first
      if share
        headers \
          "Cache-Control" => "no-cache, private",
          "Pragma"        => "no-cache",
          "Content-type"  => "#{share.content_type}",
          "Content-Disposition" => "attachment; filename=\"#{share.name}\""
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
