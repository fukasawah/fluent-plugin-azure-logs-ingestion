# frozen_string_literal: true

require_relative 'helper'
require 'fluent/test/driver/output'
require 'fluent/plugin/out_azure_logs_ingestion'

class AzureLogsIngestionOutputTest < Test::Unit::TestCase
  BASE_CONFIG = <<~CONFIG
    endpoint https://example.eastus-1.ingest.monitor.azure.com
    dcr_immutable_id dcr-000a00a000a00000a000000aa000a0aa
    stream_name Custom-MyTable
    tenant_id test-tenant
    client_id test-client
    client_secret test-secret
    <buffer>
      @type memory
    </buffer>
  CONFIG

  def create_driver(conf = BASE_CONFIG)
    Fluent::Test::Driver::Output.new(Fluent::Plugin::AzureLogsIngestionOutput).configure(conf)
  end

  test 'configures minimal service principal settings' do
    driver = create_driver

    assert_equal 'https://example.eastus-1.ingest.monitor.azure.com', driver.instance.endpoint
    assert_equal 'dcr-000a00a000a00000a000000aa000a0aa', driver.instance.dcr_immutable_id
    assert_equal 'Custom-MyTable', driver.instance.stream_name
  end

  test 'allows managed identity without service principal secret' do
    driver = create_driver(<<~CONFIG)
      endpoint https://example.eastus-1.ingest.monitor.azure.com
      dcr_immutable_id dcr-000a00a000a00000a000000aa000a0aa
      stream_name Custom-MyTable
      use_msi true
      <buffer>
        @type memory
      </buffer>
    CONFIG

    assert_equal true, driver.instance.use_msi
  end

  test 'rejects missing credentials when use_msi is false' do
    error = assert_raise(Fluent::ConfigError) do
      create_driver(<<~CONFIG)
        endpoint https://example.eastus-1.ingest.monitor.azure.com
        dcr_immutable_id dcr-000a00a000a00000a000000aa000a0aa
        stream_name Custom-MyTable
        <buffer>
          @type memory
        </buffer>
      CONFIG
    end

    assert_match(/tenant_id, client_id, and client_secret/, error.message)
  end
end
