# frozen_string_literal: true

require_relative 'helper'
require_relative 'support/fake_azure_server'
require_relative 'support/helpers'
require 'fluent/plugin/azure_logs_ingestion/auth'

class AuthServicePrincipalTest < Test::Unit::TestCase
  test 'caches service principal token until refresh is needed' do
    server = FakeAzureServer.new do |_request|
      [200, { 'Content-Type' => 'application/json' }, { access_token: 'token-1', expires_in: '3600' }.to_json]
    end.start

    begin
      auth = Fluent::Plugin::AzureLogsIngestion::Auth.new(
        use_msi: false,
        tenant_id: 'tenant-id',
        client_id: 'client-id',
        client_secret: 'secret',
        authority_host: server.url,
        logs_ingestion_scope: 'https://monitor.azure.com/.default',
        token_refresh_skew: 300,
        logger: TestLogger.new
      )

      assert_equal 'token-1', auth.token
      assert_equal 'token-1', auth.token
      assert_equal 1, server.requests.size
      assert_match %r{/tenant-id/oauth2/v2.0/token}, server.requests.first.path
      assert_match(/scope=https%3A%2F%2Fmonitor\.azure\.com%2F\.default/, server.requests.first.body)
    ensure
      server&.stop
    end
  end

  test 'refreshes service principal token when it is already expired' do
    tokens = %w[token-1 token-2]
    server = FakeAzureServer.new do |_request|
      [200, { 'Content-Type' => 'application/json' }, { access_token: tokens.shift, expires_in: '0' }.to_json]
    end.start

    begin
      auth = Fluent::Plugin::AzureLogsIngestion::Auth.new(
        use_msi: false,
        tenant_id: 'tenant-id',
        client_id: 'client-id',
        client_secret: 'secret',
        authority_host: server.url,
        logs_ingestion_scope: 'https://monitor.azure.com/.default',
        token_refresh_skew: 0,
        logger: TestLogger.new
      )

      assert_equal 'token-1', auth.token
      assert_equal 'token-2', auth.token
      assert_equal 2, server.requests.size
    ensure
      server&.stop
    end
  end

  test 'raises unrecoverable error for service principal client error' do
    server = FakeAzureServer.new do |_request|
      [401, { 'Content-Type' => 'application/json' }, '{"error":"unauthorized"}']
    end.start

    begin
      auth = Fluent::Plugin::AzureLogsIngestion::Auth.new(
        use_msi: false,
        tenant_id: 'tenant-id',
        client_id: 'client-id',
        client_secret: 'secret',
        authority_host: server.url,
        logs_ingestion_scope: 'https://monitor.azure.com/.default',
        token_refresh_skew: 300,
        logger: TestLogger.new
      )

      error = assert_raise(Fluent::UnrecoverableError) { auth.token }
      assert_match(/401/, error.message)
    ensure
      server&.stop
    end
  end

  test 'raises retryable error for service principal server error' do
    server = FakeAzureServer.new do |_request|
      [500, { 'Content-Type' => 'application/json' }, '{"error":"server"}']
    end.start

    begin
      auth = Fluent::Plugin::AzureLogsIngestion::Auth.new(
        use_msi: false,
        tenant_id: 'tenant-id',
        client_id: 'client-id',
        client_secret: 'secret',
        authority_host: server.url,
        logs_ingestion_scope: 'https://monitor.azure.com/.default',
        token_refresh_skew: 300,
        logger: TestLogger.new
      )

      error = assert_raise(RuntimeError) { auth.token }
      assert_match(/500/, error.message)
    ensure
      server&.stop
    end
  end

  test 'rejects token response without expiration' do
    server = FakeAzureServer.new do |_request|
      [200, { 'Content-Type' => 'application/json' }, { access_token: 'token-1' }.to_json]
    end.start

    begin
      auth = Fluent::Plugin::AzureLogsIngestion::Auth.new(
        use_msi: false,
        tenant_id: 'tenant-id',
        client_id: 'client-id',
        client_secret: 'secret',
        authority_host: server.url,
        logs_ingestion_scope: 'https://monitor.azure.com/.default',
        token_refresh_skew: 300,
        logger: TestLogger.new
      )

      error = assert_raise(Fluent::UnrecoverableError) { auth.token }
      assert_match(/expires_on or expires_in/, error.message)
    ensure
      server&.stop
    end
  end

  test 'rejects token response with invalid expiration' do
    server = FakeAzureServer.new do |_request|
      [200, { 'Content-Type' => 'application/json' }, { access_token: 'token-1', expires_on: 'not-a-time' }.to_json]
    end.start

    begin
      auth = Fluent::Plugin::AzureLogsIngestion::Auth.new(
        use_msi: false,
        tenant_id: 'tenant-id',
        client_id: 'client-id',
        client_secret: 'secret',
        authority_host: "#{server.url}/",
        logs_ingestion_scope: 'https://monitor.azure.com/.default',
        token_refresh_skew: 300,
        logger: TestLogger.new
      )

      error = assert_raise(Fluent::UnrecoverableError) { auth.token }
      assert_match(/invalid expiration value/, error.message)
    ensure
      server&.stop
    end
  end

  test 'wraps service principal connection failures' do
    socket = TCPServer.new('127.0.0.1', 0)
    authority_host = "http://127.0.0.1:#{socket.addr[1]}"
    socket.close

    auth = Fluent::Plugin::AzureLogsIngestion::Auth.new(
      use_msi: false,
      tenant_id: 'tenant-id',
      client_id: 'client-id',
      client_secret: 'secret',
      authority_host: authority_host,
      logs_ingestion_scope: 'https://monitor.azure.com/.default',
      token_refresh_skew: 300,
      logger: TestLogger.new
    )

    error = assert_raise(RuntimeError) { auth.token }
    assert_match(/token request failed/, error.message)
  end

  test 'rejects invalid service principal json response' do
    server = FakeAzureServer.new do |_request|
      [200, { 'Content-Type' => 'application/json' }, '{']
    end.start

    begin
      auth = Fluent::Plugin::AzureLogsIngestion::Auth.new(
        use_msi: false,
        tenant_id: 'tenant-id',
        client_id: 'client-id',
        client_secret: 'secret',
        authority_host: server.url,
        logs_ingestion_scope: 'https://monitor.azure.com/.default',
        token_refresh_skew: 300,
        logger: TestLogger.new
      )

      error = assert_raise(RuntimeError) { auth.token }
      assert_match(/failed to parse service principal token response/, error.message)
    ensure
      server&.stop
    end
  end
end
