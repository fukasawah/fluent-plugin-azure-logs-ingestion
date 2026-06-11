#!/usr/bin/env bash
set -euo pipefail

resource_group_name="${RESOURCE_GROUP_NAME:-rg-fluent-ali-test}"
deployment_name="${DEPLOYMENT_NAME:-fluent-ali-test}"
admin_username="${ADMIN_USERNAME:-azureuser}"
public_ip_name="${PUBLIC_IP_NAME:-fluent-ali-test-pip}"
plugin_git_url="${PLUGIN_GIT_URL:-https://github.com/fukasawah/fluent-plugin-azure-logs-ingestion.git}"
plugin_git_ref="${PLUGIN_GIT_REF:-$(git rev-parse HEAD)}"

logs_ingestion_endpoint="$(az deployment sub show \
  --name "$deployment_name" \
  --query properties.outputs.logsIngestionEndpoint.value \
  --output tsv)"
dcr_immutable_id="$(az deployment sub show \
  --name "$deployment_name" \
  --query properties.outputs.dcrImmutableId.value \
  --output tsv)"

public_ip_address="$(az network public-ip show \
  --resource-group "$resource_group_name" \
  --name "$public_ip_name" \
  --query ipAddress \
  --output tsv)"

echo "Connecting to ${admin_username}@${public_ip_address}"

ssh "${admin_username}@${public_ip_address}" \
  LOGS_INGESTION_ENDPOINT="$logs_ingestion_endpoint" \
  DCR_IMMUTABLE_ID="$dcr_immutable_id" \
  PLUGIN_GIT_URL="$plugin_git_url" \
  PLUGIN_GIT_REF="$plugin_git_ref" \
  'bash -s' <<'REMOTE_SCRIPT'
set -euo pipefail

sudo apt-get update
sudo apt-get install -y ruby ruby-dev build-essential git
sudo gem install bundler --no-document

mkdir -p fluent-ali-test
cd fluent-ali-test

cat > Gemfile <<EOF
source 'https://rubygems.org'

gem 'fluentd', '>= 1.16', '< 2'
gem 'fluent-plugin-azure-logs-ingestion', git: '${PLUGIN_GIT_URL}', ref: '${PLUGIN_GIT_REF}'
EOF

bundle install

cat > fluent.conf <<EOF
<source>
  @type forward
  port 24224
  bind 127.0.0.1
</source>

<match azure.logs>
  @type azure_logs_ingestion
  endpoint ${LOGS_INGESTION_ENDPOINT}
  dcr_immutable_id ${DCR_IMMUTABLE_ID}
  stream_name Custom-FluentAliTest
  use_msi true

  <buffer>
    @type file
    path /tmp/fluent-ali-test-buffer.*.buf
    chunk_limit_size 900KB
    flush_interval 5s
  </buffer>
</match>
EOF

if pgrep -f 'fluentd -c fluent.conf' >/dev/null; then
  pkill -f 'fluentd -c fluent.conf'
fi

bundle exec fluentd -c fluent.conf > fluentd.log 2>&1 &
fluentd_pid="$!"

for _ in 1 2 3 4 5 6 7 8 9 10; do
  if bundle exec fluent-cat --host 127.0.0.1 --port 24224 azure.logs <<EOF
{"time":"$(date -u +%FT%TZ)","message":"hello from fluent-ali-test vm","level":"info","source":"setup-vm.sh"}
EOF
  then
    echo "Sent a test record with fluent-cat. Fluentd PID: ${fluentd_pid}"
    exit 0
  fi
  sleep 2
done

echo "Failed to send a test record. Last fluentd log lines:" >&2
tail -n 50 fluentd.log >&2
exit 1
REMOTE_SCRIPT