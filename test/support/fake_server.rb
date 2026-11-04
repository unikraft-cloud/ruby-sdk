# frozen_string_literal: true

require "socket"

# An HTTP/1.1 server on 127.0.0.1 that answers each request with the next
# canned response and records what it received. Connections are kept alive
# and served on a thread each. Enough HTTP for the transport tests:
# Content-Length bodies in, fixed or streamed bodies out.
class FakeServer
  Request = Struct.new(:verb, :target, :headers, :body, :conn, keyword_init: true) do
    def path = target.split("?", 2).first
    def query = target.split("?", 2)[1]
  end

  # @return [Array<Request>] what arrived, in order; `conn` numbers the
  #   connection it came on, from 1
  attr_reader :requests
  # @return [Integer] connections accepted so far
  attr_reader :accepts

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @responses = Queue.new
    @requests = []
    @accepts = 0
    @mutex = Mutex.new
    @sessions = []
    @thread = Thread.new { serve }
  end

  def url = "http://127.0.0.1:#{@server.addr[1]}"

  # @param chunks [Array<String>] written one by one, with a flush between
  # @param close [Boolean] send `Connection: close` and hang up after
  # @param drop [Boolean] hang up after reading the request, unanswered
  # @param delay [Numeric] seconds to wait before answering
  def respond(status: 200, headers: {}, body: "", chunks: nil, close: false, drop: false,
              delay: 0)
    @responses << { status:, headers:, body:, chunks:, close:, drop:, delay: }
    self
  end

  def last_request = @requests.last

  def close
    (@sessions + [@thread]).each(&:kill)
    @server.close
  end

  private

  def serve
    loop do
      client = @server.accept
      conn = @accepts += 1
      @sessions << Thread.new { session(client, conn) }
    end
  end

  def session(client, conn)
    loop { break unless serve_one?(client, conn) }
  rescue IOError, SystemCallError
    nil
  ensure
    client.close
  end

  # Serve one request; false when the connection is done.
  def serve_one?(client, conn)
    line = client.gets or return false
    method, target = line.split
    headers = {}
    while (line = client.gets) && line != "\r\n"
      name, value = line.chomp.split(": ", 2)
      headers[name.downcase] = value
    end
    body = client.read(headers.fetch("content-length", "0").to_i)
    @mutex.synchronize do
      @requests << Request.new(verb: method, target: target, headers: headers, body: body,
                               conn: conn)
    end
    res = @responses.pop
    return false if res[:drop]

    sleep res[:delay]
    write(client, res)
    !res[:close]
  end

  def write(client, res)
    client.write("HTTP/1.1 #{res[:status]} X\r\n")
    client.write("Connection: close\r\n") if res[:close]
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
