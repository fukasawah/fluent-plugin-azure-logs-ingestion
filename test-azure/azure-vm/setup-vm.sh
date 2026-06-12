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

if [[ -z "$logs_ingestion_endpoint" || -z "$dcr_immutable_id" ]]; then
  echo "Deployment outputs are missing. Check deployment status: az deployment sub show --name ${deployment_name}" >&2
  exit 1
fi

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
  PUBLIC_IP_ADDRESS="$public_ip_address" \
  'bash -s' <<'REMOTE_SCRIPT'
set -euo pipefail

sync_system_clock() {
  echo "Synchronizing system clock..."

  if ! command -v chronyc >/dev/null 2>&1; then
    echo "chronyc is not available. Check time sync status with: timedatectl status" >&2
    return 1
  fi

  sudo chronyc makestep
  sudo chronyc waitsync 30 0.1
  echo "System clock synchronized: $(date --iso-8601=ns)"
}

sync_system_clock

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

bundle config set --local path vendor/bundle
bundle config set --local bin .bundle/bin
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
    flush_mode interval
    flush_interval 1s
  </buffer>
</match>
EOF

if pgrep -f 'fluentd -c fluent.conf' >/dev/null; then
  pkill -f 'fluentd -c fluent.conf'
fi

bundle exec fluentd -c fluent.conf -vv > fluentd.log 2>&1 &
fluentd_pid="$!"

for _ in 1 2 3 4 5 6 7 8 9 10; do
  echo "Current Timestamp: $(date --iso-8601=ns)"
  if bundle exec fluent-cat --host 127.0.0.1 --port 24224 azure.logs <<EOF
{"time":"$(date -u +%FT%TZ)","message":"hello from fluent-ali-test vm","level":"info","source":"${PUBLIC_IP_ADDRESS}"}
EOF
  then
    echo "Sent a test record with fluent-cat. Waiting for Azure request completion. Fluentd PID: ${fluentd_pid}"
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
      if grep -q 'logs ingestion request completed' fluentd.log; then
        echo "Azure Logs Ingestion request completed."
        exit 0
      fi
      if grep -Eq 'UnrecoverableError|unexpected error|failed to flush|logs ingestion request failed| [45][0-9][0-9] ' fluentd.log; then
        echo "Fluentd reported an ingestion error. Last fluentd log lines:" >&2
        tail -n 80 fluentd.log >&2
        exit 1
      fi
      sleep 2
    done

    echo "Timed out waiting for Azure request completion. Last fluentd log lines:" >&2
    tail -n 80 fluentd.log >&2
    exit 1
  fi
  sleep 2
done

echo "Failed to send a test record. Last fluentd log lines:" >&2
tail -n 50 fluentd.log >&2
exit 1
REMOTE_SCRIPT