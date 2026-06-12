# frozen_string_literal: true

require_relative 'helper'
require 'fluent/plugin/azure_logs_ingestion/version'

class VersionTest < Test::Unit::TestCase
  test 'defines plugin version' do
    assert_match(/\A\d+\.\d+\.\d+\z/, Fluent::Plugin::AzureLogsIngestion::VERSION)
  end
end
