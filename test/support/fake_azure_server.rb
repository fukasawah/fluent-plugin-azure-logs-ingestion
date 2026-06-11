# frozen_string_literal: true

require 'socket'
require 'thread'

class FakeAzureServer
  Request = Struct.new(:method, :path, :headers, :body)

  attr_reader :requests

  def initialize(&handler)
    @handler = handler || proc { |_request| [200, {}, ''] }
    @requests = []
    @mutex = Mutex.new
    @closed = false
  end

  def start
    @server = TCPServer.new('127.0.0.1', 0)
    @port = @server.addr[1]
    @thread = Thread.new { run }
    self
  end

  def url
    "http://127.0.0.1:#{@port}"
  end

  def stop
    @closed = true
    @server&.close
    @thread&.join(1)
  rescue IOError, Errno::EBADF
    nil
  end

  private

  def run
    until @closed
      begin
        socket = @server.accept
        handle_client(socket)
      rescue IOError, Errno::EBADF
        break
      end
    end
  end

  def handle_client(socket)
    request_line = socket.gets("\r\n")
    return unless request_line

    method, path, = request_line.strip.split(' ', 3)
    headers = {}
    while (line = socket.gets("\r\n"))
      break if line == "\r\n"

      key, value = line.split(':', 2)
      headers[key.downcase] = value.strip
    end

    body = read_body(socket, headers)
    request = Request.new(method, path, headers, body)
    @mutex.synchronize { @requests << request }
    status, response_headers, response_body = @handler.call(request)
    write_response(socket, status, response_headers || {}, response_body || '')
  ensure
    socket&.close
  end

  def read_body(socket, headers)
    length = headers.fetch('content-length', '0').to_i
    return '' if length <= 0

    socket.read(length)
  end

  def write_response(socket, status, headers, body)
    reason = {
      200 => 'OK',
      400 => 'Bad Request',
      401 => 'Unauthorized',
      403 => 'Forbidden',
      413 => 'Payload Too Large',
      429 => 'Too Many Requests',
      500 => 'Internal Server Error'
    }.fetch(status, 'OK')

    response = +"HTTP/1.1 #{status} #{reason}\r\n"
    response << "Content-Length: #{body.bytesize}\r\n"
    response << "Connection: close\r\n"
    headers.each do |key, value|
      response << "#{key}: #{value}\r\n"
    end
    response << "\r\n"
    response << body
    socket.write(response)
  end
end
