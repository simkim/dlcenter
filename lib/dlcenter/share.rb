require 'securerandom'

module DLCenter
  class Share
    attr_reader :uuid
    attr_accessor :content_type
    def initialize options = {}
      @content_type = options[:content_type]
      @uuid = SecureRandom.uuid
    end
  end
end
