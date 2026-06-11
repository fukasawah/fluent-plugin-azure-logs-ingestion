# fluent-plugin-azure-logs-ingestion

Fluentd output plugin for Azure Monitor Logs Ingestion API.

> [!WARNING]
> This plugin is experimental and has not yet been proven in production workloads.

Use this plugin to send buffered Fluentd records to Azure Monitor through a Data Collection Rule (DCR).

## Installation

### RubyGems

```bash
fluent-gem install fluent-plugin-azure-logs-ingestion
```

For `td-agent`, use `td-agent-gem` instead of `fluent-gem`.

### Bundler

Add the following line to your Gemfile:

```ruby
gem 'fluent-plugin-azure-logs-ingestion'
```

Then run `bundle install`.

### Bundler From GitHub

You can point Bundler directly at the GitHub repository. To pin a specific revision, specify `ref`.

```ruby
gem 'fluent-plugin-azure-logs-ingestion', git: 'https://github.com/fukasawah/fluent-plugin-azure-logs-ingestion.git'
```

```ruby
gem 'fluent-plugin-azure-logs-ingestion', git: 'https://github.com/fukasawah/fluent-plugin-azure-logs-ingestion.git', ref: 'COMMIT_SHA'
```

Then run `bundle install`.

## Quick Start

```conf
<match azure.logs>
	@type azure_logs_ingestion
	endpoint https://example.japaneast-1.ingest.monitor.azure.com
	dcr_immutable_id dcr-000a00a000a00000a000000aa000a0aa
	stream_name Custom-MyTable

	tenant_id YOUR_TENANT_ID
	client_id YOUR_CLIENT_ID
	client_secret YOUR_CLIENT_SECRET

	<buffer time>
		@type file
		path /var/log/fluent/azure-logs-ingestion-buffer.*.buf
		timekey 20m
		chunk_limit_size 900KB
	</buffer>
</match>
```

## Configuration

### Parameters

| Parameter | Required | Default | Description |
| --- | --- | --- | --- |
| `endpoint` | yes | none | Logs Ingestion endpoint or DCE endpoint |
| `dcr_immutable_id` | yes | none | Immutable DCR ID such as `dcr-...` |
| `stream_name` | yes | none | DCR input stream name used in the request URI |
| `gzip` | no | `false` | Compress the HTTP request body with gzip |
| `use_msi` | no | `false` | Use Managed Identity instead of service principal credentials |
| `tenant_id` | no | `ENV['AZURE_TENANT_ID']` | Microsoft Entra tenant ID for service principal auth |
| `client_id` | no | `ENV['AZURE_CLIENT_ID']` | Service principal client ID, or user-assigned managed identity client ID |
| `client_secret` | no | `ENV['AZURE_CLIENT_SECRET']` | Service principal client secret |
| `authority_host` | no | `https://login.microsoftonline.com` | OAuth token endpoint base URL |
| `logs_ingestion_scope` | no | `https://monitor.azure.com/.default` | OAuth scope for Logs Ingestion API |
| `token_refresh_skew` | no | `300s` | Refresh access token this long before expiry |

### Buffer Parameters

This plugin only changes the buffer defaults needed to use a production-friendly file buffer and keep chunks below the Logs Ingestion API request size limit.

| Buffer parameter | Default | Description |
| --- | --- | --- |
| `@type` | `file` | Use file buffering by default |
| `chunk_limit_size` | `900KB` | Target chunk size with headroom below the Logs Ingestion API 1 MB request limit |

### Authentication

Service principal credentials can be set directly in the Fluentd config, or through environment variables.

Supported environment variables:

- `AZURE_TENANT_ID`
- `AZURE_CLIENT_ID`
- `AZURE_CLIENT_SECRET`

Example:

```bash
export AZURE_TENANT_ID="..."
export AZURE_CLIENT_ID="..."
export AZURE_CLIENT_SECRET="..."
```

When using Managed Identity, set `use_msi true` and omit `tenant_id` / `client_secret`.
For user-assigned Managed Identity, set `client_id` to the managed identity client ID.

### Managed Identity Example

```conf
<match azure.logs>
	@type azure_logs_ingestion
	endpoint https://example.japaneast-1.ingest.monitor.azure.com
	dcr_immutable_id dcr-000a00a000a00000a000000aa000a0aa
	stream_name Custom-MyTable
	use_msi true
	client_id YOUR_USER_ASSIGNED_MANAGED_IDENTITY_CLIENT_ID

	<buffer time>
		@type file
		path /var/log/fluent/azure-logs-ingestion-buffer.*.buf
		timekey 20m
	</buffer>
</match>
```

### Buffering

The plugin works with normal Fluentd buffering options. Tune them for your workload.

Useful starting points:

- `chunk_limit_size 900KB`: recommended when you want one Fluentd chunk to stay within the Logs Ingestion API 1 MB request limit with some headroom for JSON payload size growth.
- `<buffer time>` and `timekey` control how much time range can end up in one chunk. If you ingest into Auxiliary tier without transformations, keep `timekey` below 30 minutes so one request stays within the Azure-side `TimeGenerated` span limit.
- `flush_mode` and `flush_interval` use Fluentd defaults. Configure them explicitly as normal Fluentd buffer settings if you need lower delivery latency.

### DCR Example for Log Analytics Workspace

If your records include an original timestamp as a string field such as `time`, it is usually clearer to convert that field in the DCR transformation instead of asking Fluentd to rewrite `TimeGenerated`.

Example `dcr.json`:

```json
{
	"kind": "Direct",
	"properties": {
		"streamDeclarations": {
			"Custom-MyTable": {
				"columns": [
					{ "name": "time", "type": "string" },
					{ "name": "message", "type": "string" },
					{ "name": "level", "type": "string" }
				]
			}
		},
		"destinations": {
			"logAnalytics": [
				{
					"name": "workspace",
					"workspaceResourceId": "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<workspace>"
				}
			]
		},
		"dataFlows": [
			{
				"streams": ["Custom-MyTable"],
				"destinations": ["workspace"],
				"transformKql": "source | extend TimeGenerated = todatetime(['time']) | project TimeGenerated, message, level",
				"outputStream": "Custom-MyTable_CL"
			}
		]
	}
}
```

Create the DCR with Azure CLI:

```bash
az monitor data-collection rule create \
	--resource-group my-resource-group \
	--location japaneast \
	--name my-dcr \
	--rule-file dcr.json
```

Then retrieve the immutable ID and endpoint values used by this plugin:

```bash
az monitor data-collection rule show \
	--resource-group my-resource-group \
	--name my-dcr \
	--query '{immutableId:properties.immutableId, endpoint:properties.logsIngestion.endpoints[0].endpoint}'
```

This example assumes the custom table `MyTable_CL` already exists in the workspace.

## Notes

- `stream_name` is the DCR input stream name, not the destination table name. It is the name declared under `streamDeclarations` and referenced by `dataFlows.streams`, for example `Custom-MyTable`.
- The plugin does not rewrite `TimeGenerated`. If your payload already has its own timestamp field such as `time`, prefer converting it in the DCR transformation with `todatetime(...)`.
- Auxiliary tier without transformations requires `TimeGenerated` values in a single request to stay within 30 minutes. In that case, keep `timekey` below 30 minutes and leave headroom if `TimeGenerated` comes from the record body.
- The plugin always rejects request bodies larger than 1 MB before send.
- Retries are at-least-once. If Azure accepts a request but Fluentd cannot confirm the response cleanly, duplicate ingestion is possible.
- HTTP `400`, `401`, `403`, and `413` are treated as unrecoverable. `429` and `5xx` are retried by Fluentd.

## References

- Azure Monitor Logs Ingestion API overview: https://learn.microsoft.com/azure/azure-monitor/logs/logs-ingestion-api-overview
- Create data collection rules (DCRs) using JSON: https://learn.microsoft.com/azure/azure-monitor/data-collection/data-collection-rule-create-edit
- Azure DCR structure: https://learn.microsoft.com/azure/azure-monitor/data-collection/data-collection-rule-structure
- Azure CLI `az monitor data-collection rule`: https://learn.microsoft.com/cli/azure/monitor/data-collection/rule
- Azure custom tables and `_CL` suffix: https://learn.microsoft.com/azure/azure-monitor/logs/create-custom-table
- Managed identity on Azure VM: https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/how-to-use-vm-token
- Managed identity on App Service / Functions: https://learn.microsoft.com/azure/app-service/overview-managed-identity
- Fluentd output plugin API: https://docs.fluentd.org/plugin-development/api-plugin-output

## Development

```bash
bundle install
bundle exec rake test
```
