#!/usr/bin/env bash
set -Eeuo pipefail

CF_API_BASE="https://api.cloudflare.com/client/v4"
CONFIG_PATH="${VKCS_CONFIG_PATH:-$PWD/.env}"

CDN_DOMAIN=""
ORIGIN=""
DRY_RUN=false

LAST_HTTP_CODE=""
LAST_HTTP_BODY=""
TMP_DIR=""

usage() {
  cat <<'EOF'
Создаёт CDN-ресурс VK Cloud, CNAME в Cloudflare и сертификат Let's Encrypt.

Использование:
  setup-cdn.sh --cdn CDN_DOMAIN --origin ORIGIN [--dry-run]

Обязательные параметры:
  --cdn DOMAIN              Пользовательский CDN-домен, например cdn.example.ru
  --origin HOST[:PORT]      Единственный сервер-источник

Дополнительный параметр:
  --dry-run                 Выполнять только проверки и показать план изменений
  -h, --help                Показать справку

Origin-протокол всегда MATCH. CNAME и Let's Encrypt настраиваются автоматически.

Переменные окружения:
  VKCS_CONFIG_PATH          Путь к .env (по умолчанию .env в текущем каталоге)
  VKCS_OPENRC_FILE          Путь к OpenStack RC file v3
  OS_PASSWORD               Пароль OpenStack (обязательно задаётся в .env)
  CLOUDFLARE_ACCOUNT_ID     ID аккаунта Cloudflare
  CLOUDFLARE_API_TOKEN      Account-owned API token Cloudflare

Разрешения Cloudflare:
  Zone Read и DNS Write для управляемых DNS-зон.
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2
}

warn() {
  printf '[%s] ПРЕДУПРЕЖДЕНИЕ: %s\n' "$(date '+%H:%M:%S')" "$*" >&2
}

die() {
  printf '[%s] ОШИБКА: %s\n' "$(date '+%H:%M:%S')" "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Не найдена команда: $1"
}

require_env() {
  local name=$1
  [[ -n "${!name:-}" ]] || die "Не задана переменная окружения $name"
}

load_saved_config() {
  if [[ -f "$CONFIG_PATH" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$CONFIG_PATH"
    set +a
    log "Настройки загружены из $CONFIG_PATH"
  fi
}

normalize_domain() {
  local value=$1
  value=${value#http://}
  value=${value#https://}
  value=${value%%/*}
  value=${value%.}
  printf '%s' "${value,,}"
}

load_openrc() {
  if [[ -n "${OS_AUTH_URL:-}" &&
    -n "${OS_PROJECT_ID:-}" &&
    -n "${OS_USERNAME:-}" &&
    (-n "${OS_USER_DOMAIN_ID:-}" || -n "${OS_USER_DOMAIN_NAME:-}") &&
    -n "${OS_PASSWORD:-}" ]]; then
    log "Использую сохранённые параметры OpenStack из $CONFIG_PATH"
    return
  fi

  require_env VKCS_OPENRC_FILE
  require_env OS_PASSWORD
  [[ -f "$VKCS_OPENRC_FILE" ]] || die "OpenStack RC file не найден: $VKCS_OPENRC_FILE"

  log "Загружаю OpenStack RC file: $VKCS_OPENRC_FILE"
  set +u
  # shellcheck disable=SC1090
  # Horizon RC-файлы могут безусловно запрашивать пароль через read. Передаём
  # сохранённый OS_PASSWORD на stdin, чтобы запуск оставался неинтерактивным.
  source "$VKCS_OPENRC_FILE" <<<"$OS_PASSWORD" >/dev/null
  set -u

  require_env OS_AUTH_URL
  require_env OS_PROJECT_ID
  require_env OS_USERNAME
  require_env OS_PASSWORD
  [[ -n "${OS_USER_DOMAIN_ID:-}" || -n "${OS_USER_DOMAIN_NAME:-}" ]] ||
    die "Не задан OS_USER_DOMAIN_ID или OS_USER_DOMAIN_NAME"
}

validate_inputs() {
  CDN_DOMAIN=$(normalize_domain "$CDN_DOMAIN")
  ORIGIN=$(normalize_domain "$ORIGIN")

  [[ "$CDN_DOMAIN" != *"*"* ]] || die "Wildcard-домены несовместимы с Let's Encrypt в VK Cloud"
  [[ "$CDN_DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] ||
    die "CDN-домен должен быть передан в ASCII/Punycode без пути"
  [[ "$CDN_DOMAIN" == *.* ]] || die "CDN-домен должен быть полным доменным именем"
  [[ "$ORIGIN" != *"@"* ]] || die "Origin не должен содержать логин или пароль"

  require_env OS_AUTH_URL
  require_env OS_PROJECT_ID
  require_env OS_USERNAME
  require_env OS_PASSWORD
  require_env CLOUDFLARE_ACCOUNT_ID
  require_env CLOUDFLARE_API_TOKEN
}

authenticate_vk() {
  local auth_url="${OS_AUTH_URL%/}/auth/tokens"
  local body_file="$TMP_DIR/keystone-token.json"
  local headers_file="$TMP_DIR/keystone-token.headers"
  local user_domain endpoint http_code
  local payload

  if [[ -n "${OS_USER_DOMAIN_ID:-}" ]]; then
    user_domain=$(jq -cn --arg id "$OS_USER_DOMAIN_ID" '{id: $id}')
  else
    user_domain=$(jq -cn --arg name "${OS_USER_DOMAIN_NAME:-Default}" '{name: $name}')
  fi

  payload=$(jq -cn \
    --arg username "$OS_USERNAME" \
    --arg password "$OS_PASSWORD" \
    --arg project_id "$OS_PROJECT_ID" \
    --argjson user_domain "$user_domain" \
    '{
      auth: {
        identity: {
          methods: ["password"],
          password: {
            user: {
              name: $username,
              password: $password,
              domain: $user_domain
            }
          }
        },
        scope: {project: {id: $project_id}}
      }
    }')

  log "Получаю временный токен и каталог сервисов VK Cloud"
  http_code=$(curl \
    --silent \
    --show-error \
    --request POST \
    --output "$body_file" \
    --dump-header "$headers_file" \
    --write-out '%{http_code}' \
    --connect-timeout 20 \
    --max-time 120 \
    --header 'Accept: application/json' \
    --header 'Content-Type: application/json' \
    --data "$payload" \
    "$auth_url") || die "Сетевая ошибка при аутентификации VK Cloud"

  LAST_HTTP_CODE=$http_code
  LAST_HTTP_BODY=$(<"$body_file")
  expect_http 201 "Аутентификация VK Cloud через OpenStack RC"

  VKCS_TOKEN=$(awk 'BEGIN {IGNORECASE=1} /^X-Subject-Token:/ {sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print}' "$headers_file" | tail -n1)
  [[ -n "$VKCS_TOKEN" ]] || die "Keystone не вернул X-Subject-Token"

  endpoint=$(jq -r \
    --arg interface "${OS_INTERFACE:-public}" \
    --arg region "${OS_REGION_NAME:-}" '
      [
        .token.catalog[]?
        | select(.type == "cdn")
        | .endpoints[]?
        | select(.interface == $interface)
        | select($region == "" or .region == $region or .region_id == $region)
        | .url
      ][0] // empty
    ' "$body_file")

  if [[ -z "$endpoint" ]]; then
    endpoint=$(jq -r \
      --arg interface "${OS_INTERFACE:-public}" '
        [.token.catalog[]? | select(.type == "cdn") | .endpoints[]? | select(.interface == $interface) | .url][0] // empty
      ' "$body_file")
  fi

  [[ -n "$endpoint" ]] || die "В каталоге Keystone не найден public endpoint сервиса cdn; проверьте, что CDN подключён к проекту"
  VKCS_CDN_API_BASE=${endpoint%/}
  VKCS_PROJECT_ID=$OS_PROJECT_ID
  log "CDN API найден в каталоге VK Cloud: $VKCS_CDN_API_BASE"
}

http_request() {
  local method=$1
  local url=$2
  local auth=$3
  local data=${4:-}
  local body_file="$TMP_DIR/response.json"
  local -a args

  args=(
    --silent
    --show-error
    --location
    --request "$method"
    --output "$body_file"
    --write-out '%{http_code}'
    --connect-timeout 20
    --max-time 120
    --header 'Accept: application/json'
  )

  case "$auth" in
    vk)
      args+=(--header "X-Auth-Token: $VKCS_TOKEN")
      ;;
    cloudflare)
      args+=(--header "Authorization: Bearer $CLOUDFLARE_API_TOKEN")
      ;;
    *)
      die "Неизвестный тип авторизации: $auth"
      ;;
  esac

  if [[ -n "$data" ]]; then
    args+=(
      --header 'Content-Type: application/json'
      --data "$data"
    )
  fi

  LAST_HTTP_CODE=$(curl "${args[@]}" "$url") ||
    die "Сетевая ошибка при обращении к $url"
  LAST_HTTP_BODY=$(<"$body_file")
}

describe_error() {
  local body=$1
  local parsed
  parsed=$(jq -r '
    if (.errors? | type) == "array" and (.errors | length) > 0 then
      [.errors[] | (.message // tostring)] | join("; ")
    elif .error? then
      (.error | if type == "string" then . else tostring end)
    elif .detail? then
      (.detail | if type == "string" then . else tostring end)
    elif .message? then
      (.message | if type == "string" then . else tostring end)
    else
      empty
    end
  ' <<<"$body" 2>/dev/null || true)

  if [[ -n "$parsed" ]]; then
    printf '%s' "$parsed"
  else
    printf '%s' "${body:0:800}"
  fi
}

expect_http() {
  local expected=$1
  local action=$2
  if [[ "$LAST_HTTP_CODE" != "$expected" ]]; then
    die "$action: HTTP $LAST_HTTP_CODE: $(describe_error "$LAST_HTTP_BODY")"
  fi
}

expect_cloudflare_success() {
  local action=$1
  expect_http 200 "$action"
  if [[ $(jq -r '.success // false' <<<"$LAST_HTTP_BODY") != "true" ]]; then
    die "$action: $(describe_error "$LAST_HTTP_BODY")"
  fi
}

verify_cloudflare_token() {
  log "Проверяю account-owned token Cloudflare"
  http_request GET \
    "$CF_API_BASE/accounts/$CLOUDFLARE_ACCOUNT_ID/tokens/verify" \
    cloudflare
  expect_cloudflare_success "Проверка токена Cloudflare"

  local status
  status=$(jq -r '.result.status // empty' <<<"$LAST_HTTP_BODY")
  [[ "$status" == "active" ]] || die "Токен Cloudflare имеет состояние: ${status:-неизвестно}"
}

get_vk_technical_cname() {
  http_request GET \
    "$VKCS_CDN_API_BASE/projects/$VKCS_PROJECT_ID/clients/me" \
    vk
  expect_http 200 "Получение технического CNAME VK Cloud"

  local cname
  cname=$(jq -r '.cname // empty' <<<"$LAST_HTTP_BODY")
  [[ -n "$cname" ]] || die "VK Cloud не вернул поле cname для аккаунта"
  normalize_domain "$cname"
}

find_cloudflare_zone() {
  local page=1
  local total_pages=1
  local all_zones='[]'

  log "Ищу DNS-зону Cloudflare для $CDN_DOMAIN"
  while ((page <= total_pages)); do
    http_request GET \
      "$CF_API_BASE/zones?account.id=$CLOUDFLARE_ACCOUNT_ID&per_page=50&page=$page" \
      cloudflare
    expect_cloudflare_success "Получение DNS-зон Cloudflare"

    all_zones=$(jq -cn \
      --argjson existing "$all_zones" \
      --argjson response "$LAST_HTTP_BODY" \
      '$existing + ($response.result // [])')
    total_pages=$(jq -r '.result_info.total_pages // 1' <<<"$LAST_HTTP_BODY")
    ((page += 1))
  done

  local match
  match=$(jq -c --arg domain "$CDN_DOMAIN" '
    [
      .[]
      | select(
          .name as $zone
          | $domain == $zone or ($domain | endswith("." + $zone))
        )
    ]
    | sort_by(.name | length)
    | last // empty
  ' <<<"$all_zones")

  [[ -n "$match" ]] || die "В аккаунте Cloudflare не найдена зона для $CDN_DOMAIN"
  printf '%s' "$match"
}

find_vk_resource() {
  http_request GET \
    "$VKCS_CDN_API_BASE/projects/$VKCS_PROJECT_ID/resources" \
    vk
  expect_http 200 "Получение CDN-ресурсов VK Cloud"

  local matches
  matches=$(jq -c --arg cname "$CDN_DOMAIN" '
    [
      .[]
      | select(((.cname // "") | ascii_downcase) == $cname)
    ]
  ' <<<"$LAST_HTTP_BODY")

  local count
  count=$(jq 'length' <<<"$matches")
  ((count <= 1)) || die "VK Cloud вернул несколько ресурсов с CNAME $CDN_DOMAIN"
  if ((count == 1)); then
    jq -c '.[0]' <<<"$matches"
  fi
}

ensure_vk_origin_group() {
  http_request GET \
    "$VKCS_CDN_API_BASE/projects/$VKCS_PROJECT_ID/originGroups" \
    vk
  expect_http 200 "Получение групп источников VK Cloud"

  local matches count
  matches=$(jq -c --arg origin "$ORIGIN" '
    def normalize_source:
      ascii_downcase
      | sub("^https?://"; "")
      | split("/")[0]
      | sub("\\.$"; "");
    [
      .[]
      | select(((.origins // []) | length) == 1)
      | select(((.origins[0].source // "") | normalize_source) == $origin)
      | select((.origins[0].backup // false) == false)
      | select((.origins[0].enabled // true) == true)
    ]
  ' <<<"$LAST_HTTP_BODY")

  count=$(jq 'length' <<<"$matches")
  ((count <= 1)) ||
    die "Найдено несколько подходящих origin group для $ORIGIN; автоматический выбор небезопасен"

  if ((count == 1)); then
    local existing_id
    existing_id=$(jq -r '.[0].id' <<<"$matches")
    log "Использую существующую origin group: ID $existing_id"
    printf '%s' "$existing_id"
    return
  fi

  local payload
  payload=$(jq -cn \
    --arg name "${CDN_DOMAIN}_${ORIGIN}" \
    --arg origin "$ORIGIN" '
    {
      name: $name,
      useNext: false,
      origins: [
        {
          source: $origin,
          enabled: true,
          backup: false
        }
      ]
    }')

  if $DRY_RUN; then
    log "DRY-RUN: будет создана origin group:"
    jq . <<<"$payload" >&2
    printf '0'
    return
  fi

  log "Создаю origin group для $ORIGIN"
  http_request POST \
    "$VKCS_CDN_API_BASE/projects/$VKCS_PROJECT_ID/originGroups" \
    vk \
    "$payload"
  expect_http 201 "Создание origin group VK Cloud"

  local created_id
  created_id=$(jq -r '.id // empty' <<<"$LAST_HTTP_BODY")
  [[ -n "$created_id" ]] || die "VK Cloud не вернул ID созданной origin group"
  printf '%s' "$created_id"
}

verify_existing_vk_resource() {
  local resource=$1
  local resource_id origin_group_id group group_origin

  resource_id=$(jq -r '.id // empty' <<<"$resource")
  origin_group_id=$(jq -r '.originGroup // empty' <<<"$resource")
  [[ -n "$origin_group_id" ]] ||
    die "У существующего ресурса $resource_id не указан originGroup; безопасная проверка невозможна"

  local protocol active enabled methods_ok host_forward_ok extra_enabled
  protocol=$(jq -r '.originProtocol // empty' <<<"$resource")
  active=$(jq -r '.active // false' <<<"$resource")
  enabled=$(jq -r '.enabled // false' <<<"$resource")
  methods_ok=$(jq -r '
    (.options.allowedHttpMethods // .options.allowed_http_methods // {}) as $methods
    | ($methods.enabled // false) == true
      and (($methods.value // []) | sort == ["GET", "HEAD"])
  ' <<<"$resource")
  host_forward_ok=$(jq -r '
    (.options.forward_host_header.enabled // false) == true
    and (.options.forward_host_header.value // false) == true
  ' <<<"$resource")
  extra_enabled=$(jq -r '
    [
      (.options // {})
      | to_entries[]
      | select(
          .key != "allowedHttpMethods"
          and .key != "allowed_http_methods"
          and .key != "forward_host_header"
        )
      | select((.value | type) == "object" and (.value.enabled // false) == true)
      | .key
    ]
    | join(",")
  ' <<<"$resource")

  [[ "$protocol" == "MATCH" ]] ||
    die "Ресурс $resource_id использует originProtocol=$protocol, ожидался MATCH"
  [[ "$active" == "true" && "$enabled" == "true" ]] ||
    die "У существующего ресурса $resource_id отключён доступ к контенту"
  [[ "$methods_ok" == "true" ]] ||
    die "HTTP-методы ресурса $resource_id не совпадают с GET/HEAD"
  [[ "$host_forward_ok" == "true" ]] ||
    die "У ресурса $resource_id не включена пересылка исходного Host"
  [[ -z "$extra_enabled" ]] ||
    die "У ресурса $resource_id включены дополнительные опции: $extra_enabled"

  http_request GET \
    "$VKCS_CDN_API_BASE/projects/$VKCS_PROJECT_ID/originGroups/$origin_group_id" \
    vk
  expect_http 200 "Получение группы источников $origin_group_id"
  group=$LAST_HTTP_BODY

  local origin_count
  origin_count=$(jq '(.origins // []) | length' <<<"$group")
  ((origin_count == 1)) ||
    die "В группе $origin_group_id найдено источников: $origin_count, ожидался один"

  group_origin=$(normalize_domain "$(jq -r '.origins[0].source // empty' <<<"$group")")
  [[ "$group_origin" == "$ORIGIN" ]] ||
    die "Origin существующего ресурса — $group_origin, ожидался $ORIGIN"
}

create_vk_resource() {
  local origin_group_id=$1
  local payload
  payload=$(jq -cn \
    --arg cname "$CDN_DOMAIN" \
    --argjson origin_group "$origin_group_id" \
    '{
      cname: $cname,
      secondaryHostnames: [],
      originGroup: $origin_group,
      originProtocol: "MATCH",
      active: true,
      enabled: true,
      sslEnabled: false,
      options: {
        allowedHttpMethods: {
          enabled: true,
          value: ["GET", "HEAD"]
        },
        forward_host_header: {
          enabled: true,
          value: true
        }
      }
    }')

  if $DRY_RUN; then
    log "DRY-RUN: будет создан CDN-ресурс:"
    jq . <<<"$payload" >&2
    return
  fi

  log "Создаю CDN-ресурс $CDN_DOMAIN → origin group $origin_group_id"
  http_request POST \
    "$VKCS_CDN_API_BASE/projects/$VKCS_PROJECT_ID/resources" \
    vk \
    "$payload"
  expect_http 200 "Создание CDN-ресурса"
  printf '%s' "$LAST_HTTP_BODY"
}

get_vk_resource() {
  local resource_id=$1
  http_request GET \
    "$VKCS_CDN_API_BASE/projects/$VKCS_PROJECT_ID/resources/$resource_id" \
    vk
  expect_http 200 "Получение CDN-ресурса $resource_id"
  printf '%s' "$LAST_HTTP_BODY"
}

wait_for_lets_encrypt() {
  local resource_id=$1
  local started=$SECONDS

  while true; do
    local resource
    resource=$(get_vk_resource "$resource_id")
    local status
    status=$(jq -r '.status // empty' <<<"$resource")

    local ssl_enabled ssl_automated
    ssl_enabled=$(jq -r '.sslEnabled // false' <<<"$resource")
    ssl_automated=$(jq -r '.ssl_automated // false' <<<"$resource")
    if [[ "$ssl_enabled" == "true" && "$ssl_automated" == "true" ]]; then
      return
    fi

    [[ "$status" != "suspended" ]] ||
      die "CDN-ресурс $resource_id перешёл в состояние suspended"
    ((SECONDS - started < 1800)) ||
      die "Истекло время ожидания Let's Encrypt для CDN-ресурса $resource_id"

    log "CDN-ресурс $resource_id: status=${status:-unknown}, ожидаю SSL"
    sleep 15
  done
}

upsert_cloudflare_cname() {
  local zone_id=$1
  local target=$2

  http_request GET \
    "$CF_API_BASE/zones/$zone_id/dns_records?name=$CDN_DOMAIN&per_page=100" \
    cloudflare
  expect_cloudflare_success "Проверка DNS-записи $CDN_DOMAIN"

  local records count
  records=$(jq -c '.result // []' <<<"$LAST_HTTP_BODY")
  count=$(jq 'length' <<<"$records")
  ((count <= 1)) ||
    die "Для $CDN_DOMAIN найдено несколько DNS-записей; автоматическое изменение остановлено"

  local payload
  payload=$(jq -cn \
    --arg name "$CDN_DOMAIN" \
    --arg content "$target" \
    '{
      type: "CNAME",
      name: $name,
      content: $content,
      ttl: 1,
      proxied: false,
      comment: "VK Cloud CDN, managed automatically"
    }')

  if ((count == 0)); then
    if $DRY_RUN; then
      log "DRY-RUN: будет создана DNS-запись:"
      jq . <<<"$payload"
      return
    fi

    log "Создаю CNAME $CDN_DOMAIN → $target в Cloudflare"
    http_request POST \
      "$CF_API_BASE/zones/$zone_id/dns_records" \
      cloudflare \
      "$payload"
    expect_cloudflare_success "Создание CNAME $CDN_DOMAIN"
    return
  fi

  local record_type record_id current_target current_proxied
  record_type=$(jq -r '.[0].type' <<<"$records")
  record_id=$(jq -r '.[0].id' <<<"$records")
  current_target=$(normalize_domain "$(jq -r '.[0].content // empty' <<<"$records")")
  current_proxied=$(jq -r '.[0].proxied // false' <<<"$records")

  [[ "$record_type" == "CNAME" ]] ||
    die "$CDN_DOMAIN уже занят записью типа $record_type; запись не изменена"

  if [[ "$current_target" == "$target" && "$current_proxied" == "false" ]]; then
    log "CNAME в Cloudflare уже настроен правильно"
    return
  fi

  if $DRY_RUN; then
    log "DRY-RUN: CNAME $record_id будет обновлён:"
    jq . <<<"$payload"
    return
  fi

  log "Обновляю CNAME $CDN_DOMAIN → $target и отключаю Cloudflare Proxy"
  http_request PATCH \
    "$CF_API_BASE/zones/$zone_id/dns_records/$record_id" \
    cloudflare \
    "$payload"
  expect_cloudflare_success "Обновление CNAME $CDN_DOMAIN"
}

ensure_lets_encrypt() {
  local resource_id=$1
  local resource=$2

  local ssl_enabled ssl_automated
  ssl_enabled=$(jq -r '.sslEnabled // false' <<<"$resource")
  ssl_automated=$(jq -r '.ssl_automated // false' <<<"$resource")

  if [[ "$ssl_enabled" == "true" && "$ssl_automated" == "true" ]]; then
    log "Автоматический сертификат Let's Encrypt уже активен"
    return
  fi

  if [[ "$ssl_enabled" == "true" && "$ssl_automated" != "true" ]]; then
    die "На ресурсе уже включён HTTPS с неавтоматическим сертификатом; замена остановлена"
  fi

  if $DRY_RUN; then
    log "DRY-RUN: будет запрошен Let's Encrypt для ресурса $resource_id"
    return
  fi

  if [[ "$ssl_automated" != "true" ]]; then
    log "Запускаю выпуск Let's Encrypt для ресурса $resource_id"
    http_request POST \
      "$VKCS_CDN_API_BASE/projects/$VKCS_PROJECT_ID/resources/$resource_id/ssl/le/issue" \
      vk

    if [[ "$LAST_HTTP_CODE" != "201" ]]; then
      local error_text
      error_text=$(describe_error "$LAST_HTTP_BODY")
      if [[ "$LAST_HTTP_CODE" == "400" &&
            "$error_text" == *"already being launched"* ]]; then
        warn "Выпуск сертификата уже был запущен"
      else
        die "Запуск Let's Encrypt: HTTP $LAST_HTTP_CODE: $error_text"
      fi
    fi
  fi

  log "Запрос на выпуск Let's Encrypt отправлен; активация продолжится асинхронно в VK Cloud"
}

main() {
  load_saved_config

  while (($# > 0)); do
    case "$1" in
      --cdn)
        (($# >= 2)) || die "После --cdn требуется значение"
        CDN_DOMAIN=$2
        shift 2
        ;;
      --origin)
        (($# >= 2)) || die "После --origin требуется значение"
        ORIGIN=$2
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Неизвестный параметр: $1"
        ;;
    esac
  done

  [[ -n "$CDN_DOMAIN" ]] || die "Укажите --cdn"
  [[ -n "$ORIGIN" ]] || die "Укажите --origin"

  require_command curl
  require_command jq
  load_openrc
  validate_inputs

  TMP_DIR=$(mktemp -d)
  trap cleanup EXIT

  authenticate_vk
  verify_cloudflare_token

  local vk_target
  vk_target=$(get_vk_technical_cname)
  log "Технический CNAME VK Cloud: $vk_target"

  local zone zone_id zone_name
  zone=$(find_cloudflare_zone)
  zone_id=$(jq -r '.id' <<<"$zone")
  zone_name=$(jq -r '.name' <<<"$zone")
  log "Зона Cloudflare: $zone_name ($zone_id)"
  [[ "$CDN_DOMAIN" != "$zone_name" ]] ||
    die "Корневой домен зоны не поддерживается этим CNAME-сценарием; используйте поддомен"

  local resource resource_id origin_group_id
  resource=$(find_vk_resource)
  if [[ -n "$resource" ]]; then
    resource_id=$(jq -r '.id' <<<"$resource")
    log "CDN-ресурс уже существует: ID $resource_id"
    verify_existing_vk_resource "$resource"
    log "Существующий ресурс совпадает с требуемой конфигурацией"
  else
    origin_group_id=$(ensure_vk_origin_group)
    resource=$(create_vk_resource "$origin_group_id")
    if $DRY_RUN; then
      resource_id=""
    else
      resource_id=$(jq -r '.id // empty' <<<"$resource")
      [[ -n "$resource_id" ]] || die "VK Cloud не вернул ID созданного ресурса"
      log "CDN-ресурс создан: ID $resource_id"
    fi
  fi

  # Публикуем CNAME и сразу запускаем Let's Encrypt, не ожидая публичного DNS
  # или перехода CDN-ресурса из processed в active.
  upsert_cloudflare_cname "$zone_id" "$vk_target"

  if [[ -n "$resource_id" ]]; then
    ensure_lets_encrypt "$resource_id" "$resource"
  else
    log "DRY-RUN: Let's Encrypt будет запрошен сразу после создания CNAME"
  fi

  log "Готово: $CDN_DOMAIN → VK CDN → $ORIGIN"
}

main "$@"
