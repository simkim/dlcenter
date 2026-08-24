require 'dlcenter/thin_ipv6_host'

RSpec.describe DLCenter::ThinIPv6Host do
  def parse(host)
    request = Thin::Request.new
    request.parse("GET / HTTP/1.1\r\nHost: #{host}\r\n\r\n")
    request.env
  end

  it "keeps a bracketed IPv6 host and its port intact" do
    env = parse("[::1]:55100")
    expect(env['SERVER_NAME']).to eq("[::1]")
    expect(env['SERVER_PORT']).to eq("55100")
    expect { Rack::Lint.new(->(*) { [200, {}, []] }).call(env) }.not_to raise_error
  end

  it "defaults the port for a bracketed IPv6 host without one" do
    env = parse("[::1]")
    expect(env['SERVER_NAME']).to eq("[::1]")
    expect(env['SERVER_PORT']).to eq("80")
  end

  it "leaves regular hosts alone" do
    env = parse("localhost:55100")
    expect(env['SERVER_NAME']).to eq("localhost")
    expect(env['SERVER_PORT']).to eq("55100")
  end
end
