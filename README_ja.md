# fluent-plugin-azure-logs-ingestion

Azure Monitor Logs Ingestion API を使い、Log Analytics Workspace のテーブルへ出力する Fluentd output plugin です。

> [!WARNING]
> この plugin は試験的な実装であり、本格的な production workload での動作実績はまだ十分ではありません。

## サポート環境

- Ruby 2.4 以上
- Fluentd 1.13.0 以上、2.0 未満

## インストール

### RubyGems

```bash
fluent-gem install fluent-plugin-azure-logs-ingestion
```

`td-agent` を使う場合は `fluent-gem` の代わりに `td-agent-gem` を使ってください。

### Bundler

Gemfile に次の行を追加してください。

```ruby
gem 'fluent-plugin-azure-logs-ingestion'
```

その後、`bundle install` を実行してください。

### GitHub から Bundler でインストール

Bundler で GitHub repository を直接指定でき、特定の revision に固定したい場合は、`ref` を指定します。

```ruby
gem 'fluent-plugin-azure-logs-ingestion', git: 'https://github.com/fukasawah/fluent-plugin-azure-logs-ingestion.git', ref: '90782c8aad34a1101566909162d8cf02aa40c11a'
```

その後、`bundle install` を実行してください。


## 設定例

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

## 設定

### パラメータ

| Parameter | Required | Default | Description |
| --- | --- | --- | --- |
| `endpoint` | yes | none | Logs Ingestion endpoint または DCE endpoint |
| `dcr_immutable_id` | yes | none | `dcr-...` 形式の immutable DCR ID |
| `stream_name` | yes | none | request URI に指定する DCR の input stream 名 |
| `gzip` | no | `false` | HTTP request body を gzip 圧縮して送信 |
| `use_msi` | no | `false` | service principal ではなく Managed Identity を使う |
| `tenant_id` | no | `ENV['AZURE_TENANT_ID']` | service principal 認証で使う tenant ID |
| `client_id` | no | `ENV['AZURE_CLIENT_ID']` | service principal の client ID、または user-assigned managed identity の client ID |
| `client_secret` | no | `ENV['AZURE_CLIENT_SECRET']` | service principal の client secret |
| `authority_host` | no | `https://login.microsoftonline.com` | OAuth token endpoint の base URL |
| `logs_ingestion_scope` | no | `https://monitor.azure.com/.default` | Logs Ingestion API 用の OAuth scope |
| `token_refresh_skew` | no | `300s` | Azure のアクセストークンを期限の何秒前に再取得するか |

### Buffer パラメータ

この plugin は、production workload で使いやすい file buffer と、Logs Ingestion API の request size 上限に収まりやすい chunk size だけを buffer default として変更しています。

| Buffer parameter | Default | Description |
| --- | --- | --- |
| `@type` | `file` | デフォルトで file buffer を使う |
| `chunk_limit_size` | `900KB` | Logs Ingestion API の 1 MB request size 上限に対して余裕を持たせた chunk size |

### 認証

service principal の認証情報は Fluentd 設定に直接書くことも、環境変数から読むこともできます。

利用できる環境変数:

- `AZURE_TENANT_ID`
- `AZURE_CLIENT_ID`
- `AZURE_CLIENT_SECRET`

Managed Identity を使う場合は `use_msi true` を指定し、`tenant_id` と `client_secret` は省略してください。
User-assigned Managed Identity を使う場合は `client_id` に User-assigned Managed Identity の client ID を指定します。

### Managed Identity の例

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

### Buffer 設定の考え方

- `chunk_limit_size 900KB`: Logs Ingestion API の request size 上限は 1 MB です。1 chunk を 1 request に収めるほうがよいですが、APIリクエストの際の JSON 化によるサイズ増加の余裕を見て 900KB 前後から始めるのが安全です。
- `flush_mode` や `flush_interval` は Fluentd の default を使います。より短い遅延で送信したい場合は、通常の Fluentd buffer 設定として明示してください。

### Auxiliary tier での 30 分制限

Log Analytics Workspace の Auxiliary tier へ送信し、DCR transformation で `TimeGenerated` を変換しない場合、1 request 内の `TimeGenerated` の範囲は 30 分未満にする必要があります。この制限に対応するには、元ログの時刻を Fluentd の event time として扱い、`<buffer time>` と `timekey` で chunk を時間分割してください。

たとえば record の `created_at` が ISO8601 文字列の場合、入力時の parser で event time に変換します。Azure 側にも `created_at` を送る場合は `keep_time_key true` を指定します。

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

すでに record として取り込まれた後に event time を差し替える場合は、filter で `renew_time_key` を使えます。ただし `renew_time_key` に指定するフィールドは Unix timestamp である必要があります。

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

`<buffer time>` の `time` は record 内の `time` フィールドではなく Fluentd の event time です。record の `created_at` や `TimeGenerated` を payload に残すだけでは chunk の時間分割には使われません。

### Plugin 仕様

- 本 plugin は `TimeGenerated` を書き換えません。payload に `time` のような元時刻フィールドがある場合は、DCR の transformation で `extend TimeGenerated = todatetime(['time'])` のように作成することをお勧めします。
- HTTP `400`, `401`, `403`, `413` は unrecoverable として扱い、`429` と `5xx` は Fluentd の retry 対象です。

## Memo: Log Analytics Workspace / DCR / Logs Ingestion API の仕様

- 現状、Log Analytics Workspace の SKU が Auxiliary tier で DCR の transformation を使わない場合、1 request 内の `TimeGenerated` は 30 分未満に収める必要があります。
  - > This limit only applies when ingesting to Auxiliary log tables. If the source entries for TimeGenerated are ingested without being transformed, the range of entries must be less than 30 minutes. 
    >
	> https://learn.microsoft.com/en-us/azure/azure-monitor/fundamentals/service-limits#logs-ingestion-api
- Logs Ingestion API の request size は 1 MB 以下に抑える必要があります。
  - > Maximum size of API call | 1 MB
    >
	> https://learn.microsoft.com/en-us/azure/azure-monitor/fundamentals/service-limits#logs-ingestion-api
- Log Analytics Workspace には重複排除の仕組みがありません。Azure が受理した後で Fluentd が応答を正常に確認できなかった場合、再送により重複が発生します。

## 参考資料

- Azure Monitor Logs Ingestion API overview: https://learn.microsoft.com/azure/azure-monitor/logs/logs-ingestion-api-overview
- Create data collection rules (DCRs) using JSON: https://learn.microsoft.com/azure/azure-monitor/data-collection/data-collection-rule-create-edit
- Azure DCR structure: https://learn.microsoft.com/azure/azure-monitor/data-collection/data-collection-rule-structure
- Azure custom tables and `_CL` suffix: https://learn.microsoft.com/azure/azure-monitor/logs/create-custom-table
- Managed identity on Azure VM: https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/how-to-use-vm-token
- Managed identity on App Service / Functions: https://learn.microsoft.com/azure/app-service/overview-managed-identity
- Fluentd output plugin API: https://docs.fluentd.org/plugin-development/api-plugin-output

## 開発

```bash
bundle install
bundle exec rake test
```

この project は 1 つの `Gemfile` を使います。古い Ruby / Fluentd version の互換性を手元で確認する場合は、rbenv と `FLUENTD_VERSION` を使います。

```bash
rbenv init
source ~/.bashrc

(
	export RBENV_VERSION=2.4.10 FLUENTD_VERSION=1.13.0
	unset GEM_HOME GEM_PATH MY_RUBY_HOME
	rbenv install "$RBENV_VERSION" -s
	rbenv exec gem install bundler -v 2.3.27 --no-document
	rbenv exec bundle _2.3.27_ install
	rbenv exec bundle _2.3.27_ exec rake test
)

(
	export RBENV_VERSION=2.7.8 FLUENTD_VERSION=1.18.0
	unset GEM_HOME GEM_PATH MY_RUBY_HOME
	rbenv install "$RBENV_VERSION" -s
	rbenv exec gem install bundler -v 2.3.27 --no-document
	rbenv exec bundle _2.3.27_ install
	rbenv exec bundle _2.3.27_ exec rake test
)
```

RubyGems へ公開する gem は 1 つだけです。互換性は test で確認し、配布する gem は現在の Ruby で build します。

```bash
bundle install
bundle exec rake test
bundle exec gem build fluent-plugin-azure-logs-ingestion.gemspec --strict
gem push fluent-plugin-azure-logs-ingestion-*.gem
```
