# frozen_string_literal: true

if ENV['COVERAGE']
	require 'simplecov'
	SimpleCov.enable_coverage :branch if SimpleCov.respond_to?(:enable_coverage)
	SimpleCov.start do
		add_filter '/test/'
		add_filter '/vendor/'
		track_files 'lib/**/*.rb'
	end
end
require 'test/unit'
require 'fluent/test'

Fluent::Test.setup
