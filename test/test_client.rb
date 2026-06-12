# frozen_string_literal: true

require_relative 'helper'
require_relative 'support/fake_azure_server'
require_relative 'support/helpers'
require 'fluent/plugin/azure_logs_ingestion/client'
require 'tempfile'

class ClientTest < Test::Unit::TestCase
  Payload = Struct.new(:io, :content_encoding, :content_length)

  def build_payload(body = '[{"message":"hello"}]', content_encoding = nil)
    file = Tempfile.new('azure-logs-ingestion-client-test')
    file.binmode
    file.write(body)
    file.flush
    file.rewind
    Payload.new(file, content_encoding, body.bytesize)
  end

  def build_client(server)
    Fluent::Plugin::AzureLogsIngestion::Client.new(
      endpoint: server.url,
      dcr_immutable_id: 'dcr-immutable-id',
      stream_name: 'Custom-MyTable',
      logger: TestLogger.new
    )
  end

  def build_client_for_endpoint(endpoint)
    Fluent::Plugin::AzureLogsIngestion::Client.new(
      endpoint: endpoint,
      dcr_immutable_id: 'dcr-immutable-id',
      stream_name: 'Custom-MyTable',
      logger: TestLogger.new
    )
  end

  def with_payload(body = '[{"message":"hello"}]', content_encoding = nil)
    payload = build_payload(body, content_encoding)
    yield payload
  ensure
    payload.io.close! if payload && payload.io
  end

  test 'sends payload to logs ingestion endpoint' do
    server = FakeAzureServer.new do |_request|
      [200, { 'Content-Type' => 'application/json' }, '{}']
    end.start

    begin
      with_payload do |payload|
        assert_equal true, build_client(server).send_payload(payload: payload, bearer_token: 'token-1')
      end

      request = server.requests.first
      assert_equal 'POST', request.method
      assert_match %r{/dataCollectionRules/dcr-immutable-id/streams/Custom-MyTable\?api-version=2023-01-01}, request.path
      assert_equal 'Bearer token-1', request.headers['authorization']
      assert_equal 'application/json', request.headers['content-type']
      assert_not_nil request.headers['x-ms-client-request-id']
      assert_match(/"message":"hello"/, request.body)
    ensure
      server&.stop
    end
  end

  test 'sends content encoding when payload is compressed' do
    server = FakeAzureServer.new { |_request| [200, {}, ''] }.start

    begin
      with_payload('compressed', 'gzip') do |payload|
        build_client(server).send_payload(payload: payload, bearer_token: 'token-1')
      end

      assert_equal 'gzip', server.requests.first.headers['content-encoding']
    ensure
      server&.stop
    end
  end

  test 'preserves endpoint path when endpoint has trailing slash' do
    server = FakeAzureServer.new { |_request| [200, {}, ''] }.start

    begin
      with_payload do |payload|
        build_client_for_endpoint("#{server.url}/").send_payload(payload: payload, bearer_token: 'token-1')
      end

      assert_match %r{\A/dataCollectionRules/dcr-immutable-id/streams/Custom-MyTable\?api-version=2023-01-01\z}, server.requests.first.path
    ensure
      server&.stop
    end
  end

  test 'rejects invalid json body on successful response' do
    server = FakeAzureServer.new { |_request| [200, { 'Content-Type' => 'application/json' }, '{'] }.start

    begin
      with_payload do |payload|
        error = assert_raise(RuntimeError) do
          build_client(server).send_payload(payload: payload, bearer_token: 'token-1')
        end
        assert_match(/successful response body was not valid JSON/, error.message)
      end
    ensure
      server&.stop
    end
  end

  test 'treats documented client errors as unrecoverable' do
    [400, 401, 403, 413].each do |status|
      server = FakeAzureServer.new { |_request| [status, {}, 'client error'] }.start

      begin
        with_payload do |payload|
          error = assert_raise(Fluent::UnrecoverableError) do
            build_client(server).send_payload(payload: payload, bearer_token: 'token-1')
          end
          assert_match(/#{status}/, error.message)
        end
      ensure
        server&.stop
      end
    end
  end

  test 'keeps 5xx retryable' do
    server = FakeAzureServer.new { |_request| [500, {}, 'server error'] }.start

    begin
      with_payload do |payload|
        error = assert_raise(RuntimeError) do
          build_client(server).send_payload(payload: payload, bearer_token: 'token-1')
        end
        assert_match(/500/, error.message)
      end
    ensure
      server&.stop
    end
  end

  test 'keeps 429 retryable without retry after header' do
    server = FakeAzureServer.new { |_request| [429, {}, 'throttled'] }.start

    begin
      with_payload do |payload|
        error = assert_raise(RuntimeError) do
          build_client(server).send_payload(payload: payload, bearer_token: 'token-1')
        end
        assert_match(/429/, error.message)
      end
    ensure
      server&.stop
    end
  end

  test 'treats other client errors as unrecoverable' do
    server = FakeAzureServer.new { |_request| [418, {}, 'teapot'] }.start

    begin
      with_payload do |payload|
        error = assert_raise(Fluent::UnrecoverableError) do
          build_client(server).send_payload(payload: payload, bearer_token: 'token-1')
        end
        assert_match(/418/, error.message)
      end
    ensure
      server&.stop
    end
  end

  test 'treats redirects as retryable unexpected responses' do
    server = FakeAzureServer.new { |_request| [302, { 'Location' => 'https://example.invalid/' }, 'redirect'] }.start

    begin
      with_payload do |payload|
        error = assert_raise(RuntimeError) do
          build_client(server).send_payload(payload: payload, bearer_token: 'token-1')
        end
        assert_match(/302/, error.message)
      end
    ensure
      server&.stop
    end
  end

  test 'wraps connection failures as retryable runtime errors' do
    socket = TCPServer.new('127.0.0.1', 0)
    endpoint = "http://127.0.0.1:#{socket.addr[1]}"
    socket.close

    with_payload do |payload|
      error = assert_raise(RuntimeError) do
        build_client_for_endpoint(endpoint).send_payload(payload: payload, bearer_token: 'token-1')
      end
      assert_match(/logs ingestion request failed/, error.message)
    end
  end
end
