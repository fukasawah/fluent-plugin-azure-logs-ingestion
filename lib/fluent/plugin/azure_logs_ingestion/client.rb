# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require 'openssl'
require 'securerandom'
require 'time'

module Fluent
  module Plugin
    module AzureLogsIngestion
      class Client
        def initialize(endpoint:, dcr_immutable_id:, stream_name:, logger:)
          @endpoint = endpoint
          @dcr_immutable_id = dcr_immutable_id
          @stream_name = stream_name
          @log = logger
        end

        def send_payload(payload:, bearer_token:)
          uri = build_uri
          @log.debug('sending logs ingestion request', uri: uri.to_s, content_length: payload.content_length, content_encoding: payload.content_encoding)
          request = Net::HTTP::Post.new(uri)
          request['Authorization'] = "Bearer #{bearer_token}"
          request['Content-Type'] = 'application/json'
          request['Content-Encoding'] = payload.content_encoding if payload.content_encoding
          request['x-ms-client-request-id'] = SecureRandom.uuid
          request.body_stream = payload.io
          request.content_length = payload.content_length

          response = perform_request(uri, request)
          handle_response(response)
          true
        rescue Timeout::Error, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ECONNRESET, EOFError, SocketError, IOError, SystemCallError => error
          raise "logs ingestion request failed: #{error.message}"
        ensure
          payload.io.rewind if payload&.io
        end

        private

        def build_uri
          base = @endpoint.end_with?('/') ? @endpoint : "#{@endpoint}/"
          URI.join(base, "dataCollectionRules/#{@dcr_immutable_id}/streams/#{@stream_name}?api-version=2023-01-01")
        end

        def perform_request(uri, request)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == 'https'
          http.open_timeout = 10
          http.read_timeout = 60
          http.verify_mode = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?
          http.request(request)
        end

        def handle_response(response)
          code = response.code.to_i
          @log.debug('received logs ingestion response', code: code, message: response.message, retry_after: response['Retry-After'])
          return handle_success_response(response) if response.is_a?(Net::HTTPSuccess)

          message = "#{response.code} #{response.message} #{String(response.body).strip}".strip
          case code
          when 400, 401, 403, 413
            raise Fluent::UnrecoverableError, message
          when 429
            @log.warn('received retryable 429 from Logs Ingestion API', retry_after: response['Retry-After']) if response['Retry-After']
            raise message
          when 500..599
            raise message
          else
            if code >= 400 && code < 500
              raise Fluent::UnrecoverableError, message
            end

            raise message
          end
        end

        def handle_success_response(response)
          body = String(response.body)
          return true if body.empty?

          JSON.parse(body)
          true
        rescue JSON::ParserError => error
          raise "successful response body was not valid JSON: #{error.message}"
        end
      end
    end
  end
end
