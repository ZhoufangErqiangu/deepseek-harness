#!/bin/sh
# dsh 容器启动入口：配置 git/gh，然后启动 web profile。
# 所有值都来自环境变量（部署平台注入），密钥永不写入镜像。
set -e

# 挂载卷里的仓库可能属于宿主机用户，git 会拒绝"可疑所有者"；单租户容器直接放行。
git config --global --add safe.directory '*' 2>/dev/null || true

# 提交身份：仅当提供了 GIT_USER_NAME / GIT_USER_EMAIL 才配置，避免错误署名。
# 未提供时交给 agent 自行按仓库配置。
if [ -n "${GIT_USER_NAME:-}" ] || [ -n "${GIT_USER_EMAIL:-}" ]; then
  git config --global user.name  "${GIT_USER_NAME:-dsh-agent}"
  git config --global user.email "${GIT_USER_EMAIL:-dsh-agent@localhost}"
fi

# GitHub CLI 鉴权：容器里无法交互式 gh auth login，用 GH_TOKEN / GITHUB_TOKEN。
# 有 token 时把 gh 注册为 git 的 HTTPS credential helper（push/pull 免密）；
# 若 setup-git 失败（例如只给了 GITHUB_TOKEN），退回手写 helper。
if [ -n "${GH_TOKEN:-}" ] || [ -n "${GITHUB_TOKEN:-}" ]; then
  gh auth setup-git >/dev/null 2>&1 || \
    git config --global credential.helper \
      '!f() { echo "username=x-access-token"; echo "password=${GH_TOKEN:-${GITHUB_TOKEN}}"; }; f'
fi

# 绑定容器自身的第一个非回环 IPv4（node:24-slim 里未必有 hostname/ip 命令）。
# dsh web 出于安全考虑拒绝 --host 0.0.0.0；DSH_BIND_HOST 可强制指定绑定地址，
# DSH_TRUSTED_HOST 把平台路由进来的公网域名加入 /api 浏览器信任名单，
# DSH_PORT 兼容需要监听 $PORT 的托管平台。
BIND="${DSH_BIND_HOST:-$(node -e 'const os=require("os");const a=Object.values(os.networkInterfaces()).flat().filter(i=>i&&i.family==="IPv4"&&!i.internal);console.log(a[0]?a[0].address:"127.0.0.1")')}"

exec dsh web --host "$BIND" --port "${DSH_PORT:-3080}" --trusted-host "${DSH_TRUSTED_HOST:-localhost}"
