# frozen_string_literal: true

require 'json'
require 'time'
require 'uri'

class TestLogger
  def debug(*)
    nil
  end

  def info(*)
    nil
  end

  def warn(*)
    nil
  end

  def error(*)
    nil
  end
end

FakeChunk = Struct.new(:events, :chunk_id) do
  def initialize(events, chunk_id = '0123456789ab')
    super(events, chunk_id)
  end

  def each(&block)
    events.each(&block)
  end

  def unique_id
    chunk_id
  end
end

module TestEnvHelper
  def with_env(values)
    previous = {}
    values.each do |key, value|
      previous[key] = ENV[key]
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    previous.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end
end
