#!/usr/bin/env bash
# ============================================================================
#  uninstall.sh —— 在【虚拟机】内以 root 执行：把本项目装进去的东西删干净
#
#  它会清理：
#    虚拟机侧： dsh-web.service / dsh-tunnel.service、/usr/local/bin/dsh-tunnel.sh、
#               /etc/default/dsh-tunnel、切换日志
#    宿主机侧（可选，需在宿主机上执行）：install-host.sh 写的
#               /etc/ssh/sshd_config.d/10-dsh-tunnel.conf 与 ufw 规则
#
#  以前 README 只教了删 unit 和脚本，sshd 的 GatewayPorts 与 ufw 规则会残留，
#  等于"以为卸载了，其实局域网还通着"——这个脚本就是补这个洞。
#
#  用法：
#    sudo bash uninstall.sh                 # 交互确认后清理（虚拟机侧）
#    sudo bash uninstall.sh -y              # 不问
#    sudo bash uninstall.sh --dry-run       # 只打印要删什么
#    sudo bash uninstall.sh --purge-host    # 连宿主机侧的 GatewayPorts/ufw 一起清（在宿主机上跑）
#    sudo bash uninstall.sh --keep-config   # 保留 /etc/default/dsh-tunnel
# ============================================================================
set -uo pipefail

UNIT_DIR=/etc/systemd/system
BIN=/usr/local/bin/dsh-tunnel.sh
CONF=/etc/default/dsh-tunnel
SWITCH_LOG=/var/log/dsh-switch.log
SSHD_DROPIN=/etc/ssh/sshd_config.d/10-dsh-tunnel.conf
UFW_PORTS="${UFW_PORTS:-3000 3080}"

ASSUME_YES=0
DRY_RUN=0
PURGE_HOST=0
KEEP_CONFIG=0

for a in "$@"; do
  case "$a" in
    -y|--yes)         ASSUME_YES=1 ;;
    -n|--dry-run)     DRY_RUN=1 ;;
    --purge-host)     PURGE_HOST=1 ;;
    --keep-config)    KEEP_CONFIG=1 ;;
    -h|--help)        sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$a（-h 看用法）" >&2; exit 2 ;;
  esac
done

die() { echo "错误：$*" >&2; exit 1; }
say() { printf '[uninstall] %s\n' "$*"; }
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  would: %s\n' "$*"
  else
    "$@" 2>/dev/null || true
  fi
}

[ "$(id -u)" -eq 0 ] || [ "$DRY_RUN" -eq 1 ] || die "必须以 root 运行（--dry-run 例外）"

if [ "$ASSUME_YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  cat <<'EOF'
将停止并删除：
  dsh-web.service / dsh-tunnel.service（含 enable 链接）
  /usr/local/bin/dsh-tunnel.sh
  /etc/default/dsh-tunnel
  /var/log/dsh-switch.log
如果你正在通过隧道访问这个 Web GUI，执行后就会断开（数据已持久化，恢复需重新安装）。
EOF
  read -r -p "继续？[y/N] " ans
  [ "${ans:-n}" = "y" ] || { echo "已取消"; exit 1; }
fi

say "停止并禁用服务"
for u in dsh-tunnel.service dsh-web.service; do
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  would: systemctl disable --now %s\n' "$u"
  else
    systemctl disable --now "$u" 2>/dev/null || true
  fi
  run rm -f "$UNIT_DIR/$u"
done

say "删除脚本与配置"
run rm -f "$BIN"
for f in url verify setup-key uninstall; do
  run rm -f "/usr/local/bin/vmrt-${f}"
done
[ "$KEEP_CONFIG" -eq 1 ] && say "保留 $CONF（--keep-config）" || run rm -f "$CONF"
run rm -f "$SWITCH_LOG"

if [ "$DRY_RUN" -eq 0 ]; then
  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed 2>/dev/null || true
fi

# ── 宿主机侧（GatewayPorts + ufw）───────────────────────────────────────────
if [ "$PURGE_HOST" -eq 1 ]; then
  if [ -f "$SSHD_DROPIN" ]; then
    say "删除 $SSHD_DROPIN 并重载 sshd"
    run rm -f "$SSHD_DROPIN"
    if [ "$DRY_RUN" -eq 0 ]; then
      if sshd -t 2>/dev/null; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || \
          say "警告：sshd 重载失败，请手动 systemctl reload sshd"
      else
        say "警告：sshd 配置校验失败，未重载；请检查后手动处理"
      fi
    fi
  else
    say "$SSHD_DROPIN 不存在，跳过"
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    for p in $UFW_PORTS; do
      say "ufw delete allow ${p}/tcp"
      run ufw delete allow "${p}/tcp"
    done
  else
    say "ufw 未启用，跳过防火墙规则清理"
  fi
else
  say "未清理宿主机侧（GatewayPorts / ufw）。要清请在【宿主机】上执行： sudo bash uninstall.sh --purge-host"
fi

say "完成。建议再确认一下："
cat <<'EOF'
  systemctl status dsh-web.service dsh-tunnel.service   # 应显示 not-found
  ss -tlnp | grep -E ':(3080|3000)\b'                   # 不应再有残留监听
  # 宿主机侧：sshd -T | grep -i gatewayports              # 应回到默认 no
EOF
