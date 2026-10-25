#!/usr/bin/env bash
# ============================================================================
#  install-vm.sh —— 在【虚拟机】内以 root 执行：安装脚本 + systemd unit
#
#  它会自动探测 dsh 用户 / 家目录 / exe 路径 / 端口 / 仓库地址，把 units/*.in
#  里的 @PLACEHOLDER@ 替换后生成正式 unit，所以克隆下来不需要手改任何路径。
#  渲染完成后会检查是否还残留 @XXX@ 占位符——漏渲染直接报错，不会装出一个
#  指向 github.com/OWNER/… 的文档链接。
#
#  用法：
#    sudo bash install-vm.sh            # 安装并 enable（不启动，不影响正在跑的实例）
#    sudo bash install-vm.sh --start    # 安装、enable，并立即启动（会断开当前 Web 会话）
#
#    # 预演/打包：不需要 root，把所有文件渲染到 DESTDIR 下（CI 用它做校验）
#    DESTDIR=/tmp/stage bash install-vm.sh
#
#  可用环境变量覆盖探测结果：
#    SVC_USER=xxx SVC_HOME=/home/xxx SVC_BIN=/path/to/dsh LOCAL_PORT=3080 bash install-vm.sh
#    REPO_URL=https://github.com/you/vm-reverse-tunnel   # 默认从 git remote 推导
# ============================================================================
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESTDIR="${DESTDIR:-}"
ROOT="${DESTDIR%/}"
BIN_DST="$ROOT/usr/local/bin/dsh-tunnel.sh"
UNIT_DIR="$ROOT/etc/systemd/system"
DEFAULT_DST="$ROOT/etc/default/dsh-tunnel"

die() { echo "错误：$*" >&2; exit 1; }

# DESTDIR 模式是"预演安装"，不碰系统，因此不要求 root
if [ "$(id -u)" -ne 0 ] && [ -z "$DESTDIR" ]; then
  die "必须以 root 运行（仅 DESTDIR 预演可以非 root）"
fi

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
[ -n "$SVC_HOME" ] || die "拿不到用户 $SVC_USER 的家目录"

# dsh 的 shebang 是 #!/usr/bin/env node，所以 unit 的 PATH 里要有 node 所在目录
NODE_BIN_DIR="$(dirname "$(command -v node 2>/dev/null || printf '%s' "$SVC_BIN")")"

# ── 仓库地址：从 git remote 推导，推不出来就退回本地 README ─────────────────
# （以前这里留了字面量 .../OWNER/...，装完之后 systemctl status 里是个死链）
REPO_URL="${REPO_URL:-}"
if [ -z "$REPO_URL" ] && command -v git >/dev/null 2>&1; then
  REPO_URL="$(git -C "$SRC_DIR" config --get remote.origin.url 2>/dev/null || true)"
fi
case "$REPO_URL" in
  git@github.com:*)        REPO_URL="https://github.com/${REPO_URL#git@github.com:}" ;;
  ssh://git@github.com/*)  REPO_URL="https://github.com/${REPO_URL#ssh://git@github.com/}" ;;
esac
REPO_URL="${REPO_URL%.git}"
[ -n "$REPO_URL" ] || REPO_URL="file:$SRC_DIR/README.md"

echo "[install-vm] SVC_USER=$SVC_USER"
echo "[install-vm] SVC_HOME=$SVC_HOME"
echo "[install-vm] SVC_BIN=$SVC_BIN"
echo "[install-vm] LOCAL_PORT=$LOCAL_PORT"
echo "[install-vm] REPO_URL=$REPO_URL"
[ -n "$DESTDIR" ] && echo "[install-vm] DESTDIR=$DESTDIR（预演模式：跳过 systemctl）"

render() {  # render <模板> <目标>
  sed -e "s|@SVC_USER@|$SVC_USER|g" \
      -e "s|@SVC_HOME@|$SVC_HOME|g" \
      -e "s|@SVC_BIN@|$SVC_BIN|g" \
      -e "s|@NODE_BIN_DIR@|$NODE_BIN_DIR|g" \
      -e "s|@LOCAL_PORT@|$LOCAL_PORT|g" \
      -e "s|@REPO_URL@|$REPO_URL|g" \
      "$1" > "$2"
}

mkdir -p "$(dirname "$BIN_DST")" "$UNIT_DIR" "$(dirname "$DEFAULT_DST")"

echo "[install-vm] 安装 $BIN_DST"
install -m 0755 "$SRC_DIR/tunnel.sh" "$BIN_DST"

# 辅助命令：不装的话，用户删掉克隆目录后 README 里的 bash url.sh / verify.sh 就没了
BIN_DIR="$(dirname "$BIN_DST")"
for f in url.sh verify.sh setup-key.sh uninstall.sh; do
  install -m 0755 "$SRC_DIR/$f" "$BIN_DIR/vmrt-${f%.sh}"
done
echo "[install-vm] 安装辅助命令：$BIN_DIR/vmrt-{url,verify,setup-key,uninstall}"

for u in dsh-web dsh-tunnel; do
  echo "[install-vm] 生成 $UNIT_DIR/$u.service"
  render "$SRC_DIR/units/$u.service.in" "$UNIT_DIR/$u.service"
  chmod 0644 "$UNIT_DIR/$u.service"
  # 兜底：任何 @XXX@ 没被替换都说明模板和渲染逻辑不同步
  if grep -nE '@[A-Z_]+@' "$UNIT_DIR/$u.service"; then
    die "$u.service 里残留未替换的占位符（见上面几行）"
  fi
done

if [ -f "$DEFAULT_DST" ]; then
  echo "[install-vm] 保留已有配置 $DEFAULT_DST（未覆盖）"
else
  echo "[install-vm] 生成默认配置 $DEFAULT_DST"
  render "$SRC_DIR/dsh-tunnel.default" "$DEFAULT_DST" || die "渲染 $DEFAULT_DST 失败"
  chmod 0644 "$DEFAULT_DST"
fi

if command -v systemd-analyze >/dev/null 2>&1; then
  echo "[install-vm] unit 校验："
  # DESTDIR 预演模式下 ExecStart 指向的文件还没进 /usr/local/bin，忽略这一条
  systemd-analyze verify "$UNIT_DIR/dsh-web.service" "$UNIT_DIR/dsh-tunnel.service" 2>&1 \
    | grep -v 'is not executable' || true
fi

if [ -z "$DESTDIR" ]; then
  systemctl daemon-reload
  systemctl enable dsh-web.service dsh-tunnel.service
  echo "[install-vm] 已 enable：$(systemctl is-enabled dsh-web.service dsh-tunnel.service 2>&1 | tr '\n' ' ')"

  if [ "${1:-}" = "--start" ]; then
    echo "[install-vm] --start：立即启动（会断开当前 Web 会话）"
    systemctl start dsh-web.service
    systemctl start dsh-tunnel.service
  fi
else
  echo "[install-vm] DESTDIR 预演完成：$DESTDIR"
fi

cat <<'EOF'

下一步：
  1) 配好 虚拟机 → 宿主机 免密：  bash setup-key.sh
  2) 平滑切换（带预检，推荐）：    bash switch-now.sh
  3) 体检：                       bash verify.sh
  4) 拿登录 URL：                 bash url.sh
  卸载：                           sudo bash uninstall.sh
EOF
