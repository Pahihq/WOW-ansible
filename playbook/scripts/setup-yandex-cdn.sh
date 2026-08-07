#!/usr/bin/env bash
set -Eeuo pipefail

CF_API="https://api.cloudflare.com/client/v4"
CDN_API="https://cdn.api.cloud.yandex.net/cdn/v1"
OP_API="https://operation.api.cloud.yandex.net/operations"
CONFIG_PATH="${YANDEX_CONFIG_PATH:-$PWD/.env}"
CDN_DOMAIN="" ORIGIN="" CERT_NAME="${YANDEX_CERTIFICATE_NAME:-wowsecure}"
STATE_ONLY=false DRY_RUN=false TMP_DIR="" IAM_TOKEN="" FOLDER_ID=""
HTTP_CODE="" HTTP_BODY=""

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die() { printf '[%s] ОШИБКА: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }
cleanup() { [[ -z "$TMP_DIR" ]] || rm -rf -- "$TMP_DIR"; }
normalize() { local v=${1#http://}; v=${v#https://}; v=${v%%/*}; printf '%s' "${v%.}" | tr '[:upper:]' '[:lower:]'; }

usage() {
  cat <<'EOF'
setup-yandex-cdn.sh --cdn DOMAIN --origin HOST [--certificate-name NAME] [--dry-run]
setup-yandex-cdn.sh --cdn DOMAIN --state

Порядок: поиск wowsecure -> проверка wildcard SAN/ISSUED -> CNAME -> CDN resource.
Новый сертификат не создаётся; DNS challenge нужен только если найденный сертификат ещё не ISSUED.
Требуются yc, curl, jq, авторизованный профиль yc, Cloudflare token и account ID.
EOF
}

yc_cmd() {
  local -a a=(yc)
  [[ -z "${YANDEX_CLI_PROFILE:-}" ]] || a+=(--profile "$YANDEX_CLI_PROFILE")
  "${a[@]}" "$@"
}

request() {
  local method=$1 url=$2 auth=$3 data=${4:-} out="$TMP_DIR/http.json"
  local -a a=(--silent --show-error --request "$method" --output "$out" --write-out '%{http_code}'
    --connect-timeout 20 --max-time 120 --header 'Accept: application/json')
  case "$auth" in
    yc) a+=(--header "Authorization: Bearer $IAM_TOKEN") ;;
    cf) a+=(--header "Authorization: Bearer $CLOUDFLARE_API_TOKEN") ;;
  esac
  [[ -z "$data" ]] || a+=(--header 'Content-Type: application/json' --data "$data")
  HTTP_CODE=$(curl "${a[@]}" "$url") || die "Сетевая ошибка: $url"
  HTTP_BODY=$(<"$out")
}

expect() {
  [[ "$HTTP_CODE" == "$1" ]] || die "$2: HTTP $HTTP_CODE: $(jq -r '.message // .errors[0].message // tostring' <<<"$HTTP_BODY")"
}

cf_expect() {
  expect 200 "$1"
  [[ $(jq -r '.success // false' <<<"$HTTP_BODY") == true ]] || die "$1: API success=false"
}

find_zone() {
  local name=${1%.}
  request GET "$CF_API/zones?account.id=$CLOUDFLARE_ACCOUNT_ID&per_page=50" cf
  cf_expect "Получение зон Cloudflare"
  local z
  z=$(jq -c --arg n "$name" '[.result[] | select(.name as $z | $n == $z or ($n | endswith("."+$z)))] | sort_by(.name|length) | last // empty' <<<"$HTTP_BODY")
  [[ -n "$z" ]] || die "Не найдена DNS-зона для $name"
  printf '%s' "$z"
}

upsert_dns() {
  local type=$1 name=${2%.} value=${3%.} comment=$4 zone zone_id records payload id
  zone=$(find_zone "$name"); zone_id=$(jq -r '.id' <<<"$zone")
  request GET "$CF_API/zones/$zone_id/dns_records?name=$name" cf; cf_expect "Чтение DNS $name"
  records=$(jq -c '.result' <<<"$HTTP_BODY")
  [[ $(jq 'length' <<<"$records") -le 1 ]] || die "Несколько DNS-записей для $name"
  payload=$(jq -cn --arg t "$type" --arg n "$name" --arg v "$value" --arg c "$comment" '{type:$t,name:$n,content:$v,ttl:300,proxied:false,comment:$c}')
  if [[ $(jq 'length' <<<"$records") == 0 ]]; then
    $DRY_RUN && { log "DRY-RUN DNS: $type $name -> $value"; return; }
    request POST "$CF_API/zones/$zone_id/dns_records" cf "$payload"; cf_expect "Создание DNS $name"
    log "Создана DNS-запись $type $name -> $value"
  else
    [[ $(jq -r '.[0].type' <<<"$records") == "$type" ]] || die "$name занят другим типом записи"
    if [[ $(normalize "$(jq -r '.[0].content' <<<"$records")") == "$(normalize "$value")" && $(jq -r '.[0].proxied // false' <<<"$records") == false ]]; then
      log "DNS-запись $name уже настроена"; return
    fi
    $DRY_RUN && { log "DRY-RUN DNS update: $type $name -> $value"; return; }
    id=$(jq -r '.[0].id' <<<"$records")
    request PUT "$CF_API/zones/$zone_id/dns_records/$id" cf "$payload"; cf_expect "Обновление DNS $name"
    log "Обновлена DNS-запись $type $name -> $value"
  fi
}

wait_op() {
  local id=$1 started=$SECONDS
  while true; do
    request GET "$OP_API/$id" yc; expect 200 "Операция $id"
    if [[ $(jq -r '.done // false' <<<"$HTTP_BODY") == true ]]; then
      jq -e 'has("error") | not' <<<"$HTTP_BODY" >/dev/null || die "Операция: $(jq -r '.error.message' <<<"$HTTP_BODY")"
      return
    fi
    ((SECONDS-started < 900)) || die "Операция $id не завершилась"
    sleep 5
  done
}

find_cert() {
  yc_cmd certificate-manager certificate list --folder-id "$FOLDER_ID" --format json |
    jq -c --arg n "$CERT_NAME" '[.[] | select(.name==$n)] | .[0] // empty'
}

certificate_covers_domain() {
  local cert=$1 domain=$2 san suffix prefix
  while IFS= read -r san; do
    san=$(normalize "$san")
    if [[ "$san" == "$domain" ]]; then
      return 0
    fi
    if [[ "$san" == \*.* ]]; then
      suffix=${san#*.}
      if [[ "$domain" == *".$suffix" ]]; then
        prefix=${domain%."$suffix"}
        [[ -n "$prefix" && "$prefix" != *.* ]] && return 0
      fi
    fi
  done < <(jq -r '.domains[]?' <<<"$cert")
  return 1
}

ensure_cert() {
  local cert id status started
  cert=$(find_cert)
  if [[ -z "$cert" ]]; then
    die "Сертификат $CERT_NAME не найден. Создайте управляемый wildcard-сертификат для DNS-зон CDN"
  fi
  id=$(jq -r '.id' <<<"$cert")
  certificate_covers_domain "$cert" "$CDN_DOMAIN" ||
    die "Сертификат $CERT_NAME не покрывает домен $CDN_DOMAIN"
  cert=$(yc_cmd certificate-manager certificate get --id "$id" --full --format json)
  status=$(jq -r '.status' <<<"$cert")
  if [[ "$status" != ISSUED ]]; then
    started=$SECONDS
    while [[ $(jq '[.challenges[]? | select(.dns_challenge != null)] | length' <<<"$cert") == 0 ]]; do
      ((SECONDS-started < 120)) || die "Certificate Manager не вернул DNS challenge"
      sleep 5
      cert=$(yc_cmd certificate-manager certificate get --id "$id" --full --format json)
    done
    while IFS=$'\t' read -r t n v; do
      upsert_dns "$t" "$n" "$v" "Yandex Certificate Manager validation; keep for renewal"
    done < <(jq -r '.challenges[] | select(.dns_challenge != null) | [.dns_challenge.type,.dns_challenge.name,.dns_challenge.value] | @tsv' <<<"$cert")
    started=$SECONDS
    while [[ "$status" != ISSUED ]]; do
      [[ "$status" != INVALID && "$status" != REVOKED ]] || die "Сертификат: $status"
      ((SECONDS-started < 1800)) || die "Сертификат не выпущен за 30 минут"
      sleep 15
      cert=$(yc_cmd certificate-manager certificate get --id "$id" --full --format json)
      status=$(jq -r '.status' <<<"$cert")
      log "Сертификат $CERT_NAME: $status"
    done
  fi
  log "Сертификат $CERT_NAME покрывает $CDN_DOMAIN и имеет статус ISSUED"
  printf '%s' "$id"
}

find_resource() {
  request GET "$CDN_API/resources?folderId=$FOLDER_ID&pageSize=1000" yc; expect 200 "Список CDN"
  jq -c --arg c "$CDN_DOMAIN" '[.resources[]? | select((.cname|ascii_downcase)==$c)] | .[0] // empty' <<<"$HTTP_BODY"
}

create_resource() {
  local cert=$1 payload op
  payload=$(jq -cn --arg f "$FOLDER_ID" --arg c "$CDN_DOMAIN" --arg o "$ORIGIN" --arg cert "$cert" '{
    folderId:$f,cname:$c,origin:{originSource:$o},originProtocol:"HTTPS",active:true,
    options:{disableCache:{enabled:true,value:true},browserCacheSettings:{enabled:false},
      queryParamsOptions:{ignoreQueryString:{enabled:true,value:true}},slice:{enabled:false,value:false},
      compressionOptions:{gzipOn:{enabled:false,value:false}},redirectOptions:{redirectHttpToHttps:{enabled:true,value:true}},
      hostOptions:{forwardHostHeader:{enabled:true,value:true}},cors:{enabled:false},
      allowedHttpMethods:{enabled:true,value:["HEAD","GET","OPTIONS"]},ignoreCookie:{enabled:true,value:true},
      rewrite:{enabled:false},secureKey:{enabled:false},ipAddressAcl:{enabled:false},followRedirects:{enabled:false},staticResponse:{enabled:false}},
    sslCertificate:{type:"CM",data:{cm:{id:$cert}}},providerType:"ourcdn",tls:{profile:"PROFILE_SECURE"}}')
  $DRY_RUN && { jq . <<<"$payload" >&2; return; }
  request POST "$CDN_API/resources" yc "$payload"; expect 200 "Создание CDN"
  op=$(jq -r '.id' <<<"$HTTP_BODY"); wait_op "$op"; log "CDN-ресурс создан"
}

state() {
  local r cert status
  r=$(find_resource); [[ -n "$r" ]] || { printf '{"found":false}\n'; return; }
  cert=$(jq -r '.sslCertificate.data.cm.id // empty' <<<"$r")
  status=$(yc_cmd certificate-manager certificate get --id "$cert" --format json | jq -r '.status')
  jq -cn --argjson r "$r" --arg cs "$status" '{found:true,id:$r.id,status:(if $r.active then "active" else "disabled" end),active:$r.active,sslEnabled:($cs=="ISSUED"),certificateId:($r.sslCertificate.data.cm.id//""),certificateStatus:$cs}'
}

main() {
  [[ ! -f "$CONFIG_PATH" ]] || { set -a; source "$CONFIG_PATH"; set +a; }
  CERT_NAME=${YANDEX_CERTIFICATE_NAME:-$CERT_NAME}
  while (($#)); do case "$1" in
    --cdn) CDN_DOMAIN=$2; shift 2;; --origin) ORIGIN=$2; shift 2;;
    --certificate-name) CERT_NAME=$2; shift 2;; --state) STATE_ONLY=true; shift;;
    --dry-run) DRY_RUN=true; shift;; -h|--help) usage; exit;; *) die "Неизвестный параметр $1";; esac; done
  CDN_DOMAIN=$(normalize "$CDN_DOMAIN"); ORIGIN=$(normalize "$ORIGIN")
  [[ -n "$CDN_DOMAIN" ]] || die "Нужен --cdn"
  $STATE_ONLY || [[ -n "$ORIGIN" ]] || die "Нужен --origin"
  command -v yc >/dev/null && command -v jq >/dev/null && command -v curl >/dev/null || die "Нужны yc, jq, curl"
  FOLDER_ID=${YANDEX_FOLDER_ID:-$(yc_cmd config get folder-id 2>/dev/null || true)}
  [[ -n "$FOLDER_ID" ]] || die "Не задан YANDEX_FOLDER_ID/folder-id"
  IAM_TOKEN=$(yc_cmd iam create-token); TMP_DIR=$(mktemp -d); trap cleanup EXIT
  $STATE_ONLY && { state; return; }
  : "${CLOUDFLARE_ACCOUNT_ID:?}" "${CLOUDFLARE_API_TOKEN:?}"
  local cert target resource
  cert=$(ensure_cert)
  target=$(yc_cmd cdn resource get-provider-cname --folder-id "$FOLDER_ID" --format json | jq -r '.cname')
  upsert_dns CNAME "$CDN_DOMAIN" "$target" "Yandex Cloud CDN, managed by Ansible"
  resource=$(find_resource)
  [[ -n "$resource" ]] || create_resource "$cert"
  log "Готово: $CDN_DOMAIN -> Yandex CDN -> $ORIGIN"
}
main "$@"
