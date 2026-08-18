# syntax=docker/dockerfile:1

# ========== 第一阶段：构建 ==========
FROM node:24-slim AS builder

# lefthook（workspace 里 allowBuilds 放行，pnpm 会执行它的 postinstall）
# 的 postinstall 会运行 git --version，构建期必须有 git。
RUN apt-get update && apt-get install -y --no-install-recommends git && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# 复制整个仓库（详见 .dockerignore）。pnpm 安装时就必须读到每个 workspace 包的
# package.json、pnpm-workspace.yaml、patches/（node-pty 补丁）以及根 postinstall
# 脚本 scripts/install-lefthook.mjs，所以不能只先拷 package.json + lockfile。
COPY . .

# corepack 随 node:24 自带，按 package.json 的 packageManager 字段固定 pnpm 版本
# （pnpm@11.7.0），与 lockfile 一致。仓库没有 git 依赖（也没有 .git 目录，
# 根的 install-lefthook.mjs 会自行跳过）。
RUN corepack enable && pnpm install --frozen-lockfile

# tsc -b（host/client 两个 face）→ tsdown 打包每个包到 lib/，然后 vite 构建前端 dist
RUN pnpm build

# ========== 第二阶段：运行 ==========
FROM node:24-slim AS runtime

# 远程代码工作必需：git、curl，以及 GitHub CLI（gh 走 GitHub 官方 apt 源）。
# 沙箱只限制文件写、不限制网络，所以 agent 的 bash 工具里这些命令都能用。
RUN apt-get update && apt-get install -y --no-install-recommends git curl \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       | install -D -o root -g root -m 644 /dev/stdin /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# 用户数据根：profiles、session、telemetry 都写在这里，建议挂持久卷
ENV DSH_HOME=/data
WORKDIR /app

# pnpm 的 node_modules 用相对符号链接指回 packages/、vendor/、apps/、native/，
# 且每个 workspace 包目录里还有自己的 node_modules —— 必须整体一起搬，缺一块
# 链接就全部悬空（镜像无法启动）。examples/、website/、python/ 只是构建期需要，
# 不复制进运行镜像。
COPY --from=builder /build/package.json /build/pnpm-workspace.yaml ./
COPY --from=builder /build/node_modules ./node_modules
COPY --from=builder /build/packages ./packages
COPY --from=builder /build/vendor ./vendor
COPY --from=builder /build/apps ./apps
COPY --from=builder /build/native ./native

# dsh 入口是 apps/cli/lib/bin.js（tsdown 打包产物，自带 #!/usr/bin/env node）。
# pnpm 不会把叶子应用 @deepseek-ai/dsh 的 bin 链进 node_modules/.bin，所以手动建软链。
# 该入口按相对路径读 ../package.json（apps/cli/package.json）作为版本与解析锚点，
# 因此 apps/ 必须整体复制。
RUN ln -s /app/apps/cli/lib/bin.js /usr/local/bin/dsh

# 容器启动入口：git 身份、gh 鉴权、绑定地址（见 docker-entrypoint.sh）
COPY docker-entrypoint.sh /usr/local/bin/dsh-entrypoint
RUN chmod +x /usr/local/bin/dsh-entrypoint

# web profile 首次启动时会在 $DSH_HOME/profiles/web 自动初始化（模板为
# @deepseek-ai/dsh-base + @deepseek-ai/dsh-web-app），且 guard 插件
# （@deepseek-ai/dsh-tool-call-timeout-policy、@deepseek-ai/dsh-repeat-tool-reminder）
# 已经由 dsh-base 这个 bundle 层挂载 —— 镜像构建期不需要任何 dsh plugin 命令。

EXPOSE 3080
VOLUME /data

# 启动入口（见 docker-entrypoint.sh）：配置 git 身份与 gh 鉴权，然后启动
# dsh web。dsh web 出于安全考虑会明确拒绝 --host 0.0.0.0（这是远程代码执行面，
# 不能直接暴露到全网），入口脚本改为绑定容器自身的第一个非回环 IPv4。
ENTRYPOINT ["/usr/local/bin/dsh-entrypoint"]
