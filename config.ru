$LOAD_PATH << File.join(__dir__, 'lib')
require "./app"

use Rack::Config do |env|
    if env['PATH_INFO'].start_with? '/p/' and env['REQUEST_METHOD'] == 'POST'
        env['rack.input'], env['data.input'] = StringIO.new, env['rack.input']
    end
end

run DLCenter::App
