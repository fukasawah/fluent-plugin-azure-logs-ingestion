# frozen_string_literal: true

require_relative 'helper'
require_relative 'support/fake_azure_server'
require_relative 'support/helpers'
require 'fluent/plugin/azure_logs_ingestion/auth'

class AuthManagedIdentityTest < Test::Unit::TestCase
  include TestEnvHelper

  test 'uses app service managed identity endpoint when environment is present' do
    server = FakeAzureServer.new do |_request|
      [200, { 'Content-Type' => 'application/json' }, { access_token: 'msi-token', expires_on: (Time.now.to_i + 3600).to_s }.to_json]
    end.start

    with_env(
      'IDENTITY_ENDPOINT' => "#{server.url}/msi/token",
      'IDENTITY_HEADER' => 'identity-header-value',
      'AZURE_LOGS_INGESTION_IMDS_ENDPOINT' => nil
    ) do
      auth = Fluent::Plugin::AzureLogsIngestion::Auth.new(
        use_msi: true,
        tenant_id: nil,
        client_id: 'user-assigned-client-id',
        client_secret: nil,
        authority_host: 'https://login.microsoftonline.com',
        logs_ingestion_scope: 'https://monitor.azure.com/.default',
        token_refresh_skew: 300,
        logger: TestLogger.new
      )

      assert_equal 'msi-token', auth.token
    end

    request = server.requests.first
    query = URI.decode_www_form(URI(request.path).query).to_h
    assert_equal 'identity-header-value', request.headers['x-identity-header']
    assert_equal 'https://monitor.azure.com/', query['resource']
    assert_equal 'user-assigned-client-id', query['client_id']
  ensure
    server&.stop
  end

  test 'uses IMDS endpoint when app service environment is absent' do
    server = FakeAzureServer.new do |_request|
      [200, { 'Content-Type' => 'application/json' }, { access_token: 'imds-token', expires_on: (Time.now.to_i + 3600).to_s }.to_json]
    end.start

    with_env(
      'IDENTITY_ENDPOINT' => nil,
      'IDENTITY_HEADER' => nil,
      'AZURE_LOGS_INGESTION_IMDS_ENDPOINT' => "#{server.url}/metadata/identity/oauth2/token"
    ) do
      auth = Fluent::Plugin::AzureLogsIngestion::Auth.new(
        use_msi: true,
        tenant_id: nil,
        client_id: 'user-assigned-client-id',
        client_secret: nil,
        authority_host: 'https://login.microsoftonline.com',
        logs_ingestion_scope: 'https://monitor.azure.com/.default',
        token_refresh_skew: 300,
        logger: TestLogger.new
      )

      assert_equal 'imds-token', auth.token
    end

    request = server.requests.first
    query = URI.decode_www_form(URI(request.path).query).to_h
    assert_equal 'true', request.headers['metadata']
    assert_equal 'https://monitor.azure.com/', query['resource']
    assert_equal 'user-assigned-client-id', query['client_id']
  ensure
    server&.stop
  end
end
