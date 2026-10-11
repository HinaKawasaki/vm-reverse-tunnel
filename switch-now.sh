#!/usr/bin/env bash
# ============================================================================
#  switch-now.sh —— 在【虚拟机】内以 root 执行：一键把「手动启动的 dsh web」
#  平滑切换成 systemd 托管（dsh-web.service + dsh-tunnel.service）。
#  用户/家目录/dsh 路径/端口都从 /etc/default/dsh-tunnel 读取（install-vm.sh 生成）。
#
#  为什么默认要“分离”：本脚本会杀掉 dsh web，如果你恰好是在 dsh GUI 自带的
#  终端里运行，脚本会跟着一起被杀。注意 setsid 只换会话、不换 cgroup —— 终端
#  所在会话结束时 logind 会把整个 cgroup 一起 SIGKILL，连 setsid 的子进程也
#  跑不掉。所以这里优先用 systemd-run 起一个独立的 transient unit。
#
#  流程（顺序经过设计：即使脚本中途被杀，两个服务也会自己接管）：
#   0) 确认 → 用 systemd-run 分离到独立单元（失败则退回 setsid + 校验）；
#   1) 预检：在临时端口 3099 用与 service 相同的参数起一个 dsh，确认服务方式
#      真能跑起来；失败则中止，绝不动当前会话；
#   2) 安装 unit 并 enable；
#   3) 停掉旧隧道服务 + 清理残留的手动隧道实例（否则它们占着宿主机落地端口）；
#   4) 先把两个服务都 start —— dsh-web 因 3080 被手动实例占着会绑定失败并按
#      Restart=always 反复重试；dsh-tunnel 自己会等 3080 就绪再建隧道；
#   5) 杀掉手动启动的 dsh web（你当前的 Web GUI 会话到此断开）；           ← Agent 会话
#      此时第 4 步的 dsh-web.service 会立刻抢到 3080 自己接管；
#   6) 等 127.0.0.1:3080 重新就绪（服务已接管）；
#   7) 等隧道日志出现「隧道已建立」，打印结果与排障命令。
#
#  用法：
#    bash switch-now.sh            # 交互确认后转后台（推荐）
#    bash switch-now.sh -y         # 不问，直接转后台
#    bash switch-now.sh -f         # 前台跑（进度直接打在终端，最简单直观）
#
#  进度查看： tail -f /var/log/dsh-switch.log
# ============================================================================
set -uo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
SRC_DIR="$(dirname "$SELF")"
CONF=/etc/default/dsh-tunnel
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"
LOG=/var/log/dsh-switch.log
SVC_USER="${SVC_USER:-$(id -un)}"
SVC_HOME="${SVC_HOME:-$(getent passwd "$SVC_USER" | cut -d: -f6)}"
SVC_BIN="${SVC_BIN:-$(command -v dsh || true)}"
SVC_PATH="$(dirname "$SVC_BIN"):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
LOCAL_PORT="${LOCAL_PORT:-3080}"
PREFLIGHT_PORT="${PREFLIGHT_PORT:-3099}"
PREFLIGHT="${PREFLIGHT:-1}"
FOREGROUND=0
SKIP_CONFIRM=0

for _a in "$@"; do
  case "$_a" in
    -f|--foreground) FOREGROUND=1 ;;
    -y|--yes)        SKIP_CONFIRM=1 ;;
  esac
done

log() { printf '%s [switch] %s\n' "$(date '+%F %T')" "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "错误：必须以 root 运行（虚拟机内没有 sudo，请用 root shell）" >&2; exit 1; }

# ── 分离：优先 systemd-run（独立 cgroup，免疫会话清理），退路 setsid ────────
if [ "$FOREGROUND" -eq 0 ] && [ "${DSH_SWITCH_DETACHED:-0}" != "1" ]; then
  if [ "$SKIP_CONFIRM" -eq 0 ] && [ -t 0 ]; then
    echo "即将：杀掉当前手动启动的 dsh web，改由 systemd 托管。"
    echo "影响：当前 Web GUI 会话会断开（会话记录已持久化，重连后仍在侧栏）。"
    read -r -p "继续？[y/N] " ans
    [ "${ans:-n}" = "y" ] || { echo "已取消"; exit 1; }
  fi
  : >>"$LOG"; chmod 0644 "$LOG" 2>/dev/null || true
  unit="dsh-switch-$(date +%s)"
  if command -v systemd-run >/dev/null 2>&1 && \
     systemd-run --unit="$unit" --collect \
       --description="dsh web 切换到 systemd 托管" \
       --setenv=DSH_SWITCH_DETACHED=1 \
       bash "$SELF" -y >/dev/null 2>&1; then
    echo "已作为独立 systemd 单元启动： $unit"
    echo "  （不受终端/会话退出影响；systemctl status $unit 可看状态）"
  else
    DSH_SWITCH_DETACHED=1 setsid nohup bash "$SELF" -y </dev/null >>"$LOG" 2>&1 &
    echo "已用 setsid 分离启动（pid $!）"
  fi

  # 校验子进程真的开始干活了；没有再报错，绝不静默失败
  for _ in $(seq 1 15); do
    if grep -q '开始切换到 systemd 托管' "$LOG" 2>/dev/null; then
      echo "已在后台开始执行。进度： tail -f $LOG"
      exit 0
    fi
    sleep 1
  done
  {
    echo "!! 后台任务 15 秒内没有产生任何日志，多半被会话清理杀掉了。"
    echo "   请改用前台方式（在 root SSH 终端里最稳）： bash $SELF -f"
    echo "   ---- $LOG 当前内容 ----"
    tail -20 "$LOG" 2>/dev/null
  } >&2
  exit 1
fi

: >>"$LOG" 2>/dev/null || true
if [ "${DSH_SWITCH_DETACHED:-0}" = "1" ]; then
  exec >>"$LOG" 2>&1            # 后台：全部进日志
else
  exec > >(tee -a "$LOG") 2>&1  # 前台：终端可见，同时留一份日志
fi
log "===== 开始切换到 systemd 托管（PID $$）====="

# ── 1) 预检：同样参数换端口先验证一遍 ─────────────────────────────────────
if [ "$PREFLIGHT" = "1" ]; then
  log "预检：用同样参数在 127.0.0.1:${PREFLIGHT_PORT} 试启动 dsh web"
  su "$SVC_USER" -c "cd $SVC_HOME && HOME=$SVC_HOME DSH_HOME=$SVC_HOME/.dsh PATH=$SVC_PATH exec $SVC_BIN web --host 127.0.0.1 --port $PREFLIGHT_PORT --no-open" \
    >>"$LOG" 2>&1 &
  pf_pid=$!
  pf_code=000
  for _ in $(seq 1 40); do
    pf_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:${PREFLIGHT_PORT}/" || true)
    [ "$pf_code" != "000" ] && break
    kill -0 "$pf_pid" 2>/dev/null || break
    sleep 1
  done
  kill -TERM "$pf_pid" 2>/dev/null
  wait "$pf_pid" 2>/dev/null
  sleep 1
  # su 不一定转发信号，按端口找残留进程收尸
  pkill -TERM -f "port 309[9]" 2>/dev/null || true
  sleep 1
  pkill -KILL -f "port 309[9]" 2>/dev/null || true
  if [ "$pf_code" = "000" ]; then
    log "预检失败：dsh web 在 ${PREFLIGHT_PORT} 上没能起来（HTTP=$pf_code）。"
    log "已中止，当前会话保持原样。请检查下面日志。"
    exit 1
  fi
  log "预检通过（HTTP $pf_code，401 = 需要 token，属正常）"
fi

# ── 2) 安装 ────────────────────────────────────────────────────────────────
bash "$SRC_DIR/install-vm.sh" || { log "安装失败，中止"; exit 1; }

# ── 3) 清理：停掉旧的隧道服务与任何残留的手动隧道实例 ──────────────────────
# （必须在启动 dsh-tunnel.service 之前做，否则会误杀服务自己的脚本；
#   残留实例会占着宿主机落地端口，让服务版隧道两个候选都撞车）
if systemctl is-active --quiet dsh-tunnel.service; then
  log "先停止已在运行的 dsh-tunnel.service"
  systemctl stop dsh-tunnel.service
  sleep 1
fi
mapfile -t stale_tunnels < <(pgrep -f 'tunnel[.]sh' || true)
if [ "${#stale_tunnels[@]}" -gt 0 ]; then
  log "清理残留的手动隧道实例：${stale_tunnels[*]}"
  kill -TERM "${stale_tunnels[@]}" 2>/dev/null || true
  sleep 2
  mapfile -t stale_tunnels < <(pgrep -f 'tunnel[.]sh' || true)
  if [ "${#stale_tunnels[@]}" -gt 0 ]; then
    kill -KILL "${stale_tunnels[@]}" 2>/dev/null || true
  fi
fi

# ── 4) 两个服务都先起来，再杀 dsh（关键的自愈设计）────────────────────────
# dsh-web：此刻 3080 还被手动实例占着，它会绑定失败并按 Restart=always 反复重试；
# dsh-tunnel：脚本自己会等 3080 就绪（现在就能先连上手动的 dsh，之后无缝换到服务版）。
# 这样即使本脚本在下一步被杀，两个服务也会自己完成接管。
systemctl start dsh-web.service 2>/dev/null
log "dsh-web.service 已 start（若 3080 仍被占用会按 Restart=always 自动重试）"
systemctl start dsh-tunnel.service 2>/dev/null
log "dsh-tunnel.service 已 start（它会等 3080 就绪再建隧道）"

# ── 5) 杀掉手动启动的 dsh web ──────────────────────────────────────────────
if [ "$SKIP_CONFIRM" -eq 0 ]; then
  log "两个服务已就位。5 秒后杀掉当前 dsh web（这个 Web GUI 会断开）；要中止请按 Ctrl-C"
  sleep 5
fi
log "查找手动启动的 dsh web 进程"
mapfile -t victims < <(pgrep -u "$SVC_USER" -f 'bin/dsh web' || true)
if [ "${#victims[@]}" -gt 0 ]; then
  log "结束进程：${victims[*]}"
  kill -TERM "${victims[@]}" 2>/dev/null || true
  for _ in $(seq 1 15); do
    pgrep -u "$SVC_USER" -f 'bin/dsh web' >/dev/null 2>&1 || break
    sleep 1
  done
  mapfile -t victims < <(pgrep -u "$SVC_USER" -f 'bin/dsh web' || true)
  if [ "${#victims[@]}" -gt 0 ]; then
    log "仍有残留，强制结束：${victims[*]}"
    kill -KILL "${victims[@]}" 2>/dev/null || true
  fi
else
  log "没有找到手动启动的 dsh web（可能已经停了）"
fi

for _ in $(seq 1 15); do
  (exec 3<>/dev/tcp/127.0.0.1/"$LOCAL_PORT") >/dev/null 2>&1 || break
  sleep 1
done
log "3080 端口已释放（原 Agent 会话到此结束）"

# ── 6) 等服务接管 3080 ─────────────────────────────────────────────────────
web_code=000
logged_dead=0
for _ in $(seq 1 90); do
  web_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:${LOCAL_PORT}/ || true)
  [ "$web_code" != "000" ] && break
  if [ "$logged_dead" -eq 0 ] && ! systemctl is-active --quiet dsh-web.service; then
    logged_dead=1
    log "注意：dsh-web.service 当前不是 active，继续等待（Restart=always 会自动重试）"
  fi
  sleep 1
done
if [ "$web_code" = "000" ]; then
  log "dsh-web.service 启动失败（3080 无响应）。排障：journalctl -u dsh-web.service -n 50 --no-pager"
  exit 1
fi
log "dsh-web.service 已接管 127.0.0.1:3080（HTTP $web_code）"
log "已 enable：$(systemctl is-enabled dsh-web.service dsh-tunnel.service 2>&1 | tr '\n' ' ')"

# ── 7) 等隧道建立 ──────────────────────────────────────────────────────────
tunnel_ok=0
for _ in $(seq 1 40); do
  if journalctl -u dsh-tunnel.service --since '-3min' --no-pager 2>/dev/null | grep -q '隧道已建立'; then
    tunnel_ok=1; break
  fi
  sleep 1
done

echo
if [ "$tunnel_ok" -eq 1 ]; then
  log "桥接完成："
  journalctl -u dsh-tunnel.service --since '-3min' --no-pager | grep -E '隧道已建立|尝试反向隧道' | tail -5
else
  log "隧道尚未在 40s 内建立，请稍后看：journalctl -u dsh-tunnel.service -f"
fi

cat <<EOF

==================== 切换结果 ====================
 访问地址（宿主机侧，指向同一个 dsh）：
   http://127.0.0.1:3000     ← 隧道落地，当前即可用
   http://127.0.0.1:3080     ← 首选端口，VS Code 转发占用中；关掉 VS Code 后自动升级过去

 提示需要登录时，取带 token 的 URL：
   journalctl -u dsh-web.service | grep 'dsh web:' | tail -1

 健康检查：bash "$SRC_DIR/verify.sh"
 服务状态：systemctl status dsh-web.service dsh-tunnel.service
 隧道日志：journalctl -u dsh-tunnel.service -f
 本次日志：$LOG
==================================================
EOF
