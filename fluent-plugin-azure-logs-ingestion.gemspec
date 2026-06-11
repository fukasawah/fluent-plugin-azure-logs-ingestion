# frozen_string_literal: true

require_relative 'lib/fluent/plugin/azure_logs_ingestion/version'

Gem::Specification.new do |spec|
  spec.name = 'fluent-plugin-azure-logs-ingestion'
  spec.version = Fluent::Plugin::AzureLogsIngestion::VERSION
  spec.authors = ['fukasawah']
  spec.email = ['']

  spec.summary = 'Fluentd output plugin for Azure Monitor Logs Ingestion API'
  spec.description = 'Buffered Fluentd output plugin for Azure Monitor Logs Ingestion API.'
  spec.homepage = 'https://github.com/fukasawah/fluent-plugin-azure-logs-ingestion'
  spec.license = 'Apache-2.0'
  spec.required_ruby_version = '>= 3.1'
  spec.metadata = {
    'rubygems_mfa_required' => 'true',
    'source_code_uri' => spec.homepage
  }

  spec.files = Dir.chdir(__dir__) do
    Dir['lib/**/*.rb', 'test/**/*.rb', 'README.md', 'README_ja.md', 'LICENSE', 'Rakefile', 'Gemfile']
  end
  spec.require_paths = ['lib']

  spec.add_runtime_dependency 'fluentd', '>= 1.16', '< 2'
  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'test-unit', '~> 3.6'
end
