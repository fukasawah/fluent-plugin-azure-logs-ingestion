# fluent-plugin-azure-logs-ingestion

Fluentd output plugin that sends records to Log Analytics Workspace tables by using the Azure Monitor Logs Ingestion API.

> [!WARNING]
> This plugin is experimental and has not yet been sufficiently proven in serious production workloads.

## Supported Environment

- Ruby 2.4 or later
- Fluentd 1.x

## Installation

### RubyGems

```bash
fluent-gem install fluent-plugin-azure-logs-ingestion
```

If you use `td-agent`, use `td-agent-gem` instead of `fluent-gem`.

### Bundler

Add the following line to your Gemfile.

```ruby
gem 'fluent-plugin-azure-logs-ingestion'
```

Then run `bundle install`.

### Install From GitHub With Bundler

Bundler can point directly at the GitHub repository. Specify `ref` when you want to pin a specific revision.

```ruby
gem 'fluent-plugin-azure-logs-ingestion', git: 'https://github.com/fukasawah/fluent-plugin-azure-logs-ingestion.git', ref: 'abda3b5370ccd61282c8b234ca05042049e09d15'
```

Then run `bundle install`.


## Configuration Example

```conf

<match azure.logs>
	@type azure_logs_ingestion
	endpoint https://example.japaneast-1.ingest.monitor.azure.com
	dcr_immutable_id dcr-000a00a000a00000a000000aa000a0aa
	stream_name Custom-MyTable

	tenant_id YOUR_TENANT_ID
	client_id YOUR_CLIENT_ID
	client_secret YOUR_CLIENT_SECRET

	<buffer>
		@type file
		path /var/log/fluent/azure-logs-ingestion-buffer.*.buf
		chunk_limit_size 900KB
	</buffer>
</match>
```

## Configuration

### Parameters

| Parameter | Required | Default | Description |
| --- | --- | --- | --- |
| `endpoint` | yes | none | Logs Ingestion endpoint or DCE endpoint |
| `dcr_immutable_id` | yes | none | Immutable DCR ID in `dcr-...` format |
| `stream_name` | yes | none | DCR input stream name specified in the request URI |
| `gzip` | no | `false` | Send the HTTP request body compressed with gzip |
| `use_msi` | no | `false` | Use Managed Identity instead of a service principal |
| `tenant_id` | no | `ENV['AZURE_TENANT_ID']` | Tenant ID used for service principal authentication |
| `client_id` | no | `ENV['AZURE_CLIENT_ID']` | Service principal client ID, or user-assigned managed identity client ID |
| `client_secret` | no | `ENV['AZURE_CLIENT_SECRET']` | Service principal client secret |
| `authority_host` | no | `https://login.microsoftonline.com` | OAuth token endpoint base URL |
| `logs_ingestion_scope` | no | `https://monitor.azure.com/.default` | OAuth scope for the Logs Ingestion API |
| `token_refresh_skew` | no | `300s` | How many seconds before expiry to refresh the Azure access token |

### Buffer Parameters

This plugin changes only the buffer defaults needed for a production-friendly file buffer and a chunk size that is likely to fit within the Logs Ingestion API request size limit.

| Buffer parameter | Default | Description |
| --- | --- | --- |
| `@type` | `file` | Use a file buffer by default |
| `chunk_limit_size` | `900KB` | Chunk size with headroom against the Logs Ingestion API 1 MB request size limit |

### Authentication

Service principal credentials can be written directly in the Fluentd configuration or read from environment variables.

Available environment variables:

- `AZURE_TENANT_ID`
- `AZURE_CLIENT_ID`
- `AZURE_CLIENT_SECRET`

When using Managed Identity, specify `use_msi true` and omit `tenant_id` and `client_secret`.
When using User-assigned Managed Identity, specify the User-assigned Managed Identity client ID in `client_id`.

### Managed Identity Example

```conf
<match azure.logs>
	@type azure_logs_ingestion
	endpoint https://example.japaneast-1.ingest.monitor.azure.com
	dcr_immutable_id dcr-000a00a000a00000a000000aa000a0aa
	stream_name Custom-MyTable
	use_msi true
	client_id YOUR_USER_ASSIGNED_MANAGED_IDENTITY_CLIENT_ID

	<buffer>
		@type file
		path /var/log/fluent/azure-logs-ingestion-buffer.*.buf
	</buffer>
</match>
```

### Buffer Configuration Notes

- `chunk_limit_size 900KB`: The Logs Ingestion API request size limit is 1 MB. One chunk should fit in one request, and starting around 900 KB is safer because JSON serialization can increase the API request size.
- `flush_mode` and `flush_interval` use Fluentd defaults. If you need lower delivery latency, specify them explicitly as normal Fluentd buffer settings.

### 30 Minute Limit On Auxiliary Tier

When sending to the Log Analytics Workspace Auxiliary tier without converting `TimeGenerated` in a DCR transformation, the range of `TimeGenerated` values in one request must be less than 30 minutes. To satisfy this limit, treat the original log timestamp as the Fluentd event time, then split chunks by time with `<buffer time>` and `timekey`.

For example, if the record field `created_at` is an ISO8601 string, convert it to event time with the input parser. Specify `keep_time_key true` when you also want to send `created_at` to Azure.

```conf
<source>
	@type tail
	path /var/log/myapp/app.log
	tag azure.logs

	<parse>
		@type json
		time_key created_at
		time_format %iso8601
		keep_time_key true
	</parse>
</source>

<match azure.logs>
	@type azure_logs_ingestion
	# ...
	<buffer time>
		@type file
		# ...
		timekey 20m
	</buffer>
</match>
```

If you need to replace the event time after a record has already been ingested, you can use `renew_time_key` in a filter. The field specified in `renew_time_key` must be a Unix timestamp.

```conf
<filter azure.logs>
	@type record_transformer
	renew_time_key created_at
</filter>


<match azure.logs>
	@type azure_logs_ingestion
	# ...
	<buffer time>
		@type file
		# ...
		timekey 20m
	</buffer>
</match>
```

The `time` in `<buffer time>` is the Fluentd event time, not a `time` field inside the record. Merely leaving `created_at` or `TimeGenerated` in the payload does not make it available for time-based chunking.

### Plugin Behavior

- This plugin does not rewrite `TimeGenerated`. If the payload has an original timestamp field such as `time`, prefer creating it in the DCR transformation, for example `extend TimeGenerated = todatetime(['time'])`.
- HTTP `400`, `401`, `403`, and `413` are treated as unrecoverable. `429` and `5xx` are retried by Fluentd.

## Memo: Log Analytics Workspace / DCR / Logs Ingestion API Behavior

- Currently, when the Log Analytics Workspace SKU is Auxiliary tier and the DCR transformation is not used, `TimeGenerated` in one request must stay within less than 30 minutes.
  - > This limit only applies when ingesting to Auxiliary log tables. If the source entries for TimeGenerated are ingested without being transformed, the range of entries must be less than 30 minutes.
    >
	> https://learn.microsoft.com/en-us/azure/azure-monitor/fundamentals/service-limits#logs-ingestion-api
- Logs Ingestion API request size must be kept to 1 MB or less.
  - > Maximum size of API call | 1 MB
    >
	> https://learn.microsoft.com/en-us/azure/azure-monitor/fundamentals/service-limits#logs-ingestion-api
- Log Analytics Workspace has no deduplication mechanism. If Azure accepts a request but Fluentd cannot confirm the response successfully, retrying can create duplicate records.

## References

- Azure Monitor Logs Ingestion API overview: https://learn.microsoft.com/azure/azure-monitor/logs/logs-ingestion-api-overview
- Create data collection rules (DCRs) using JSON: https://learn.microsoft.com/azure/azure-monitor/data-collection/data-collection-rule-create-edit
- Azure DCR structure: https://learn.microsoft.com/azure/azure-monitor/data-collection/data-collection-rule-structure
- Azure custom tables and `_CL` suffix: https://learn.microsoft.com/azure/azure-monitor/logs/create-custom-table
- Managed identity on Azure VM: https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/how-to-use-vm-token
- Managed identity on App Service / Functions: https://learn.microsoft.com/azure/app-service/overview-managed-identity
- Fluentd output plugin API: https://docs.fluentd.org/plugin-development/api-plugin-output

## Development

```bash
bundle install
bundle exec rake test
```

This project uses a single `Gemfile`. Set `FLUENTD_VERSION` when you want to test a specific Fluentd version.

```bash
rvm use default
bundle install
bundle exec rake test

# Old version tests
rvm install 2.4.10
rvm use 2.4.10
gem install bundler -v 2.3.27 --no-document
FLUENTD_VERSION=1.15.3 bundle install
FLUENTD_VERSION=1.15.3 bundle exec rake test

rvm install 2.7.8
rvm use 2.7.8
gem install bundler -v 2.3.27 --no-document
FLUENTD_VERSION=1.18.0 bundle install
FLUENTD_VERSION=1.18.0 bundle exec rake test
```

RubyGems releases do not need separate gems for each Ruby / Fluentd combination. The gemspec `required_ruby_version` and `fluentd` dependency declare the supported range, so build and push one gem as usual.
Compatibility checks run tests against the selected Ruby / Fluentd combinations. Build the distributable gem once with the current Ruby.

```bash
bundle exec gem build fluent-plugin-azure-logs-ingestion.gemspec --strict
gem push fluent-plugin-azure-logs-ingestion-*.gem
```
