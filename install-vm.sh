#!/usr/bin/env bash
# ============================================================================
#  install-vm.sh —— 在【虚拟机】内以 root 执行：安装脚本 + systemd unit
#
#  它会自动探测 dsh 用户 / 家目录 / dsh 可执行文件 / 端口，把 units/*.in 里的
#  @PLACEHOLDER@ 替换后生成正式 unit，所以克隆下来不需要手改任何路径。
#
#  用法：
#    sudo bash install-vm.sh            # 安装并 enable（不启动，不影响正在跑的实例）
#    sudo bash install-vm.sh --start    # 安装、enable，并立即启动（会断开当前 Web 会话）
#
#  可用环境变量覆盖探测结果：
#    SVC_USER=xxx SVC_HOME=/home/xxx SVC_BIN=/path/to/dsh LOCAL_PORT=3080 bash install-vm.sh
# ============================================================================
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DST=/usr/local/bin/dsh-tunnel.sh
UNIT_DIR=/etc/systemd/system
DEFAULT_DST=/etc/default/dsh-tunnel

[ "$(id -u)" -eq 0 ] || { echo "错误：必须以 root 运行" >&2; exit 1; }

# ── 探测参数（都可用环境变量覆盖）──────────────────────────────────────────
SVC_USER="${SVC_USER:-$(stat -c %U "$SRC_DIR")}"
SVC_HOME="${SVC_HOME:-$(getent passwd "$SVC_USER" | cut -d: -f6)}"
LOCAL_PORT="${LOCAL_PORT:-3080}"

find_dsh() {
  local c
  command -v dsh 2>/dev/null && return 0
  for c in "$SVC_HOME"/.nvm/versions/node/*/bin/dsh \
           /usr/local/bin/dsh /usr/bin/dsh; do
    [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}
SVC_BIN="${SVC_BIN:-$(find_dsh || true)}"

if [ -z "${SVC_BIN:-}" ] || [ ! -x "$SVC_BIN" ]; then
  echo "错误：找不到 dsh 可执行文件。请显式指定，例如：" >&2
  echo "  SVC_BIN=/path/to/dsh SVC_USER=$SVC_USER SVC_HOME=$SVC_HOME bash $0" >&2
  exit 1
fi
[ -n "$SVC_HOME" ] || { echo "错误：拿不到用户 $SVC_USER 的家目录" >&2; exit 1; }

# dsh 的 shebang 是 #!/usr/bin/env node，所以 unit 的 PATH 里要有 node 所在目录
NODE_BIN_DIR="$(dirname "$(command -v node 2>/dev/null || printf '%s' "$SVC_BIN")")"

echo "[install-vm] SVC_USER=$SVC_USER"
echo "[install-vm] SVC_HOME=$SVC_HOME"
echo "[install-vm] SVC_BIN=$SVC_BIN"
echo "[install-vm] LOCAL_PORT=$LOCAL_PORT"

render() {  # render <模板> <目标>
  sed -e "s|@SVC_USER@|$SVC_USER|g" \
      -e "s|@SVC_HOME@|$SVC_HOME|g" \
      -e "s|@SVC_BIN@|$SVC_BIN|g" \
      -e "s|@NODE_BIN_DIR@|$NODE_BIN_DIR|g" \
      -e "s|@LOCAL_PORT@|$LOCAL_PORT|g" \
      "$1" > "$2"
}

echo "[install-vm] 安装 $BIN_DST"
install -m 0755 "$SRC_DIR/tunnel.sh" "$BIN_DST"

for u in dsh-web dsh-tunnel; do
  echo "[install-vm] 生成 $UNIT_DIR/$u.service"
  render "$SRC_DIR/units/$u.service.in" "$UNIT_DIR/$u.service"
  chmod 0644 "$UNIT_DIR/$u.service"
done

if [ -f "$DEFAULT_DST" ]; then
  echo "[install-vm] 保留已有配置 $DEFAULT_DST（未覆盖）"
else
  echo "[install-vm] 生成默认配置 $DEFAULT_DST"
  render "$SRC_DIR/dsh-tunnel.default" "$DEFAULT_DST"
  chmod 0644 "$DEFAULT_DST"
fi

systemctl daemon-reload
systemctl enable dsh-web.service dsh-tunnel.service

echo "[install-vm] 已 enable：$(systemctl is-enabled dsh-web.service dsh-tunnel.service 2>&1 | tr '\n' ' ')"
echo "[install-vm] unit 校验："
systemd-analyze verify "$UNIT_DIR/dsh-web.service" "$UNIT_DIR/dsh-tunnel.service" 2>&1 \
  | grep -v 'is not executable' || true

if [ "${1:-}" = "--start" ]; then
  echo "[install-vm] --start：立即启动（会断开当前 Web 会话）"
  systemctl start dsh-web.service
  systemctl start dsh-tunnel.service
fi

cat <<'EOF'

下一步：
  1) 配好 虚拟机 → 宿主机 免密：  bash setup-key.sh
  2) 平滑切换（带预检，推荐）：    bash switch-now.sh
  3) 体检：                       bash verify.sh
  4) 拿登录 URL：                 bash url.sh
EOF
