require 'sinatra'
require 'sinatra-websocket'
require 'securerandom'
require 'json'
require "base64"

class FileStreamer
  attr_accessor :uuid
  def initialize(receiver, ref, out)
    @ref = ref
    @uuid = SecureRandom.uuid
    @receiver = receiver
    @data = ""
    @done = false
    @out = out
  end
  def got_chunk(chunk)
    begin
      chunk = Base64.decode64(chunk)
      puts "stream chunk of size #{chunk.size}"
      @out << chunk
    rescue
      puts "Error decoding chunk"
    end
    @out.close
  end
end

class FileReference
  attr_accessor :client, :content_type, :size
  def initialize(client, options)
    @client = client
    @name = options['name']
    @content_type = options['content_type']
    @size = options['size']
  end

  def stream_file out
    fs = FileStreamer.new @client, self, out
    client.streamers[fs.uuid] = fs
    client.send({
      type: "stream",
      uuid: fs.uuid,
      name: @name
    }.to_json)
    return fs
  end

end

class FileCenterClient
  attr_accessor :streamers
  def initialize(fcip, ws)
    @name = "Unknown"
    @fcip = fcip
    @ws = ws
    @files = {}
    @streamers = {}
  end

  def has_file name
    puts "check if #{self} has file #{name} : #{@files.keys}"
    @files.include? name
  end

  def get_file name
    @files[name]
  end


  def send(msg)
    begin
      @ws.send(msg)
    rescue
      puts "Can't send message to #{@ws}"
    end
  end

  def handle_register_file(msg)
    name = msg['name']
    puts "Websocket #{@ws} share file #{name}"
    @files[name] = FileReference.new(self, msg)
    @fcip.broadcast_available_files
    return
  end

  def get_files_json
    {
      name: @name,
      files: @files.map do |name, ref|
                {
                  name: name
                }
              end
    }
  end

  def handle_chunk(msg)
    uuid = msg['uuid']
    chunk = msg['chunk']
    streamer = @streamers[uuid]
    if streamer
      puts "Got chunk for stream #{uuid}"
      streamer.got_chunk(chunk)
    else
      puts "Unknown streamer #{uuid}"
    end
  end

  def handle_msg(msg)
    #puts msg
    case msg["type"]
    when 'register_file' then handle_register_file(msg)
    when 'chunk' then handle_chunk(msg)
    else puts "Unkown msg : #{msg}"
    end
  end
end

class FileCenterIP
  def initialize(ip)
    @ip = ip
    @clients = []
  end
  def get_file(name)
    @clients.each do |client|
      if client.has_file(name)
        return client.get_file(name)
      end
    end
    return nil
  end

  def has_file(name)
    @clients.each do |client|
      if client.has_file(name)
        return true
      end
    end
    return false
  end

  def get_files_json
    @clients.map(&:get_files_json)
  end
  def broadcast_available_files
    EM.next_tick {
      payload = {type: "files", files: get_files_json}.to_json
      @clients.each do |client|
        client.send(payload)
      end
    }
  end
  def add_websocket(ws)
    puts "Adding websocket for ip #{@ip}"

    client = FileCenterClient.new(self, ws)
    ws.onopen do
      @clients << client
      client.send({type: "hello", text: "Hello World!"}.to_json)
      client.send({type: "files", files: get_files_json}.to_json)
    end
    ws.onmessage do |tmsg|
      begin
        msg = JSON.parse(tmsg)
        client.handle_msg(msg)
      rescue
        puts "Can't parse JSON message"
      end
    end
    ws.onclose do
      warn("websocket closed")
      @clients.delete(client)
      broadcast_available_files
    end
  end
end

class FileCenter
  def initialize
    @ips = {}
  end
  def get_fcip(ip)
	puts "Lookup fcip for ip #{ip}"
    @ips[ip] ||= FileCenterIP.new(ip)
  end
  def add_websocket(ip, ws)
    get_fcip(ip).add_websocket(ws)
  end
end

set :server, 'thin'
set :center, FileCenter.new
set :static, true

get '/ws' do
  request.websocket do |ws|
    settings.center.add_websocket(request.ip, ws)
  end
end

get '/' do
  puts "Visitor from #{request.ip}"
  File.read(settings.public_folder+'/index.html')
end

get '/file/:filename' do
  name = params[:filename]
  puts "Lookup file #{name}"
  fcip = settings.center.get_fcip(request.ip)
  if fcip.has_file(name)
    file = fcip.get_file(name)
    headers \
      "Cache-Control" => "no-cache, private",
      "Pragma"        => "no-cache",
      "Content-type"  => "#{file.content_type}",
      "Content-Disposition" => "attachment; filename=\"#{name}\""
    stream(:keep_open) do |out|
      puts "Stream file with content_type : #{file.content_type}"
      file.stream_file(out)
      nil
    end
  else
    [404, "Not found"]
  end
end
