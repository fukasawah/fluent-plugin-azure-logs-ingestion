# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require 'time'
require 'openssl'

module Fluent
  module Plugin
    module AzureLogsIngestion
      class Auth
        Token = Struct.new(:value, :expires_at, keyword_init: true)

        IMDS_API_VERSION = '2018-02-01'
        APP_SERVICE_API_VERSION = '2019-08-01'
        IMDS_ENDPOINT = 'http://169.254.169.254/metadata/identity/oauth2/token'

        def initialize(use_msi:, tenant_id:, client_id:, client_secret:, authority_host:, logs_ingestion_scope:, token_refresh_skew:, logger:)
          @use_msi = use_msi
          @tenant_id = tenant_id
          @client_id = client_id
          @client_secret = client_secret
          @authority_host = authority_host
          @logs_ingestion_scope = logs_ingestion_scope
          @token_refresh_skew = token_refresh_skew
          @log = logger
          @token = nil
          @mutex = Mutex.new
        end

        def token
          @mutex.synchronize do
            if token_valid?(@token)
              @log.debug('reusing cached access token', expires_at: @token.expires_at.utc.iso8601)
              return @token.value
            end

            @token = @use_msi ? fetch_msi_token : fetch_service_principal_token
            @log.debug('fetched new access token', mode: @use_msi ? 'managed_identity' : 'service_principal', expires_at: @token.expires_at.utc.iso8601)
            @token.value
          end
        end

        private

        def token_valid?(token)
          token && token.expires_at && (Time.now + @token_refresh_skew) < token.expires_at
        end

        def fetch_service_principal_token
          uri = URI.join(normalized_authority_host, "#{@tenant_id}/oauth2/v2.0/token")
          @log.debug('requesting service principal token', authority_host: normalized_authority_host, tenant_id: @tenant_id, scope: @logs_ingestion_scope)
          request = Net::HTTP::Post.new(uri)
          request.set_form_data(
            'grant_type' => 'client_credentials',
            'client_id' => @client_id,
            'client_secret' => @client_secret,
            'scope' => @logs_ingestion_scope
          )

          response = perform_request(uri, request)
          body = parse_json_body(response)
          build_token_from_token_response(body)
        rescue JSON::ParserError => error
          raise "failed to parse service principal token response: #{error.message}"
        end

        def fetch_msi_token
          if ENV['IDENTITY_ENDPOINT'] && (ENV['IDENTITY_HEADER'] || ENV['MSI_SECRET'])
            fetch_app_service_token
          else
            fetch_imds_token
          end
        end

        def fetch_imds_token
          uri = URI(ENV.fetch('AZURE_LOGS_INGESTION_IMDS_ENDPOINT', IMDS_ENDPOINT))
          params = {
            'api-version' => IMDS_API_VERSION,
            'resource' => scope_resource(@logs_ingestion_scope)
          }
          params['client_id'] = @client_id if @client_id && !@client_id.empty?
          uri.query = URI.encode_www_form(params)

          request = Net::HTTP::Get.new(uri)
          request['Metadata'] = 'true'
          @log.debug('requesting managed identity token via IMDS', endpoint: uri.to_s, resource: params['resource'], client_id: params['client_id'])

          response = perform_request(uri, request)
          body = parse_json_body(response)
          build_token_from_token_response(body)
        rescue JSON::ParserError => error
          raise "failed to parse IMDS token response: #{error.message}"
        end

        def fetch_app_service_token
          uri = URI(ENV.fetch('IDENTITY_ENDPOINT'))
          params = {
            'api-version' => APP_SERVICE_API_VERSION,
            'resource' => scope_resource(@logs_ingestion_scope)
          }
          params['client_id'] = @client_id if @client_id && !@client_id.empty?
          existing = URI.decode_www_form(String(uri.query))
          uri.query = URI.encode_www_form(existing + params.to_a)

          request = Net::HTTP::Get.new(uri)
          request['X-IDENTITY-HEADER'] = ENV['IDENTITY_HEADER'] if ENV['IDENTITY_HEADER']
          request['Secret'] = ENV['MSI_SECRET'] if ENV['MSI_SECRET']
          @log.debug('requesting managed identity token via app service endpoint', endpoint: uri.to_s, resource: params['resource'], client_id: params['client_id'])

          response = perform_request(uri, request)
          body = parse_json_body(response)
          build_token_from_token_response(body)
        rescue KeyError => error
          raise Fluent::ConfigError, error.message
        rescue JSON::ParserError => error
          raise "failed to parse App Service managed identity response: #{error.message}"
        end

        def perform_request(uri, request)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == 'https'
          http.open_timeout = 10
          http.read_timeout = 30
          http.verify_mode = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?

          response = http.request(request)
          handle_token_response_errors(response)
          response
        rescue Timeout::Error, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ECONNRESET, EOFError, SocketError, IOError, SystemCallError => error
          raise "token request failed: #{error.message}"
        end

        def handle_token_response_errors(response)
          return if response.is_a?(Net::HTTPSuccess)

          message = "token endpoint returned #{response.code} #{response.message} #{String(response.body).strip}".strip
          status = response.code.to_i

          if @use_msi
            raise message if retryable_msi_status?(status)
            raise Fluent::UnrecoverableError, message if status >= 400 && status < 500
            raise message
          end

          raise Fluent::UnrecoverableError, message if status >= 400 && status < 500
          raise message
        end

        def retryable_msi_status?(status)
          status == 404 || status == 410 || status == 429 || status >= 500
        end

        def parse_json_body(response)
          JSON.parse(String(response.body))
        end

        def build_token_from_token_response(body)
          token = body.fetch('access_token')
          expires_at = parse_token_expiry(body)
          Token.new(value: token, expires_at: expires_at)
        end

        def parse_token_expiry(body)
          return Time.at(Integer(body['expires_on'])) if body['expires_on']
          return Time.now + Integer(body['expires_in']) if body['expires_in']

          raise Fluent::UnrecoverableError, 'token response did not include expires_on or expires_in'
        rescue ArgumentError, TypeError
          raise Fluent::UnrecoverableError, 'token response included an invalid expiration value'
        end

        def normalized_authority_host
          @authority_host.end_with?('/') ? @authority_host : "#{@authority_host}/"
        end

        def scope_resource(scope)
          scope.sub(%r{/\.default\z}, '/')
        end
      end
    end
  end
end
