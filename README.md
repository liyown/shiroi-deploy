# Shiroi Deploy Script

一键部署 Shiroi（Docker Compose + Nginx 反代 + Let's Encrypt HTTPS）。

## 特性

- 交互式配置（精简提问）
- 自动启动容器：`docker-compose up -d` / `docker compose up -d`
- 自动安装并配置 Nginx 反向代理
- 自动申请 HTTPS 证书（Certbot）
- 自动配置证书续期（`certbot.timer` 或 `cron`）

## 快速开始

```bash
curl -fsSL https://raw.githubusercontent.com/liyown/shiroi-deploy/main/install.sh | bash
```

## 交互会询问的内容

1. 主域名（例如 `https://example.com`）
2. `TMDB_API_KEY`
3. `GH_TOKEN`
4. `JWT_SECRET`（可直接回车自动生成）
5. 证书通知邮箱（默认 `admin@你的域名`）

## 自动默认配置

- `NEXT_PUBLIC_API_URL=<主域名>/api/v2`
- `TZ=Asia/Shanghai`
- `FRONT_PORT=2323`
- `APP_PORT=2333`
- `ALLOWED_ORIGINS=<domain>,www.<domain>`

## 可选参数

```bash
curl -fsSL https://raw.githubusercontent.com/liyown/shiroi-deploy/main/install.sh | bash -s -- \
  --template-url https://raw.githubusercontent.com/liyown/shiroi-deploy/main/docker-compose-template.yml \
  --nginx-template-url https://raw.githubusercontent.com/liyown/shiroi-deploy/main/nginx.conf \
  --force-template-download
```

## 前置条件

- Linux 服务器（Debian/Ubuntu/CentOS/RHEL/Fedora 等）
- 具备 `root` 或 `sudo` 权限
- 域名已解析到当前服务器
- 防火墙/安全组放行 `80` 和 `443`
- 服务器已安装 Docker（脚本会使用 `docker-compose` 或 `docker compose`）

## HTTPS 与续期说明

- 使用 Certbot 自动申请证书
- 域名不是公网域名、或填写的是 IP 时，会跳过证书申请
- 申请证书时会自动检测 `www` 子域名是否可解析：
  - 可解析：一起签发 `example.com` + `www.example.com`
  - 不可解析：只签发主域名
- 续期机制：
  - 优先启用 `certbot.timer`
  - 否则写入 `/etc/cron.d/certbot-renew-shiroi`
  - 首次签发后执行 `certbot renew --dry-run`

## 生成的文件

- 当前目录生成：`docker-compose.yml`
- Nginx 路径：
  - `/etc/nginx/snippets/shiroi-locations.conf`
  - `/etc/nginx/conf.d/shiroi.conf`

## 常见问题

### 1) 证书申请失败

常见原因：

- DNS 未生效或未解析到当前机器
- 80/443 端口未放通
- 域名被 CDN/代理拦截了 ACME 验证

排查建议：

```bash
nginx -t
certbot certificates
certbot renew --dry-run
```

### 2) `www` 域名没有证书

脚本只会在 `www.<domain>` 可解析时才自动加入签发。如果你不需要 `www`，这是正常行为。

### 3) 只想重装反代/证书

可直接重复执行安装命令，脚本会覆盖 Nginx 配置并重试签发。
