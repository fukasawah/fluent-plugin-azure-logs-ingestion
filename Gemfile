# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

gem 'fluentd', ENV['FLUENTD_VERSION'] if ENV['FLUENTD_VERSION']
gem 'csv', '< 3.2' if ENV['FLUENTD_VERSION'] && Gem::Version.new(ENV['FLUENTD_VERSION']) < Gem::Version.new('1.18')

gem 'rake'
gem 'test-unit'
