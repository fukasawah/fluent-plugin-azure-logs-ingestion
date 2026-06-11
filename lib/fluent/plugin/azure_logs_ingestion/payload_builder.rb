# frozen_string_literal: true

require 'json'
require 'tempfile'
require 'zlib'

module Fluent
  module Plugin
    module AzureLogsIngestion
      class PayloadBuilder
        MAX_BYTES = 1_048_576
        Result = Struct.new(
          :io,
          :content_encoding,
          :content_length,
          :raw_size,
          :gzip_size,
          :record_count,
          keyword_init: true
        ) do
          def close!
            io.close!
          rescue StandardError
            nil
          end
        end

        def initialize(gzip:)
          @gzip = gzip
        end

        def build(chunk)
          raw_file = Tempfile.new('azure-logs-ingestion-raw')
          raw_file.binmode
          gzip_file = nil

          raw_size = 0
          record_count = 0
          first_record = true

          raw_size += write_bytes(raw_file, '[')
          chunk.each do |_event_time, record|
            json = JSON.generate(record.dup)
            raw_size += write_bytes(raw_file, ',') unless first_record
            raw_size += write_bytes(raw_file, json)
            first_record = false
            record_count += 1
          end
          raw_size += write_bytes(raw_file, ']')
          raw_file.flush
          raw_file.rewind

          gzip_size = nil
          io = raw_file
          content_encoding = nil
          content_length = raw_size

          if @gzip
            gzip_file, gzip_size = gzip_file_from(raw_file)
            io = gzip_file
            content_encoding = 'gzip'
            content_length = gzip_size
            raw_file.close!
          end

          validate!(raw_size: raw_size, gzip_size: gzip_size)

          Result.new(
            io: io,
            content_encoding: content_encoding,
            content_length: content_length,
            raw_size: raw_size,
            gzip_size: gzip_size,
            record_count: record_count
          )
        rescue StandardError
          gzip_file.close! if gzip_file
          raw_file.close! if raw_file
          raise
        end

        private

        def validate!(raw_size:, gzip_size:)
          raise Fluent::UnrecoverableError, "payload size #{raw_size} exceeds #{MAX_BYTES} bytes" if raw_size > MAX_BYTES
          if gzip_size && gzip_size > MAX_BYTES
            raise Fluent::UnrecoverableError, "gzip payload size #{gzip_size} exceeds #{MAX_BYTES} bytes"
          end
        end

        def gzip_file_from(source_file)
          gzip_file = Tempfile.new('azure-logs-ingestion-gzip')
          gzip_file.binmode
          Zlib::GzipWriter.open(gzip_file.path) do |writer|
            source_file.rewind
            IO.copy_stream(source_file, writer)
          end
          gzip_file.close
          gzip_file.open
          gzip_file.binmode
          gzip_file.rewind
          [gzip_file, File.size(gzip_file.path)]
        end

        def write_bytes(io, string)
          io.write(string)
          string.bytesize
        end
      end
    end
  end
end
