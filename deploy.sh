#!/usr/bin/env bash
# ============================================================================
#  deploy.sh —— 把【仓库】部署到本机：仓库是唯一源，本机差异只写在 local.env
#
#  背景：v0.1/v0.2 的用法是"克隆一份、手改里面的地址和端口"，于是仓库里的
#  通用值和机器上的私有值会各自漂移，改了一边另一边永远收不到。
#  现在把私有值全部收进一个 gitignored 的 local.env，由本脚本渲染安装。
#
#  用法：
#    cp local.env.example local.env && vi local.env   # 只写本机差异
#    sudo bash deploy.sh                # 安装 unit/脚本 + 生成 /etc/default/dsh-tunnel
#    sudo bash deploy.sh --restart      # 装完顺手重启隧道服务
#    bash deploy.sh --dry-run           # 不碰系统：渲染到临时目录，只看结果
#
#  说明：
#    - local.env 里的键会被写进 /etc/default/dsh-tunnel 的「托管块」，
#      重跑 deploy.sh 会整体替换该块（块外的自定义内容保持不动）。
#    - 真的安装动作交给 install-vm.sh（它支持 DESTDIR），本脚本只负责
#      合并配置、daemon-reload、enable。
# ============================================================================
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_ENV="${LOCAL_ENV:-$SELF_DIR/local.env}"
DESTDIR=""
DRY_RUN=0
RESTART=0
CONF=/etc/default/dsh-tunnel

BEGIN_MARK='# >>> vm-reverse-tunnel local.env（deploy.sh 托管，重跑会整体替换）>>>'
END_MARK='# <<< vm-reverse-tunnel local.env <<<'

die() { echo "错误：$*" >&2; exit 1; }
say() { printf '[deploy] %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)        DRY_RUN=1 ;;
    --restart)        RESTART=1 ;;
    --env)            shift; LOCAL_ENV="${1:?--env 需要一个路径}" ;;
    --destdir)        shift; DESTDIR="${1:?--destdir 需要一个路径}" ;;
    -h|--help)        sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知参数：$1（-h 看用法）" ;;
  esac
  shift
done

# 允许的键：只把这些写进托管块，避免把任意变量灌进 service 环境
ALLOWED_KEYS='SVC_USER SVC_HOME SVC_BIN LOCAL_ADDR LOCAL_PORT
SSH_HOST SSH_PORT SSH_USER SSH_KEY HOST_ADDR HOST_PORT_CANDIDATES
SERVICE_LABEL HEALTH_URL READY_GRACE RETRY_SEC UPGRADE_CHECK_SEC
HEALTH_CHECK_SEC DSH_POLL_SEC LOCK_FILE'

if [ -f "$LOCAL_ENV" ]; then
  say "读取本机配置：$LOCAL_ENV"
  set -a
  # shellcheck disable=SC1090  # 本机私有配置，路径由 --env/LOCAL_ENV 决定
  . "$LOCAL_ENV"
  set +a
else
  say "注意：没有 $LOCAL_ENV，将使用仓库默认值（cp local.env.example local.env 可定制）"
fi

[ -n "${HOST_PORT_CANDIDATES:-}" ] || die "HOST_PORT_CANDIDATES 不能为空"

# 虚拟机端口与宿主机落地端口在【两台机器】上，允许相同（默认就是 3080 -> 3080）。
# 只有把隧道打到本机（SSH_HOST=127.0.0.1/localhost）时才会真自撞。
case "${SSH_HOST:-}" in
  127.0.0.1|localhost|::1)
    case " ${HOST_PORT_CANDIDATES} " in
      *" ${LOCAL_PORT:-3080} "*) die "SSH_HOST 是本机时，落地端口不能与 LOCAL_PORT(${LOCAL_PORT:-3080}) 相同" ;;
    esac
    ;;
esac

TMP_STAGE=""
if [ "$DRY_RUN" -eq 1 ] && [ -z "$DESTDIR" ]; then
  TMP_STAGE="$(mktemp -d /tmp/vmrt-deploy.XXXXXX)"
  DESTDIR="$TMP_STAGE"
  say "dry-run：渲染到 $DESTDIR"
fi

# ── 1) 安装（unit / 脚本 / 模板配置）──────────────────────────────────────
install_env=(DESTDIR="$DESTDIR")
[ -n "${SVC_USER:-}" ] && install_env+=(SVC_USER="$SVC_USER")
[ -n "${SVC_HOME:-}" ] && install_env+=(SVC_HOME="$SVC_HOME")
[ -n "${SVC_BIN:-}" ]  && install_env+=(SVC_BIN="$SVC_BIN")
[ -n "${LOCAL_PORT:-}" ] && install_env+=(LOCAL_PORT="$LOCAL_PORT")
[ -n "${REPO_URL:-}" ] && install_env+=(REPO_URL="$REPO_URL")

say "调用 install-vm.sh（DESTDIR=${DESTDIR:-/}）"
env "${install_env[@]}" bash "$SELF_DIR/install-vm.sh" >/dev/null || die "install-vm.sh 失败"

CONF_PATH="${DESTDIR%/}$CONF"

# ── 2) 把 local.env 的值合并进配置文件的托管块 ─────────────────────────────
BLOCK="$(mktemp)"
cleanup() {
  rm -f "$BLOCK"
  if [ -n "${TMP_STAGE:-}" ]; then rm -rf "$TMP_STAGE"; fi
  return 0
}
trap cleanup EXIT

if [ -f "$LOCAL_ENV" ]; then
  for k in $ALLOWED_KEYS; do
    if grep -qE "^[[:space:]]*${k}=" "$LOCAL_ENV"; then
      # 取最后一次赋值，去掉行尾注释，保持原样引号
      line="$(grep -E "^[[:space:]]*${k}=" "$LOCAL_ENV" | tail -1 | sed 's/^[[:space:]]*//')"
      printf '%s\n' "$line" >> "$BLOCK"
    fi
  done
fi

mkdir -p "$(dirname "$CONF_PATH")"
[ -f "$CONF_PATH" ] || : > "$CONF_PATH"

if [ -s "$BLOCK" ]; then
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    skip != 1 { print }
  ' "$CONF_PATH" > "$CONF_PATH.new"
  { cat "$CONF_PATH.new"; printf '%s\n' "$BEGIN_MARK"; cat "$BLOCK"; printf '%s\n' "$END_MARK"; } \
    > "$CONF_PATH"
  rm -f "$CONF_PATH.new"
  say "已更新 $CONF_PATH 的托管块（$(wc -l < "$BLOCK") 项）"
else
  say "local.env 里没有可写入的键，$CONF_PATH 保持模板默认值"
fi

# ── 3) 生效 ────────────────────────────────────────────────────────────────
if [ "$DRY_RUN" -eq 1 ]; then
  say "dry-run 结果："
  echo "  ---- $CONF_PATH （托管块部分）----"
  sed -n "/^${BEGIN_MARK//\//\\/}\$/,/^${END_MARK//\//\\/}\$/p" "$CONF_PATH" | sed 's/^/  /'
  echo "  ---- units ----"
  ls -1 "$DESTDIR/etc/systemd/system" | sed 's/^/  /'
  echo "  ---- 脚本 ----"
  ls -1 "$DESTDIR/usr/local/bin" | sed 's/^/  /'
  say "dry-run 结束（未改动系统）。去掉 --dry-run 即真正安装。"
  exit 0
fi

[ "$(id -u)" -eq 0 ] || die "真正安装需要 root（只想看效果请加 --dry-run）"

systemctl daemon-reload
systemctl enable dsh-web.service dsh-tunnel.service >/dev/null 2>&1 || true
say "已 enable：$(systemctl is-enabled dsh-web.service dsh-tunnel.service 2>&1 | tr '\n' ' ')"

if [ "$RESTART" -eq 1 ]; then
  systemctl restart dsh-tunnel.service
  say "已重启 dsh-tunnel.service"
fi

cat <<EOF

下一步：
  systemctl status dsh-web.service dsh-tunnel.service
  journalctl -u dsh-tunnel.service -f
  vmrt-verify      # 端到端体检
  vmrt-url         # 当前有效的登录 URL
EOF
