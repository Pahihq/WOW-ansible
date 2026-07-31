#!/usr/bin/env bash
set -Eeuo pipefail

PROGRAM_NAME=${0##*/}
CF_API_BASE="https://api.cloudflare.com/client/v4"
CONFIG_PATH="${VKCS_CONFIG_PATH:-$PWD/.env}"

CDN_DOMAIN=""
ORIGIN=""
ORIGIN_PROTOCOL="MATCH"
DNS_TIMEOUT=900
SSL_TIMEOUT=1800
POLL_INTERVAL=15
DRY_RUN=false
SKIP_SSL=false
SKIP_DNS_WAIT=false
INTERACTIVE_MODE=false

LAST_HTTP_CODE=""
LAST_HTTP_BODY=""
TMP_DIR=""

usage() {
  cat <<'EOF'
Создаёт CDN-ресурс VK Cloud, CNAME в Cloudflare и сертификат Let's Encrypt.

Использование:
  setup-cdn.sh --cdn CDN_DOMAIN --origin ORIGIN [параметры]

Обязательные параметры:
  --cdn DOMAIN              Пользовательский CDN-домен, например cdn.example.ru
  --origin HOST[:PORT]      Единственный сервер-источник

Дополнительные параметры:
  --origin-protocol VALUE   HTTP, HTTPS или MATCH (по умолчанию MATCH)
  --dns-timeout SECONDS     Ожидание CNAME (по умолчанию 900)
  --ssl-timeout SECONDS     Ожидание сертификата (по умолчанию 1800)
  --poll-interval SECONDS   Интервал проверок (по умолчанию 15)
  --skip-dns-wait           Не ждать распространения CNAME
  --skip-ssl                Не выпускать Let's Encrypt
  --dry-run                 Выполнять только проверки и показать план изменений
  -h, --help                Показать справку

Переменные окружения:
  VKCS_CONFIG_PATH          Путь к .env (по умолчанию .env в текущем каталоге)
  VKCS_OPENRC_FILE          Путь к OpenStack RC file v3
  OS_PASSWORD               Пароль OpenStack (если не задан, RC-файл запросит его)
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

ask_yes_no() {
  local question=$1
  local default=${2:-yes}
  local suffix answer

  if [[ "$default" == "yes" ]]; then
    suffix="[Y/n]"
  else
    suffix="[y/N]"
  fi

  while true; do
    read -r -p "$question $suffix " answer
    answer=${answer,,}
    if [[ -z "$answer" ]]; then
      [[ "$default" == "yes" ]]
      return
    fi
    case "$answer" in
      y|yes|д|да)
        return 0
        ;;
      n|no|н|нет)
        return 1
        ;;
      *)
        printf 'Введите y/yes/да или n/no/нет.\n' >&2
        ;;
    esac
  done
}

prompt_value() {
  local variable_name=$1
  local label=$2
  local secret=${3:-false}
  local current=${!variable_name:-}
  local value=""

  while true; do
    if $secret; then
      if [[ -n "$current" ]]; then
        read -r -s -p "$label [уже настроено, Enter — оставить]: " value
      else
        read -r -s -p "$label: " value
      fi
      printf '\n' >&2
    else
      if [[ -n "$current" ]]; then
        read -r -p "$label [$current]: " value
      else
        read -r -p "$label: " value
      fi
    fi

    if [[ -z "$value" ]]; then
      value=$current
    fi
    if [[ -n "$value" ]]; then
      printf -v "$variable_name" '%s' "$value"
      export "$variable_name"
      return
    fi
    printf 'Значение не может быть пустым.\n' >&2
  done
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

save_env_value() {
  local name=$1
  local value=${!name:-}
  printf '%s=%q\n' "$name" "$value"
}

save_interactive_config() {
  local temp_path="$CONFIG_PATH.tmp"

  umask 077
  {
    printf '# Создано %s. Содержит секреты; не добавляйте файл в Git.\n' "$PROGRAM_NAME"
    save_env_value VKCS_OPENRC_FILE
    save_env_value OS_AUTH_URL
    save_env_value OS_PROJECT_ID
    save_env_value OS_PROJECT_NAME
    save_env_value OS_PROJECT_DOMAIN_ID
    save_env_value OS_REGION_NAME
    save_env_value OS_USERNAME
    save_env_value OS_USER_DOMAIN_ID
    save_env_value OS_USER_DOMAIN_NAME
    save_env_value OS_INTERFACE
    save_env_value OS_IDENTITY_API_VERSION
    save_env_value OS_PASSWORD
    save_env_value CLOUDFLARE_ACCOUNT_ID
    save_env_value CLOUDFLARE_API_TOKEN
    save_env_value CDN_DOMAIN
    save_env_value ORIGIN
    save_env_value ORIGIN_PROTOCOL
    save_env_value DNS_TIMEOUT
    save_env_value SSL_TIMEOUT
    save_env_value POLL_INTERVAL
    save_env_value SKIP_DNS_WAIT
    save_env_value SKIP_SSL
  } >"$temp_path"
  chmod 600 "$temp_path"
  mv -f -- "$temp_path" "$CONFIG_PATH"
  log "Настройки сохранены в $CONFIG_PATH (права 600)"
}

discover_openrc_file() {
  local downloads_dir="${HOME:-}/Downloads"
  local candidate
  local -a matches=()

  while IFS= read -r candidate; do
    matches+=("$candidate")
  done < <(
    find "$PWD" "$downloads_dir" \
      -maxdepth 1 -type f -iname '*openrc*.sh' -print 2>/dev/null
  )

  if ((${#matches[@]} >= 1)); then
    printf '%s' "${matches[0]}"
  fi
}

load_interactive_config() {
  local auth_choice discovered_openrc

  if [[ -z "${OS_AUTH_URL:-}" ||
    -z "${OS_PROJECT_ID:-}" ||
    -z "${OS_USERNAME:-}" ||
    -z "${OS_PASSWORD:-}" ]]; then
    printf '\nНастройка доступа к VK Cloud:\n'
    printf '1) Загрузить OpenStack RC file v3\n'
    printf '2) Ввести параметры OpenStack вручную\n'
    read -r -p 'Выберите способ [1]: ' auth_choice
    auth_choice=${auth_choice:-1}

    case "$auth_choice" in
      1)
        discovered_openrc=$(discover_openrc_file)
        if [[ -z "${VKCS_OPENRC_FILE:-}" && -n "$discovered_openrc" ]]; then
          VKCS_OPENRC_FILE=$discovered_openrc
          log "Найден OpenStack RC file: $VKCS_OPENRC_FILE"
        fi
        prompt_value VKCS_OPENRC_FILE "Путь к OpenStack RC file v3"
        ;;
      2)
        OS_AUTH_URL=${OS_AUTH_URL:-https://msk.cloud.vk.com/infra/identity/v3/}
        OS_PROJECT_ID=${OS_PROJECT_ID:-${VKCS_PROJECT_ID:-}}
        OS_REGION_NAME=${OS_REGION_NAME:-RegionOne}
        OS_USER_DOMAIN_NAME=${OS_USER_DOMAIN_NAME:-users}
        OS_INTERFACE=${OS_INTERFACE:-public}
        OS_IDENTITY_API_VERSION=${OS_IDENTITY_API_VERSION:-3}

        prompt_value OS_AUTH_URL "OpenStack Auth URL"
        prompt_value OS_PROJECT_ID "OpenStack Project ID"
        prompt_value OS_PROJECT_NAME "OpenStack Project Name"
        prompt_value OS_PROJECT_DOMAIN_ID "OpenStack Project Domain ID"
        prompt_value OS_USERNAME "OpenStack Username"
        prompt_value OS_USER_DOMAIN_NAME "OpenStack User Domain Name"
        prompt_value OS_REGION_NAME "OpenStack Region Name"
        prompt_value OS_INTERFACE "OpenStack Interface"
        prompt_value OS_IDENTITY_API_VERSION "Identity API Version"
        prompt_value OS_PASSWORD "OpenStack Password" true
        ;;
      *)
        die "Неизвестный способ настройки OpenStack: $auth_choice"
        ;;
    esac
  fi
  if [[ -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]]; then
    prompt_value CLOUDFLARE_ACCOUNT_ID "Cloudflare account_id"
  fi
  if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    prompt_value CLOUDFLARE_API_TOKEN "Cloudflare account API token" true
  fi
}

interactive_menu() {
  local choice protocol_choice protocol_default dns_wait_default ssl_default

  INTERACTIVE_MODE=true

  printf '\n'
  printf 'VK Cloud CDN + Cloudflare DNS\n'
  printf '%s\n' '--------------------------------'

  while true; do
    printf '\n'
    printf '1) Создать или проверить CDN\n'
    printf '2) Проверка без изменений (dry-run)\n'
    printf '3) Показать справку\n'
    printf '0) Выход\n'
    read -r -p 'Выберите действие [1]: ' choice
    choice=${choice:-1}

    case "$choice" in
      1)
        DRY_RUN=false
        break
        ;;
      2)
        DRY_RUN=true
        break
        ;;
      3)
        printf '\n'
        usage
        ;;
      0)
        log "Операция отменена"
        exit 0
        ;;
      *)
        printf 'Неизвестный пункт меню.\n' >&2
        ;;
    esac
  done

  load_interactive_config
  prompt_value CDN_DOMAIN "CDN-домен"
  prompt_value ORIGIN "Домен или IP источника[:порт]"

  case "${ORIGIN_PROTOCOL^^}" in
    HTTPS) protocol_default=2 ;;
    HTTP) protocol_default=3 ;;
    *) protocol_default=1 ;;
  esac

  while true; do
    printf '\n'
    printf 'Протокол обращения CDN к источнику:\n'
    printf '1) MATCH — повторять протокол запроса пользователя\n'
    printf '2) HTTPS\n'
    printf '3) HTTP\n'
    read -r -p "Выберите протокол [$protocol_default]: " protocol_choice
    protocol_choice=${protocol_choice:-$protocol_default}
    case "$protocol_choice" in
      1)
        ORIGIN_PROTOCOL="MATCH"
        break
        ;;
      2)
        ORIGIN_PROTOCOL="HTTPS"
        break
        ;;
      3)
        ORIGIN_PROTOCOL="HTTP"
        break
        ;;
      *)
        printf 'Выберите 1, 2 или 3.\n' >&2
        ;;
    esac
  done

  dns_wait_default=yes
  $SKIP_DNS_WAIT && dns_wait_default=no
  if ask_yes_no "Ждать появления CNAME в публичном DNS?" "$dns_wait_default"; then
    SKIP_DNS_WAIT=false
  else
    SKIP_DNS_WAIT=true
  fi

  ssl_default=yes
  $SKIP_SSL && ssl_default=no
  if ask_yes_no "Выпустить сертификат Let's Encrypt?" "$ssl_default"; then
    SKIP_SSL=false
  else
    SKIP_SSL=true
  fi

  if ask_yes_no "Настроить интервалы ожидания вручную?" no; then
    prompt_value DNS_TIMEOUT "Время ожидания DNS, секунд"
    prompt_value SSL_TIMEOUT "Время ожидания SSL, секунд"
    prompt_value POLL_INTERVAL "Интервал проверок, секунд"
  fi

  CDN_DOMAIN=$(normalize_domain "$CDN_DOMAIN")
  ORIGIN=$(normalize_domain "$ORIGIN")

  printf '\n'
  printf 'Итоговая конфигурация\n'
  printf '%s\n' '--------------------------------'
  printf 'Режим:             %s\n' "$($DRY_RUN && printf 'dry-run' || printf 'создание')"
  printf 'CDN-домен:         %s\n' "$CDN_DOMAIN"
  printf 'Источник:          %s\n' "$ORIGIN"
  printf 'Протокол origin:   %s\n' "$ORIGIN_PROTOCOL"
  printf 'Ожидание DNS:      %s\n' "$($SKIP_DNS_WAIT && printf 'нет' || printf 'да')"
  printf "Let's Encrypt:     %s\n" "$($SKIP_SSL && printf 'нет' || printf 'да')"
  printf 'Cloudflare Proxy:  выключен\n'
  printf 'HTTP-методы:       GET, HEAD\n'
  printf '%s\n' '--------------------------------'

  if ! ask_yes_no "Продолжить?" yes; then
    log "Операция отменена"
    exit 0
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
  [[ -f "$VKCS_OPENRC_FILE" ]] || die "OpenStack RC file не найден: $VKCS_OPENRC_FILE"

  log "Загружаю OpenStack RC file: $VKCS_OPENRC_FILE"
  set +u
  # shellcheck disable=SC1090
  source "$VKCS_OPENRC_FILE"
  set -u

  require_env OS_AUTH_URL
  require_env OS_PROJECT_ID
  require_env OS_USERNAME
  require_env OS_PASSWORD
  [[ -n "${OS_USER_DOMAIN_ID:-}" || -n "${OS_USER_DOMAIN_NAME:-}" ]] ||
    die "Не задан OS_USER_DOMAIN_ID или OS_USER_DOMAIN_NAME"
}

validate_inputs() {
  [[ -n "$CDN_DOMAIN" ]] || die "Укажите --cdn"
  [[ -n "$ORIGIN" ]] || die "Укажите --origin"

  CDN_DOMAIN=$(normalize_domain "$CDN_DOMAIN")
  ORIGIN=$(normalize_domain "$ORIGIN")
  ORIGIN_PROTOCOL=${ORIGIN_PROTOCOL^^}

  [[ "$CDN_DOMAIN" != *"*"* ]] || die "Wildcard-домены несовместимы с Let's Encrypt в VK Cloud"
  [[ "$CDN_DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] ||
    die "CDN-домен должен быть передан в ASCII/Punycode без пути"
  [[ "$CDN_DOMAIN" == *.* ]] || die "CDN-домен должен быть полным доменным именем"
  [[ "$ORIGIN" != *"@"* ]] || die "Origin не должен содержать логин или пароль"
  [[ "$ORIGIN_PROTOCOL" =~ ^(HTTP|HTTPS|MATCH)$ ]] ||
    die "--origin-protocol должен быть HTTP, HTTPS или MATCH"
  [[ "$DNS_TIMEOUT" =~ ^[0-9]+$ ]] || die "--dns-timeout должен быть целым числом"
  [[ "$SSL_TIMEOUT" =~ ^[0-9]+$ ]] || die "--ssl-timeout должен быть целым числом"
  [[ "$POLL_INTERVAL" =~ ^[1-9][0-9]*$ ]] || die "--poll-interval должен быть больше нуля"

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
    (.options.allowedHttpMethods.enabled // false) == true
    and ((.options.allowedHttpMethods.value // []) | sort == ["GET", "HEAD"])
  ' <<<"$resource")
  host_forward_ok=$(jq -r '
    (.options.forward_host_header.enabled // false) == true
    and (.options.forward_host_header.value // false) == true
  ' <<<"$resource")
  extra_enabled=$(jq -r '
    [
      (.options // {})
      | to_entries[]
      | select(.key != "allowedHttpMethods" and .key != "forward_host_header")
      | select((.value | type) == "object" and (.value.enabled // false) == true)
      | .key
    ]
    | join(",")
  ' <<<"$resource")

  [[ "$protocol" == "$ORIGIN_PROTOCOL" ]] ||
    die "Ресурс $resource_id использует originProtocol=$protocol, ожидался $ORIGIN_PROTOCOL"
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
    --arg protocol "$ORIGIN_PROTOCOL" \
    '{
      cname: $cname,
      secondaryHostnames: [],
      originGroup: $origin_group,
      originProtocol: $protocol,
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

wait_for_vk_resource() {
  local resource_id=$1
  local timeout=$2
  local purpose=$3
  local started=$SECONDS

  while true; do
    local resource
    resource=$(get_vk_resource "$resource_id")
    local status
    status=$(jq -r '.status // empty' <<<"$resource")

    if [[ "$purpose" == "active" && "$status" == "active" ]]; then
      printf '%s' "$resource"
      return
    fi

    if [[ "$purpose" == "ssl" ]]; then
      local ssl_enabled ssl_automated
      ssl_enabled=$(jq -r '.sslEnabled // false' <<<"$resource")
      ssl_automated=$(jq -r '.ssl_automated // false' <<<"$resource")
      if [[ "$ssl_enabled" == "true" && "$ssl_automated" == "true" ]]; then
        printf '%s' "$resource"
        return
      fi
    fi

    [[ "$status" != "suspended" ]] ||
      die "CDN-ресурс $resource_id перешёл в состояние suspended"
    ((SECONDS - started < timeout)) ||
      die "Истекло время ожидания CDN-ресурса $resource_id ($purpose)"

    log "CDN-ресурс $resource_id: status=${status:-unknown}, ожидаю $purpose"
    sleep "$POLL_INTERVAL"
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

wait_for_dns() {
  local expected=$1
  local started=$SECONDS

  if $SKIP_DNS_WAIT; then
    warn "Ожидание DNS пропущено"
    return
  fi

  require_command dig
  log "Ожидаю публичный CNAME $CDN_DOMAIN → $expected"
  while true; do
    local answer
    answer=$(dig +short CNAME "$CDN_DOMAIN" @1.1.1.1 2>/dev/null | head -n1 || true)
    answer=$(normalize_domain "$answer")

    if [[ "$answer" == "$expected" ]]; then
      log "DNS-запись опубликована"
      return
    fi

    ((SECONDS - started < DNS_TIMEOUT)) ||
      die "CNAME не появился за $DNS_TIMEOUT секунд; последний ответ: ${answer:-пусто}"

    log "DNS пока не обновился; последний ответ: ${answer:-пусто}"
    sleep "$POLL_INTERVAL"
  done
}

ensure_lets_encrypt() {
  local resource_id=$1
  local resource=$2

  if $SKIP_SSL; then
    warn "Выпуск Let's Encrypt пропущен"
    return
  fi

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

  log "Ожидаю активацию Let's Encrypt (до $SSL_TIMEOUT секунд)"
  wait_for_vk_resource "$resource_id" "$SSL_TIMEOUT" ssl >/dev/null
  log "Let's Encrypt активирован и настроен на автопродление"
}

main() {
  load_saved_config

  if (($# == 0)); then
    interactive_menu
  fi

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
      --origin-protocol)
        (($# >= 2)) || die "После --origin-protocol требуется значение"
        ORIGIN_PROTOCOL=$2
        shift 2
        ;;
      --dns-timeout)
        (($# >= 2)) || die "После --dns-timeout требуется значение"
        DNS_TIMEOUT=$2
        shift 2
        ;;
      --ssl-timeout)
        (($# >= 2)) || die "После --ssl-timeout требуется значение"
        SSL_TIMEOUT=$2
        shift 2
        ;;
      --poll-interval)
        (($# >= 2)) || die "После --poll-interval требуется значение"
        POLL_INTERVAL=$2
        shift 2
        ;;
      --skip-dns-wait)
        SKIP_DNS_WAIT=true
        shift
        ;;
      --skip-ssl)
        SKIP_SSL=true
        shift
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

  require_command curl
  require_command jq
  load_openrc
  validate_inputs

  if $INTERACTIVE_MODE; then
    save_interactive_config
  fi

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

  # Публикуем CNAME сразу: технический адрес доступен ещё во время обработки
  # CDN-ресурса, поэтому нет необходимости ждать status=active.
  upsert_cloudflare_cname "$zone_id" "$vk_target"

  if ! $DRY_RUN; then
    wait_for_dns "$vk_target"
  fi

  if [[ -n "$resource_id" ]]; then
    log "Ожидаю готовность CDN-ресурса"
    resource=$(wait_for_vk_resource "$resource_id" "$DNS_TIMEOUT" active)
    log "CDN-ресурс готов"
  fi

  if [[ -n "$resource_id" ]]; then
    ensure_lets_encrypt "$resource_id" "$resource"
  elif ! $SKIP_SSL; then
    log "DRY-RUN: Let's Encrypt будет запрошен после создания ресурса и публикации DNS"
  fi

  log "Готово: $CDN_DOMAIN → VK CDN → $ORIGIN"
}

main "$@"
