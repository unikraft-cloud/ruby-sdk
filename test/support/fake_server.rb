# frozen_string_literal: true

require "socket"

# A one-thread HTTP/1.1 server on 127.0.0.1 that answers each request with the
# next canned response and records what it received. Enough HTTP for the
# transport tests: Content-Length bodies in, fixed or streamed bodies out.
class FakeServer
  Request = Struct.new(:verb, :target, :headers, :body, keyword_init: true) do
    def path = target.split("?", 2).first
    def query = target.split("?", 2)[1]
  end

  attr_reader :requests

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @responses = Queue.new
    @requests = []
    @thread = Thread.new { serve }
  end

  def url = "http://127.0.0.1:#{@server.addr[1]}"

  # @param chunks [Array<String>] written one by one, with a flush between
  def respond(status: 200, headers: {}, body: "", chunks: nil)
    @responses << { status: status, headers: headers, body: body, chunks: chunks }
    self
  end

  def last_request = @requests.last

  def close
    @thread.kill
    @server.close
  end

  private

  def serve
    loop do
      client = @server.accept
      handle(client)
    ensure
      client&.close
    end
  end

  def handle(client)
    method, target = client.gets.split
    headers = {}
    while (line = client.gets) && line != "\r\n"
      name, value = line.chomp.split(": ", 2)
      headers[name.downcase] = value
    end
    body = client.read(headers.fetch("content-length", "0").to_i)
    @requests << Request.new(verb: method, target: target, headers: headers, body: body)
    write(client, @responses.pop)
  end

  def write(client, res)
    client.write("HTTP/1.1 #{res[:status]} X\r\nConnection: close\r\n")
    res[:headers].each { |k, v| client.write("#{k}: #{v}\r\n") }
    if res[:chunks]
      client.write("Transfer-Encoding: chunked\r\n\r\n")
      res[:chunks].each do |c|
        client.write("#{c.bytesize.to_s(16)}\r\n#{c}\r\n")
        client.flush
      end
      client.write("0\r\n\r\n")
    else
      client.write("Content-Length: #{res[:body].bytesize}\r\n\r\n#{res[:body]}")
    end
  end
end
