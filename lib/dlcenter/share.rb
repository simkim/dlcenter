require 'securerandom'
require 'zip'
require 'zip_tricks'

module DLCenter
  class Share
    attr_reader :uuid, :client, :oneshot, :inline_content
    attr_accessor :content_type, :name, :size

    def initialize client, options = {}
      @client = client
      @uuid = options[:uuid] || SecureRandom.uuid
      raise "Invalid option : #{options.class} #{options}" unless options.class == Hash
      self.content_type = options[:content_type]
      self.name = options[:name]
      self.size = options[:size]
      @inline_content = options[:content]
      @oneshot = options[:oneshot]
      raise "Must have a name" unless self.name
    end

    def self.content(shares, out)
      w = ZipTricks::BlockWrite.new { |chunk| out.write(chunk) }
      ZipTricks::Streamer.open(w) do |zip|
        shares.each do |share|
          # Sanitize filename to prevent zip path traversal
          safe_name = sanitize_zip_filename(share.name)
          zip.write_deflated_file(safe_name) do |sink|
            r, w = IO.pipe
            share.content(w)
            while true
              buffer = r.read(65536)
              sink << buffer
              break if buffer.size < 65536
            end
          end
        end
      end
    ensure
      out.close
    end

    def self.sanitize_zip_filename(name)
      return 'file' if name.nil? || name.empty?
      # Remove path traversal sequences and leading slashes
      safe = name.gsub(/\.\./, '_').gsub(/^\/+/, '').gsub(/\\/, '_')
      # Remove any remaining absolute path indicators
      safe = safe.sub(/^[A-Za-z]:/, '')
      safe.empty? ? 'file' : safe
    end

    def content(out)
      Streamer.new(self, out).tap do |stream|
        client.ask_for_stream(stream)
      end
    end

    def size=(size)
      @size = size.to_i unless size.nil?
    end
    def link?
      @inline_content && @inline_content.match(/^[a-z]+:\/\//) && true
    end
  end
end
