# frozen_string_literal: true

require 'fluent/plugin/output'
require_relative 'azure_logs_ingestion/version'
require_relative 'azure_logs_ingestion/auth'
require_relative 'azure_logs_ingestion/payload_builder'
require_relative 'azure_logs_ingestion/client'

module Fluent
  module Plugin
    class AzureLogsIngestionOutput < Output
      Fluent::Plugin.register_output('azure_logs_ingestion', self)

      config_param :endpoint, :string
      config_param :dcr_immutable_id, :string
      config_param :stream_name, :string
      config_param :gzip, :bool, default: false
      config_param :use_msi, :bool, default: false
      config_param :tenant_id, :string, default: ENV['AZURE_TENANT_ID']
      config_param :client_id, :string, default: ENV['AZURE_CLIENT_ID']
      config_param :client_secret, :string, secret: true, default: ENV['AZURE_CLIENT_SECRET']
      config_param :authority_host, :string, default: 'https://login.microsoftonline.com'
      config_param :logs_ingestion_scope, :string, default: 'https://monitor.azure.com/.default'
      config_param :token_refresh_skew, :time, default: 300

      config_section :buffer do
        config_set_default :@type, 'file'
        config_set_default :chunk_limit_size, 900 * 1024
      end

      def configure(conf)
        super

        validate_urls!

        return if @use_msi
        return if @tenant_id && @client_id && @client_secret

        raise Fluent::ConfigError, 'tenant_id, client_id, and client_secret are required when use_msi is false'
      end

      def start
        super
        @auth = AzureLogsIngestion::Auth.new(
          use_msi: @use_msi,
          tenant_id: @tenant_id,
          client_id: @client_id,
          client_secret: @client_secret,
          authority_host: @authority_host,
          logs_ingestion_scope: @logs_ingestion_scope,
          token_refresh_skew: @token_refresh_skew,
          logger: log
        )
        @client = AzureLogsIngestion::Client.new(
          endpoint: @endpoint,
          dcr_immutable_id: @dcr_immutable_id,
          stream_name: @stream_name,
          logger: log
        )
      end

      def write(chunk)
        log.debug('building logs ingestion payload', chunk_id: dump_unique_id_hex(chunk.unique_id), gzip: @gzip)
        payload = AzureLogsIngestion::PayloadBuilder.new(gzip: @gzip).build(chunk)

        log.debug(
          'built logs ingestion payload',
          chunk_id: dump_unique_id_hex(chunk.unique_id),
          record_count: payload.record_count,
          raw_size: payload.raw_size,
          gzip_size: payload.gzip_size,
          content_length: payload.content_length
        )

        token = @auth.token
        @client.send_payload(payload: payload, bearer_token: token)
        log.debug('logs ingestion request completed', chunk_id: dump_unique_id_hex(chunk.unique_id))
      ensure
        payload&.close!
      end

      private

      def validate_urls!
        validate_url!(@endpoint, 'endpoint')
        validate_url!(@authority_host, 'authority_host')
      end

      def validate_url!(value, field)
        uri = URI.parse(value)
        return if uri.is_a?(URI::HTTP) && uri.host

        raise Fluent::ConfigError, "#{field} must be a valid HTTP or HTTPS URL"
      rescue URI::InvalidURIError
        raise Fluent::ConfigError, "#{field} must be a valid HTTP or HTTPS URL"
      end
    end
  end
end
