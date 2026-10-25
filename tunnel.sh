#!/usr/bin/env bash
# ============================================================================
#  dsh-tunnel.sh — 在【虚拟机】内守护「宿主机 ⇠ 反向 SSH 隧道 ⇠ 虚拟机服务」
#
#   虚拟机 (guest)                                宿主机 (host, sshd)
#     本地服务 127.0.0.1:3080  ──ssh -R──▶     127.0.0.1:3080  （首选）
#                                              127.0.0.1:3000  （3080 被别的
#                                                               进程占用时回退）
#
#  行为：
#    1. 轮询虚拟机 127.0.0.1:LOCAL_PORT（bash /dev/tcp），服务没起来就等；
#    2. 按 HOST_PORT_CANDIDATES 顺序尝试建立反向隧道，第一个连得住 READY_GRACE
#       秒的视为成功（足以区分「端口被占用秒退」和「真的连上了」）；
#    3. 隧道存活期间每 HEALTH_CHECK_SEC 秒回探一次本地服务：服务挂了就主动
#       断开隧道触发重连，避免宿主机端口"假活着"（能连上但 502/refused）；
#    4. 隧道断开 → sleep RETRY_SEC → 回到第 1 步；
#    5. 若当前落在回退端口上，每 UPGRADE_CHECK_SEC 检查一次首选端口是否空出，
#       只在【确认为 FREE】时才主动断开重连升级；探测失败（UNKNOWN）不动；
#    6. 单实例锁：同一台机器上重复启动会直接退出，不会两份互抢端口；
#    7. 收到 SIGTERM/SIGINT 时收尸退出（systemd stop 用）。
#
#  可覆盖配置：/etc/default/dsh-tunnel（见 dsh-tunnel.default）
# ============================================================================
set -u

# ── 默认值：宿主机地址 = 本机默认网关（libvirt NAT 下它就是宿主机）─────────
default_gateway() { ip route show default 2>/dev/null | awk '{print $3; exit}'; }

# ── 配置 ────────────────────────────────────────────────────────────────────
CONF=/etc/default/dsh-tunnel
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"

SSH_HOST="${SSH_HOST:-$(default_gateway)}"                  # 宿主机地址（默认取默认网关）
SSH_PORT="${SSH_PORT:-22}"                                  # 宿主机 sshd 端口
SSH_USER="${SSH_USER:-$(id -un)}"                           # 宿主机登录账号
SSH_KEY="${SSH_KEY:-$HOME/.ssh/dsh-remote}"                 # 私钥（免密，方向：虚拟机 → 宿主机）
LOCAL_ADDR="${LOCAL_ADDR:-127.0.0.1}"                       # 虚拟机上本地服务的地址
LOCAL_PORT="${LOCAL_PORT:-3080}"                            # 虚拟机上本地服务的端口
HOST_ADDR="${HOST_ADDR:-127.0.0.1}"                         # 宿主机上隧道的绑定地址（局域网用 0.0.0.0）
HOST_PORT_CANDIDATES="${HOST_PORT_CANDIDATES:-3080 3000}"   # 宿主机落地端口，按优先级排列
READY_GRACE="${READY_GRACE:-4}"                             # 建连后观察几秒判定成功
RETRY_SEC="${RETRY_SEC:-3}"                                 # 重连间隔
UPGRADE_CHECK_SEC="${UPGRADE_CHECK_SEC:-60}"                # 回退状态下检查首选端口是否空出的间隔
HEALTH_CHECK_SEC="${HEALTH_CHECK_SEC:-3}"                   # 隧道存活期回探本地服务的间隔
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-10}"
DSH_POLL_SEC="${DSH_POLL_SEC:-2}"                           # 等本地服务就绪的轮询间隔
LOCK_FILE="${LOCK_FILE:-}"                                  # 单实例锁文件；留空=自动挑一个可写路径

# ── 工具 ────────────────────────────────────────────────────────────────────
log() { printf '%s [dsh-tunnel] %s\n' "$(date '+%F %T')" "$*"; }

SSH_OPTS=(
  -o ExitOnForwardFailure=yes
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=3
  -o StrictHostKeyChecking=accept-new
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o ConnectTimeout="$SSH_CONNECT_TIMEOUT"
  -i "$SSH_KEY"
  -p "$SSH_PORT"
)

TUNNEL_PID=""
WATCHDOG_PID=""
CURRENT_PORT=""

# 虚拟机上本地服务是否已监听（不依赖 ss/netstat）
dsh_ready() {
  (exec 3<>"/dev/tcp/${LOCAL_ADDR}/${LOCAL_PORT}") >/dev/null 2>&1
}

preferred_port() { printf '%s\n' "${HOST_PORT_CANDIDATES%% *}"; }

# ── 单实例锁：避免手动实例与 systemd 实例互抢端口 ───────────────────────────
acquire_lock() {
  local f="$LOCK_FILE"
  if [ -z "$f" ]; then
    f=/run/dsh-tunnel.lock
    # 非 root 时 /run 不可写，退到用户级临时目录
    : >>"$f" 2>/dev/null || f="${TMPDIR:-/tmp}/dsh-tunnel.$(id -u).lock"
  fi
  if ! exec 9>>"$f" 2>/dev/null; then
    log "警告：无法创建锁文件 ${f}，跳过单实例保护"
    return 0
  fi
  if ! flock -n 9; then
    log "已有实例在运行（锁 ${f}），本实例退出"
    exit 0
  fi
}

# 宿主机上某端口的状态：BUSY / FREE / UNKNOWN
# 关键：ss 不存在、ssh 连不上、输出看不懂，一律 UNKNOWN —— 绝不当作 FREE，
#       否则会每 UPGRADE_CHECK_SEC 秒误拆一条健康的隧道。
host_port_state() {
  local port="$1" out
  out=$(ssh -T "${SSH_OPTS[@]}" -o ClearAllForwardings=yes "$SSH_USER@$SSH_HOST" \
    "if ! command -v ss >/dev/null 2>&1; then echo UNKNOWN; exit 0; fi
     if ss -tlnH 2>/dev/null | awk '{print \$4}' | grep -qE '[:.]${port}\$'; then echo BUSY; else echo FREE; fi" \
    2>/dev/null) || true
  case "$out" in
    BUSY) printf 'BUSY' ;;
    FREE) printf 'FREE' ;;
    *)    printf 'UNKNOWN' ;;
  esac
}

stop_watchdog() {
  if [ -n "$WATCHDOG_PID" ]; then
    kill "$WATCHDOG_PID" 2>/dev/null
    WATCHDOG_PID=""
  fi
}

# 当隧道落在非首选端口时，周期性尝试“升级”回首选端口
start_watchdog() {
  local cur="$1" pref="$2" pid="$3"
  [ "$cur" = "$pref" ] && return 0
  (
    while sleep "$UPGRADE_CHECK_SEC"; do
      kill -0 "$pid" 2>/dev/null || exit 0
      case "$(host_port_state "$pref")" in
        FREE)
          log "首选端口 ${pref} 已空出，主动重连以升级回 ${pref}"
          kill -TERM "$pid" 2>/dev/null
          exit 0
          ;;
        BUSY)
          : ;;  # 首选仍被占，继续等
        *)
          log "无法确认首选端口 ${pref} 是否空出（探测失败），本轮不升级"
          ;;
      esac
    done
  ) &
  WATCHDOG_PID=$!
}

cleanup() {
  log "收到停止信号，收尸退出（当前隧道端口：${CURRENT_PORT:-无}）"
  stop_watchdog
  if [ -n "$TUNNEL_PID" ]; then kill -TERM "$TUNNEL_PID" 2>/dev/null; fi
  exit 0
}
trap cleanup TERM INT

# ── 主循环 ──────────────────────────────────────────────────────────────────
main() {
  local pref port pid rc established
  acquire_lock
  pref=$(preferred_port)
  log "启动：${SSH_USER}@${SSH_HOST}:${SSH_PORT}  ←  落地端口候选 [${HOST_PORT_CANDIDATES}]  →  ${LOCAL_ADDR}:${LOCAL_PORT}（绑定 ${HOST_ADDR}）"

  while :; do
    while ! dsh_ready; do
      log "等待本地服务就绪（${LOCAL_ADDR}:${LOCAL_PORT}）..."
      sleep "$DSH_POLL_SEC"
    done

    established=0
    for port in $HOST_PORT_CANDIDATES; do
      log "尝试反向隧道 ${HOST_ADDR}:${port} -> ${LOCAL_ADDR}:${LOCAL_PORT}"
      ssh -N -T "${SSH_OPTS[@]}" \
        -R "${HOST_ADDR}:${port}:${LOCAL_ADDR}:${LOCAL_PORT}" \
        "$SSH_USER@$SSH_HOST" &
      pid=$!
      TUNNEL_PID=$pid

      sleep "$READY_GRACE"
      if kill -0 "$pid" 2>/dev/null; then
        established=1
        CURRENT_PORT=$port
        log "隧道已建立（ssh pid ${pid}，宿主机 ${HOST_ADDR}:${port} -> 本地服务 ${LOCAL_ADDR}:${LOCAL_PORT}）"
        start_watchdog "$port" "$pref" "$pid"

        # 存活期健康检查：本地服务挂了就主动断隧道，别让宿主机端口"假活着"
        while kill -0 "$pid" 2>/dev/null; do
          sleep "$HEALTH_CHECK_SEC"
          kill -0 "$pid" 2>/dev/null || break
          if ! dsh_ready; then
            log "本地服务 ${LOCAL_ADDR}:${LOCAL_PORT} 失联，主动断开隧道以触发重连"
            kill -TERM "$pid" 2>/dev/null
            break
          fi
        done

        wait "$pid"
        rc=$?
        stop_watchdog
        log "隧道断开（ssh 退出码 ${rc}），${RETRY_SEC}s 后重连"
        break
      fi

      wait "$pid" 2>/dev/null
      log "落地端口 ${port} 建立失败（多半已被占用），尝试下一个候选"
    done

    if [ "$established" -eq 0 ]; then
      log "候选端口全部失败 [${HOST_PORT_CANDIDATES}]，${RETRY_SEC}s 后重试"
    fi
    TUNNEL_PID=""
    CURRENT_PORT=""
    sleep "$RETRY_SEC"
  done
}

main "$@"
