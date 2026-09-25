#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="/var/lib/node_exporter/textfile_collector"
TMP_FILE="${OUT_DIR}/speedtest.prom.tmp"
OUT_FILE="${OUT_DIR}/speedtest.prom"
PROVIDER="${SPEEDTEST_PROVIDER:-ookla}"
YANDEX_SPEEDTEST_URL="https://raw.githubusercontent.com/Beta-Blaze/yandex-internetometer-cli/refs/heads/main/speedtest.py"

mkdir -p "$OUT_DIR"

HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"
TIMESTAMP="$(date +%s)"

write_failure_metrics() {
  cat > "$TMP_FILE" <<EOF
custom_speedtest_available{host="${HOSTNAME_FQDN}",provider="${PROVIDER}"} 1
custom_speedtest_success{host="${HOSTNAME_FQDN}",provider="${PROVIDER}"} 0
custom_speedtest_last_failed_timestamp_seconds{host="${HOSTNAME_FQDN}",provider="${PROVIDER}"} ${TIMESTAMP}
EOF
  mv "$TMP_FILE" "$OUT_FILE"
}

write_success_metrics() {
  local download_bps="$1"
  local upload_bps="$2"
  local ping_ms="$3"
  local jitter_ms="${4:-0}"
  local packet_loss="${5:-0}"

  cat > "$TMP_FILE" <<EOF
custom_speedtest_available{host="${HOSTNAME_FQDN}",provider="${PROVIDER}"} 1
custom_speedtest_success{host="${HOSTNAME_FQDN}",provider="${PROVIDER}"} 1
custom_speedtest_download_bits_per_second{host="${HOSTNAME_FQDN}",provider="${PROVIDER}"} ${download_bps}
custom_speedtest_upload_bits_per_second{host="${HOSTNAME_FQDN}",provider="${PROVIDER}"} ${upload_bps}
custom_speedtest_ping_latency_milliseconds{host="${HOSTNAME_FQDN}",provider="${PROVIDER}"} ${ping_ms}
custom_speedtest_jitter_latency_milliseconds{host="${HOSTNAME_FQDN}",provider="${PROVIDER}"} ${jitter_ms}
custom_speedtest_packet_loss_percent{host="${HOSTNAME_FQDN}",provider="${PROVIDER}"} ${packet_loss}
custom_speedtest_last_run_timestamp_seconds{host="${HOSTNAME_FQDN}",provider="${PROVIDER}"} ${TIMESTAMP}
EOF
  mv "$TMP_FILE" "$OUT_FILE"
}

parse_yandex_mbps() {
  local label="$1"
  tr '\r' '\n' | sed -nE "s/.*${label}[[:space:]]*:[[:space:]]*([0-9]+([.][0-9]+)?).*/\\1/p" | tail -n1
}

parse_yandex_ping() {
  tr '\r' '\n' | sed -nE "s/.*Пинг:[[:space:]]*([0-9]+([.][0-9]+)?).*/\\1/p" | tail -n1
}

parse_yandex_jitter() {
  tr '\r' '\n' | sed -nE "s/.*jitter:[[:space:]]*([0-9]+([.][0-9]+)?).*/\\1/p" | tail -n1
}

run_yandex_speedtest() {
  local result download_mbps upload_mbps ping_ms jitter_ms

  result="$(timeout 360 bash -o pipefail -c "curl -fsSL '${YANDEX_SPEEDTEST_URL}' | python3" 2>/tmp/speedtest_metrics_error.log || true)"

  download_mbps="$(printf '%s\n' "$result" | parse_yandex_mbps "Входящая")"
  upload_mbps="$(printf '%s\n' "$result" | parse_yandex_mbps "Исходящая")"
  ping_ms="$(printf '%s\n' "$result" | parse_yandex_ping)"
  jitter_ms="$(printf '%s\n' "$result" | parse_yandex_jitter)"

  if [[ ! "$download_mbps" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
     [[ ! "$upload_mbps" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
     [[ ! "$ping_ms" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    write_failure_metrics
    exit 0
  fi

  if [[ ! "$jitter_ms" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    jitter_ms="0"
  fi

  write_success_metrics \
    "$(awk -v value="$download_mbps" 'BEGIN { printf "%.0f", value * 1000000 }')" \
    "$(awk -v value="$upload_mbps" 'BEGIN { printf "%.0f", value * 1000000 }')" \
    "$ping_ms" \
    "$jitter_ms" \
    "0"
}

run_ookla_speedtest() {
  local result download_bps upload_bps ping_ms jitter_ms packet_loss

  result="$(timeout 300 speedtest --accept-license --accept-gdpr --format=json 2>/tmp/speedtest_metrics_error.log || true)"

  if [[ -z "$result" ]] || ! echo "$result" | jq -e '.type == "result"' >/dev/null 2>&1; then
    write_failure_metrics
    exit 0
  fi

  download_bps="$(echo "$result" | jq -r '.download.bandwidth * 8')"
  upload_bps="$(echo "$result" | jq -r '.upload.bandwidth * 8')"
  ping_ms="$(echo "$result" | jq -r '.ping.latency')"
  jitter_ms="$(echo "$result" | jq -r '.ping.jitter')"
  packet_loss="$(echo "$result" | jq -r '.packetLoss // 0')"

  write_success_metrics "$download_bps" "$upload_bps" "$ping_ms" "$jitter_ms" "$packet_loss"
}

case "$PROVIDER" in
  ookla)
    run_ookla_speedtest
    ;;
  yandex)
    run_yandex_speedtest
    ;;
  *)
    write_failure_metrics
    ;;
esac

exit 0
