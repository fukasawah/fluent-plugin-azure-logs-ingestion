# frozen_string_literal: true

require_relative 'helper'
require_relative 'support/fake_azure_server'
require_relative 'support/helpers'
require 'fluent/test/driver/output'
require 'fluent/plugin/out_azure_logs_ingestion'
require 'stringio'
require 'zlib'

class AzureLogsIngestionWriteTest < Test::Unit::TestCase
  def create_driver(conf)
    Fluent::Test::Driver::Output.new(Fluent::Plugin::AzureLogsIngestionOutput).configure(conf)
  end

  test 'writes a chunk with service principal auth' do
    server = FakeAzureServer.new do |request|
      case request.path
      when %r{/tenant/oauth2/v2.0/token}
        [200, { 'Content-Type' => 'application/json' }, { access_token: 'token-1', expires_in: '3600' }.to_json]
      when %r{/dataCollectionRules/.+/streams/Custom-MyTable\?api-version=2023-01-01}
        [200, { 'Content-Type' => 'application/json' }, '{}']
      else
        [404, {}, 'not found']
      end
    end.start

    driver = create_driver(<<~CONFIG)
      endpoint #{server.url}
      authority_host #{server.url}
      dcr_immutable_id dcr-000a00a000a00000a000000aa000a0aa
      stream_name Custom-MyTable
      tenant_id tenant
      client_id client
      client_secret secret
      <buffer>
        @type memory
      </buffer>
    CONFIG

    driver.instance.start
    driver.instance.write(FakeChunk.new([
      [Fluent::EventTime.from_time(Time.utc(2026, 1, 1, 0, 0, 0)), { 'message' => 'hello' }]
    ]))

    ingestion_request = server.requests.last
    assert_equal 'Bearer token-1', ingestion_request.headers['authorization']
    assert_match(/"message":"hello"/, ingestion_request.body)
    assert_not_match(/"TimeGenerated":/, ingestion_request.body)
  ensure
    driver&.instance&.shutdown
    driver&.instance&.close
    server&.stop
  end

  test 'raises unrecoverable error for 400 response' do
    server = FakeAzureServer.new do |request|
      case request.path
      when %r{/tenant/oauth2/v2.0/token}
        [200, { 'Content-Type' => 'application/json' }, { access_token: 'token-1', expires_in: '3600' }.to_json]
      else
        [400, { 'Content-Type' => 'application/json' }, '{"error":"bad request"}']
      end
    end.start

    driver = create_driver(<<~CONFIG)
      endpoint #{server.url}
      authority_host #{server.url}
      dcr_immutable_id dcr-000a00a000a00000a000000aa000a0aa
      stream_name Custom-MyTable
      tenant_id tenant
      client_id client
      client_secret secret
      <buffer>
        @type memory
      </buffer>
    CONFIG

    driver.instance.start
    error = assert_raise(Fluent::UnrecoverableError) do
      driver.instance.write(FakeChunk.new([
        [Fluent::EventTime.from_time(Time.utc(2026, 1, 1, 0, 0, 0)), { 'message' => 'hello' }]
      ]))
    end

    assert_match(/400/, error.message)
  ensure
    driver&.instance&.shutdown
    driver&.instance&.close
    server&.stop
  end

  test 'sends gzip payload when enabled' do
    server = FakeAzureServer.new do |request|
      case request.path
      when %r{/tenant/oauth2/v2.0/token}
        [200, { 'Content-Type' => 'application/json' }, { access_token: 'token-1', expires_in: '3600' }.to_json]
      when %r{/dataCollectionRules/.+/streams/Custom-MyTable\?api-version=2023-01-01}
        [200, { 'Content-Type' => 'application/json' }, '{}']
      else
        [404, {}, 'not found']
      end
    end.start

    driver = create_driver(<<~CONFIG)
      endpoint #{server.url}
      authority_host #{server.url}
      dcr_immutable_id dcr-000a00a000a00000a000000aa000a0aa
      stream_name Custom-MyTable
      tenant_id tenant
      client_id client
      client_secret secret
      gzip true
      <buffer>
        @type memory
      </buffer>
    CONFIG

    driver.instance.start
    driver.instance.write(FakeChunk.new([
      [Fluent::EventTime.from_time(Time.utc(2026, 1, 1, 0, 0, 0)), { 'message' => 'hello' }]
    ]))

    ingestion_request = server.requests.last
    json = Zlib::GzipReader.new(StringIO.new(ingestion_request.body)).read
    assert_equal 'gzip', ingestion_request.headers['content-encoding']
    assert_match(/"message":"hello"/, json)
  ensure
    driver&.instance&.shutdown
    driver&.instance&.close
    server&.stop
  end

  test 'keeps 429 retryable' do
    server = FakeAzureServer.new do |request|
      case request.path
      when %r{/tenant/oauth2/v2.0/token}
        [200, { 'Content-Type' => 'application/json' }, { access_token: 'token-1', expires_in: '3600' }.to_json]
      else
        [429, { 'Retry-After' => '5' }, '{"error":"throttled"}']
      end
    end.start

    driver = create_driver(<<~CONFIG)
      endpoint #{server.url}
      authority_host #{server.url}
      dcr_immutable_id dcr-000a00a000a00000a000000aa000a0aa
      stream_name Custom-MyTable
      tenant_id tenant
      client_id client
      client_secret secret
      <buffer>
        @type memory
      </buffer>
    CONFIG

    driver.instance.start
    error = assert_raise(RuntimeError) do
      driver.instance.write(FakeChunk.new([
        [Fluent::EventTime.from_time(Time.utc(2026, 1, 1, 0, 0, 0)), { 'message' => 'hello' }]
      ]))
    end

    assert_match(/429/, error.message)
  ensure
    driver&.instance&.shutdown
    driver&.instance&.close
    server&.stop
  end
end
