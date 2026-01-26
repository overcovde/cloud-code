FROM nikolaik/python-nodejs:python3.12-nodejs22-bookworm

ENV NODE_ENV=production

ARG TIGRISFS_VERSION=1.2.1
ARG CLOUDFLARED_DEB_URL=https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb

# 安装系统依赖 + tigrisfs/cloudflared/opencode，并清理缓存
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      fuse \
      ca-certificates \
      curl; \
    \
    curl -fsSL "https://github.com/tigrisdata/tigrisfs/releases/download/v${TIGRISFS_VERSION}/tigrisfs_${TIGRISFS_VERSION}_linux_amd64.deb" -o /tmp/tigrisfs.deb; \
    dpkg -i /tmp/tigrisfs.deb; \
    rm -f /tmp/tigrisfs.deb; \
    \
    curl -fsSL "${CLOUDFLARED_DEB_URL}" -o /tmp/cloudflared.deb; \
    dpkg -i /tmp/cloudflared.deb; \
    rm -f /tmp/cloudflared.deb; \
    \
    curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path; \
    mv /root/.opencode/bin/opencode /usr/local/bin/opencode; \
    \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# 复制预置内容
COPY config /opt/config-init

# 创建启动脚本
RUN install -m 755 /dev/stdin /entrypoint.sh <<'EOF'
#!/bin/bash
set -e

MOUNT_POINT="/root/s3"
WORKSPACE_DIR="$MOUNT_POINT/workspace"
XDG_DIR="$MOUNT_POINT/.opencode"
GLOBAL_CONFIG_DIR="$XDG_DIR/config/opencode"
CONFIG_INIT_DIR="/opt/config-init/opencode"

# 初始化工作目录和 XDG 环境变量
setup_workspace() {
    mkdir -p "$WORKSPACE_DIR/project" "$GLOBAL_CONFIG_DIR" "$XDG_DIR"/{data,state}
    export XDG_CONFIG_HOME="$XDG_DIR/config"
    export XDG_DATA_HOME="$XDG_DIR/data"
    export XDG_STATE_HOME="$XDG_DIR/state"
    PROJECT_DIR="$WORKSPACE_DIR/project"

    # 仅在配置文件不存在时复制
    for file in opencode.json AGENTS.md; do
        if [ ! -f "$GLOBAL_CONFIG_DIR/$file" ]; then
            cp "$CONFIG_INIT_DIR/$file" "$GLOBAL_CONFIG_DIR/" 2>/dev/null && echo "[INFO] 已初始化 $file" || true
        fi
    done
}

# 确保挂载点是一个干净目录
reset_mountpoint() {
    mountpoint -q "$MOUNT_POINT" 2>/dev/null && fusermount -u "$MOUNT_POINT" 2>/dev/null || true
    rm -rf "$MOUNT_POINT"
    mkdir -p "$MOUNT_POINT"
}

reset_mountpoint

if [ -z "$S3_ENDPOINT" ] || [ -z "$S3_BUCKET" ] || [ -z "$S3_ACCESS_KEY_ID" ] || [ -z "$S3_SECRET_ACCESS_KEY" ]; then
    echo "[WARN] S3 配置不完整，使用本地目录模式"
else
    echo "[INFO] 挂载 S3: ${S3_BUCKET} -> ${MOUNT_POINT}"

    export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID"
    export AWS_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY"
    export AWS_REGION="${S3_REGION:-auto}"
    export AWS_S3_PATH_STYLE="${S3_PATH_STYLE:-false}"

    /usr/bin/tigrisfs --endpoint "$S3_ENDPOINT" ${TIGRISFS_ARGS:-} -f "${S3_BUCKET}${S3_PREFIX:+:$S3_PREFIX}" "$MOUNT_POINT" &
    sleep 3

    if ! mountpoint -q "$MOUNT_POINT"; then
        echo "[ERROR] S3 挂载失败"
        exit 1
    fi
    echo "[OK] S3 挂载成功"
fi

setup_workspace

cleanup() {
    echo "[INFO] 正在关闭..."
    if [ -n "$OPENCODE_PID" ]; then
        kill -TERM "$OPENCODE_PID" 2>/dev/null
        wait "$OPENCODE_PID" 2>/dev/null
    fi
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        fusermount -u "$MOUNT_POINT" 2>/dev/null || true
    fi
    exit 0
}
trap cleanup SIGTERM SIGINT

echo "[INFO] 启动 OpenCode..."
cd "$PROJECT_DIR"
opencode web --port 2633 --hostname 0.0.0.0 &
OPENCODE_PID=$!
wait $OPENCODE_PID
EOF

WORKDIR /root/s3/workspace
EXPOSE 2633

CMD ["/entrypoint.sh"]
