#!/usr/bin/env bash
set -euo pipefail

WORK_DIR="$(pwd)"
TEMPLATE_FILE="${WORK_DIR}/docker-compose-template.yml"
OUTPUT_FILE="${WORK_DIR}/docker-compose.yml"
TEMPLATE_URL_DEFAULT="https://raw.githubusercontent.com/liyown/shiroi-deploy/main/docker-compose-template.yml"
TEMPLATE_URL="${TEMPLATE_URL:-$TEMPLATE_URL_DEFAULT}"
NGINX_LOCATIONS_FILE="${WORK_DIR}/nginx.conf"
NGINX_TEMPLATE_URL_DEFAULT="https://raw.githubusercontent.com/liyown/shiroi-deploy/main/nginx.conf"
NGINX_TEMPLATE_URL="${NGINX_TEMPLATE_URL:-$NGINX_TEMPLATE_URL_DEFAULT}"
FORCE_TEMPLATE_DOWNLOAD="false"
SUDO=""

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  fi
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --template-url)
      TEMPLATE_URL="${2:-}"
      shift 2
      ;;
    --force-template-download)
      FORCE_TEMPLATE_DOWNLOAD="true"
      shift
      ;;
    --nginx-template-url)
      NGINX_TEMPLATE_URL="${2:-}"
      shift 2
      ;;
    *)
      echo "错误: 不支持的参数 $1" >&2
      echo "可用参数: --template-url <url> --nginx-template-url <url> --force-template-download" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$TEMPLATE_URL" ]]; then
  echo "错误: 模板下载地址为空，请通过 --template-url 或 TEMPLATE_URL 提供。" >&2
  exit 1
fi

if [[ -z "$NGINX_TEMPLATE_URL" ]]; then
  echo "错误: Nginx 模板下载地址为空，请通过 --nginx-template-url 或 NGINX_TEMPLATE_URL 提供。" >&2
  exit 1
fi

download_file() {
  local url="$1"
  local out="$2"
  local tmp_file
  tmp_file="$(mktemp)"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$tmp_file"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp_file" "$url"
  else
    echo "错误: 未检测到 curl/wget，无法下载模板。" >&2
    rm -f "$tmp_file"
    exit 1
  fi

  if [[ ! -s "$tmp_file" ]]; then
    echo "错误: 下载的模板为空，请检查地址: $url" >&2
    rm -f "$tmp_file"
    exit 1
  fi

  mv "$tmp_file" "$out"
}

run_root() {
  if [[ -n "$SUDO" ]]; then
    $SUDO "$@"
  else
    "$@"
  fi
}

install_reverse_proxy_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    run_root apt-get update -y
    run_root apt-get install -y nginx certbot python3-certbot-nginx
    return
  fi

  if command -v dnf >/dev/null 2>&1; then
    run_root dnf install -y nginx certbot python3-certbot-nginx
    return
  fi

  if command -v yum >/dev/null 2>&1; then
    run_root yum install -y epel-release || true
    run_root yum install -y nginx certbot python3-certbot-nginx || run_root yum install -y nginx certbot certbot-nginx
    return
  fi

  echo "错误: 未识别的包管理器，无法自动安装 Nginx/Certbot。" >&2
  exit 1
}

reload_nginx() {
  if command -v systemctl >/dev/null 2>&1; then
    run_root systemctl enable nginx
    run_root systemctl restart nginx
    return
  fi

  run_root service nginx restart
}

setup_certbot_renewal() {
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^certbot.timer'; then
    run_root systemctl enable certbot.timer
    run_root systemctl start certbot.timer
    return
  fi

  if [[ -d /etc/cron.d ]]; then
    local cron_tmp
    cron_tmp="$(mktemp)"
    cat > "$cron_tmp" <<'EOF'
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 3 * * * root certbot renew --quiet --deploy-hook "systemctl reload nginx || service nginx reload"
EOF
    run_root install -m 644 "$cron_tmp" /etc/cron.d/certbot-renew-shiroi
    rm -f "$cron_tmp"
  fi
}

configure_reverse_proxy() {
  local domain_host="$1"
  local le_email="$2"
  local site_tmp
  local -a cert_domains
  local -a certbot_cmd
  site_tmp="$(mktemp)"
  cert_domains=("$domain_host")

  install_reverse_proxy_deps

  run_root mkdir -p /etc/nginx/snippets
  run_root install -m 644 "$NGINX_LOCATIONS_FILE" /etc/nginx/snippets/shiroi-locations.conf

  cat > "$site_tmp" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain_host} www.${domain_host};

    include /etc/nginx/snippets/shiroi-locations.conf;
}
EOF

  run_root install -m 644 "$site_tmp" /etc/nginx/conf.d/shiroi.conf
  rm -f "$site_tmp"

  run_root nginx -t
  reload_nginx

  if [[ "$domain_host" != *.* ]]; then
    echo "提示: 域名 ${domain_host} 不是标准公网域名，跳过 HTTPS 证书申请。"
    return
  fi

  if [[ "$domain_host" =~ ^[0-9.]+$ ]]; then
    echo "提示: 检测到 IP 地址 ${domain_host}，跳过 HTTPS 证书申请。"
    return
  fi

  if ! command -v certbot >/dev/null 2>&1; then
    echo "提示: 未检测到 certbot，跳过 HTTPS 证书申请。"
    return
  fi

  if [[ "$domain_host" != www.* ]]; then
    if command -v getent >/dev/null 2>&1; then
      if getent ahosts "www.${domain_host}" >/dev/null 2>&1; then
        cert_domains+=("www.${domain_host}")
      else
        echo "提示: 未检测到 www.${domain_host} 的 DNS 解析，仅为 ${domain_host} 申请证书。"
      fi
    else
      echo "提示: 系统无 getent，跳过 www 子域名自动检测，仅为 ${domain_host} 申请证书。"
    fi
  fi

  certbot_cmd=(certbot --nginx --non-interactive --agree-tos -m "$le_email")
  for d in "${cert_domains[@]}"; do
    certbot_cmd+=(-d "$d")
  done
  certbot_cmd+=(--redirect)

  if ! run_root "${certbot_cmd[@]}"; then
    echo "提示: HTTPS 自动申请失败，已保留 HTTP 反代。请检查域名解析和 80/443 端口后重试。"
    return
  fi

  setup_certbot_renewal
  if ! run_root certbot renew --dry-run; then
    echo "提示: 证书续期 dry-run 未通过，请稍后手动执行: certbot renew --dry-run"
  fi
}

ask_with_default() {
  local prompt="$1"
  local default_value="$2"
  local value
  read -r -p "$prompt [默认: $default_value]: " value
  value="$(printf '%s' "$value" | tr -d '\r\n')"
  if [[ -z "$value" ]]; then
    value="$default_value"
  fi
  printf '%s' "$value"
}

ask_secret() {
  local prompt="$1"
  local value=""
  while [[ -z "$value" ]]; do
    read -r -s -p "$prompt: " value
    value="$(printf '%s' "$value" | tr -d '\r\n')"
    echo
    if [[ -z "$value" ]]; then
      echo "输入不能为空，请重新输入。"
    fi
  done
  printf '%s' "$value"
}

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'
}

echo "=============================================="
echo "Shiroi 安装向导 (Bash)"
echo "将自动下载模板，按你的输入生成 docker-compose.yml 并启动"
echo "=============================================="

if [[ ! -f "$TEMPLATE_FILE" || "$FORCE_TEMPLATE_DOWNLOAD" == "true" ]]; then
  echo "正在下载 Compose 模板: $TEMPLATE_URL"
  download_file "$TEMPLATE_URL" "$TEMPLATE_FILE"
  echo "模板已保存到: $TEMPLATE_FILE"
else
  echo "检测到本地模板: $TEMPLATE_FILE"
  echo "如需强制更新模板，请增加参数: --force-template-download"
fi

if [[ ! -f "$NGINX_LOCATIONS_FILE" || "$FORCE_TEMPLATE_DOWNLOAD" == "true" ]]; then
  echo "正在下载 Nginx 反代模板: $NGINX_TEMPLATE_URL"
  download_file "$NGINX_TEMPLATE_URL" "$NGINX_LOCATIONS_FILE"
  echo "模板已保存到: $NGINX_LOCATIONS_FILE"
else
  echo "检测到本地 Nginx 模板: $NGINX_LOCATIONS_FILE"
fi

echo
echo "[1/4] 域名配置"
echo "作用: 前端网关根地址，用于拼接站点级链接和部分跳转。"
echo "获取方式: 填写站点主域名（不带末尾斜杠），例如 https://your-domain.com。"
echo "说明: API 地址将自动使用 <域名>/api/v2，端口将自动使用默认值。"
NEXT_PUBLIC_GATEWAY_URL="$(ask_with_default "请输入主域名 NEXT_PUBLIC_GATEWAY_URL" "https://example.com")"
NEXT_PUBLIC_GATEWAY_URL="${NEXT_PUBLIC_GATEWAY_URL%/}"
NEXT_PUBLIC_API_URL="${NEXT_PUBLIC_GATEWAY_URL}/api/v2"

echo
echo "[2/4] TMDB_API_KEY"
echo "作用: 访问 TMDB 数据接口。"
echo "获取方式: TMDB 账号后台申请 API Key。"
TMDB_API_KEY="$(ask_secret "请输入 TMDB_API_KEY（隐藏输入）")"

echo
echo "[3/4] GH_TOKEN"
echo "作用: 访问 GitHub API（若你的功能依赖私有仓库或更高限额）。"
echo "获取方式: GitHub Settings -> Developer settings -> Personal access tokens。"
GH_TOKEN="$(ask_secret "请输入 GH_TOKEN（隐藏输入）")"

echo
echo "[4/4] JWT_SECRET"
echo "作用: 用于签发和校验 JWT 的核心密钥。"
echo "获取方式: 可直接回车自动生成，或手动填写 32+ 位高强度随机字符串。"
read -r -s -p "请输入 JWT_SECRET（隐藏输入，回车自动生成）: " JWT_SECRET
echo
if [[ -z "$JWT_SECRET" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    JWT_SECRET="$(openssl rand -hex 32)"
  else
    JWT_SECRET="$(date +%s | shasum | awk '{print $1}')$(date +%s | shasum | awk '{print $1}' | cut -c1-24)"
  fi
  echo "已自动生成 JWT_SECRET。"
fi

DOMAIN_HOST="$(printf '%s' "$NEXT_PUBLIC_GATEWAY_URL" | sed -E 's#^[a-zA-Z]+://##' | sed -E 's#/.*$##')"
DOMAIN_HOST="$(printf '%s' "$DOMAIN_HOST" | sed -E 's#:[0-9]+$##')"

echo
echo "以下配置将使用默认值"
echo "- NEXT_PUBLIC_API_URL: ${NEXT_PUBLIC_API_URL}"
echo "- TZ: Asia/Shanghai"
echo "- FRONT_PORT: 2323"
echo "- APP_PORT: 2333"
echo "- ALLOWED_ORIGINS: ${DOMAIN_HOST},www.${DOMAIN_HOST}"

echo
echo "[默认] ALLOWED_ORIGINS"
echo "作用: 后端允许跨域访问的来源白名单。"
echo "获取方式: 填写前端访问域名，多个值用英文逗号分隔，例如 a.com,b.com,www.b.com。"
ALLOWED_ORIGINS="${DOMAIN_HOST},www.${DOMAIN_HOST}"
TZ="Asia/Shanghai"
FRONT_PORT="2323"
APP_PORT="2333"

NEXT_PUBLIC_API_URL="$(printf '%s' "$NEXT_PUBLIC_API_URL" | tr -d '\r\n')"
NEXT_PUBLIC_GATEWAY_URL="$(printf '%s' "$NEXT_PUBLIC_GATEWAY_URL" | tr -d '\r\n')"
TMDB_API_KEY="$(printf '%s' "$TMDB_API_KEY" | tr -d '\r\n')"
GH_TOKEN="$(printf '%s' "$GH_TOKEN" | tr -d '\r\n')"
JWT_SECRET="$(printf '%s' "$JWT_SECRET" | tr -d '\r\n')"
ALLOWED_ORIGINS="$(printf '%s' "$ALLOWED_ORIGINS" | tr -d '\r\n')"
TZ="$(printf '%s' "$TZ" | tr -d '\r\n')"
FRONT_PORT="$(printf '%s' "$FRONT_PORT" | tr -d '\r\n')"
APP_PORT="$(printf '%s' "$APP_PORT" | tr -d '\r\n')"

echo
echo "[附加] HTTPS 证书邮箱"
echo "作用: Let's Encrypt 证书到期提醒和紧急通知。"
echo "获取方式: 可回车使用默认邮箱 admin@${DOMAIN_HOST}。"
LETSENCRYPT_EMAIL="$(ask_with_default "请输入证书邮箱" "admin@${DOMAIN_HOST}")"
LETSENCRYPT_EMAIL="$(printf '%s' "$LETSENCRYPT_EMAIL" | tr -d '\r\n')"

rendered_content="$({
  cat "$TEMPLATE_FILE" | sed \
    -e "s|__NEXT_PUBLIC_API_URL__|$(escape_sed_replacement "$NEXT_PUBLIC_API_URL")|g" \
    -e "s|__NEXT_PUBLIC_GATEWAY_URL__|$(escape_sed_replacement "$NEXT_PUBLIC_GATEWAY_URL")|g" \
    -e "s|__TMDB_API_KEY__|$(escape_sed_replacement "$TMDB_API_KEY")|g" \
    -e "s|__GH_TOKEN__|$(escape_sed_replacement "$GH_TOKEN")|g" \
    -e "s|__ALLOWED_ORIGINS__|$(escape_sed_replacement "$ALLOWED_ORIGINS")|g" \
    -e "s|__JWT_SECRET__|$(escape_sed_replacement "$JWT_SECRET")|g" \
    -e "s|__TZ__|$(escape_sed_replacement "$TZ")|g" \
    -e "s|__FRONT_PORT__|$(escape_sed_replacement "$FRONT_PORT")|g" \
    -e "s|__APP_PORT__|$(escape_sed_replacement "$APP_PORT")|g"
})"

printf '%s\n' "$rendered_content" > "$OUTPUT_FILE"
echo "已生成 $OUTPUT_FILE"

if command -v docker-compose >/dev/null 2>&1; then
  echo "检测到 docker-compose，开始启动服务..."
  docker-compose -f "$OUTPUT_FILE" up -d
elif command -v docker >/dev/null 2>&1; then
  echo "未检测到 docker-compose，尝试使用 docker compose..."
  docker compose -f "$OUTPUT_FILE" up -d
else
  echo "错误: 未检测到 Docker。请先安装 Docker / Docker Compose。" >&2
  exit 1
fi

echo "正在安装并配置 Nginx 反向代理..."
configure_reverse_proxy "$DOMAIN_HOST" "$LETSENCRYPT_EMAIL"
echo "反向代理配置完成。"
