#!/usr/bin/env bash
set -euo pipefail

WORK_DIR="$(pwd)"
TEMPLATE_FILE="${WORK_DIR}/docker-compose-template.yml"
OUTPUT_FILE="${WORK_DIR}/docker-compose.yml"
TEMPLATE_URL_DEFAULT="https://raw.githubusercontent.com/liyown/shiroi-deploy/main/docker-compose-template.yml"
TEMPLATE_URL="${TEMPLATE_URL:-$TEMPLATE_URL_DEFAULT}"
FORCE_TEMPLATE_DOWNLOAD="false"

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
    *)
      echo "错误: 不支持的参数 $1" >&2
      echo "可用参数: --template-url <url> --force-template-download" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$TEMPLATE_URL" ]]; then
  echo "错误: 模板下载地址为空，请通过 --template-url 或 TEMPLATE_URL 提供。" >&2
  exit 1
fi

download_template() {
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
  echo "正在下载模板: $TEMPLATE_URL"
  download_template "$TEMPLATE_URL" "$TEMPLATE_FILE"
  echo "模板已保存到: $TEMPLATE_FILE"
else
  echo "检测到本地模板: $TEMPLATE_FILE"
  echo "如需强制更新模板，请增加参数: --force-template-download"
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
NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY=""
CLERK_SECRET_KEY=""

echo
echo "以下配置将使用默认值"
echo "- NEXT_PUBLIC_API_URL: ${NEXT_PUBLIC_API_URL}"
echo "- NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY: (空)"
echo "- CLERK_SECRET_KEY: (空)"
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

rendered_content="$({
  cat "$TEMPLATE_FILE" | sed \
    -e "s|__NEXT_PUBLIC_API_URL__|$(escape_sed_replacement "$NEXT_PUBLIC_API_URL")|g" \
    -e "s|__NEXT_PUBLIC_GATEWAY_URL__|$(escape_sed_replacement "$NEXT_PUBLIC_GATEWAY_URL")|g" \
    -e "s|__NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY__|$(escape_sed_replacement "$NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY")|g" \
    -e "s|__CLERK_SECRET_KEY__|$(escape_sed_replacement "$CLERK_SECRET_KEY")|g" \
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
