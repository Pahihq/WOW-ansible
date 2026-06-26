#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="/var/lib/node_exporter/textfile_collector"
TMP_FILE="${OUT_DIR}/speedtest.prom.tmp"
OUT_FILE="${OUT_DIR}/speedtest.prom"

mkdir -p "$OUT_DIR"

HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"
TIMESTAMP="$(date +%s)"

RESULT="$(timeout 300 speedtest --accept-license --accept-gdpr --format=json 2>/tmp/speedtest_metrics_error.log || true)"

if [[ -z "$RESULT" ]] || ! echo "$RESULT" | jq -e '.type == "result"' >/dev/null 2>&1; then
  cat > "$TMP_FILE" <<EOF
custom_speedtest_available{host="${HOSTNAME_FQDN}"} 1
custom_speedtest_success{host="${HOSTNAME_FQDN}"} 0
custom_speedtest_last_failed_timestamp_seconds{host="${HOSTNAME_FQDN}"} ${TIMESTAMP}
EOF
  mv "$TMP_FILE" "$OUT_FILE"
  exit 0
fi

DOWNLOAD_BPS="$(echo "$RESULT" | jq -r '.download.bandwidth * 8')"
UPLOAD_BPS="$(echo "$RESULT" | jq -r '.upload.bandwidth * 8')"
PING_MS="$(echo "$RESULT" | jq -r '.ping.latency')"
JITTER_MS="$(echo "$RESULT" | jq -r '.ping.jitter')"
PACKET_LOSS="$(echo "$RESULT" | jq -r '.packetLoss // 0')"

cat > "$TMP_FILE" <<EOF
custom_speedtest_available{host="${HOSTNAME_FQDN}"} 1
custom_speedtest_success{host="${HOSTNAME_FQDN}"} 1
custom_speedtest_download_bits_per_second{host="${HOSTNAME_FQDN}"} ${DOWNLOAD_BPS}
custom_speedtest_upload_bits_per_second{host="${HOSTNAME_FQDN}"} ${UPLOAD_BPS}
custom_speedtest_ping_latency_milliseconds{host="${HOSTNAME_FQDN}"} ${PING_MS}
custom_speedtest_jitter_latency_milliseconds{host="${HOSTNAME_FQDN}"} ${JITTER_MS}
custom_speedtest_packet_loss_percent{host="${HOSTNAME_FQDN}"} ${PACKET_LOSS}
custom_speedtest_last_run_timestamp_seconds{host="${HOSTNAME_FQDN}"} ${TIMESTAMP}
EOF

mv "$TMP_FILE" "$OUT_FILE"
