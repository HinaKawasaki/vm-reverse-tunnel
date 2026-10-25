#!/usr/bin/env bash
# ============================================================================
#  tests/e2e.sh —— tunnel.sh 状态机端到端测试
#
#  设计：让【同一台机器】同时扮演 guest 与 host。
#    guest 侧：tunnel.sh + 一个假 backend（python3 http.server）
#    host  侧：本机 sshd（127.0.0.1:22），ssh -R 的落点
#
#  这样不需要 libvirt、不需要两台机器，但走的是真实 sshd 的 TCP 转发，
#  足以覆盖 "就绪等待 / 首选端口被占回退 / 空出后升级 / 断线重连 / 收尸"。
#  前提：当前用户能免密 ssh 到 SSH_HOST_T（默认 127.0.0.1），且 sshd 允许 -R。
#
#  用法：
#    bash tests/e2e.sh [tunnel.sh 路径]
#  环境变量：
#    SSH_USER_T/SSH_PORT_T/SSH_KEY_T   回环登录用的账号/端口/私钥
#    LOCAL_PORT_T                      假 backend 端口（默认 18080）
#    PREFERRED/FALLBACK                宿主机落地端口（默认 13080 / 13000）
# ============================================================================
set -uo pipefail

TUNNEL_SH="${1:-${TUNNEL_SH:-./tunnel.sh}}"
SSH_USER_T="${SSH_USER_T:-$(id -un)}"
SSH_HOST_T="${SSH_HOST_T:-127.0.0.1}"
SSH_PORT_T="${SSH_PORT_T:-22}"
LOCAL_PORT_T="${LOCAL_PORT_T:-18080}"
PREFERRED="${PREFERRED:-13080}"
FALLBACK="${FALLBACK:-13000}"

W="$(mktemp -d /tmp/vrt-e2e.XXXXXX)"
BACKEND_PID=""; SQUAT_PID=""; TUN_PID=""
pass=0; fail=0; bugs=0

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=$((fail+1)); }
bug()  { printf '  \033[35m🐞\033[0m %s\n' "$*"; bugs=$((bugs+1)); }
inf()  { printf '  \033[33m•\033[0m %s\n' "$*"; }
sec()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

cleanup() {
  [ -n "$TUN_PID" ] && kill -TERM -"$TUN_PID" 2>/dev/null
  [ -n "$BACKEND_PID" ] && kill "$BACKEND_PID" 2>/dev/null
  [ -n "$SQUAT_PID" ] && kill "$SQUAT_PID" 2>/dev/null
  pkill -f "http.server ${LOCAL_PORT_T}" 2>/dev/null
  pkill -f "vrt-squat.*${PREFERRED}\|vrt-squat.*${FALLBACK}" 2>/dev/null
  # 清掉测试用的免密公钥与本机 known_hosts 里为测试新增的条目（尽力而为）
  [ -f "$W/id.pub" ] && sed -i -e "\|$(cut -d' ' -f2 "$W/id.pub")|d" "$HOME/.ssh/authorized_keys" 2>/dev/null
  rm -rf "$W"
}
trap cleanup EXIT INT TERM

# ── 前置检查 ────────────────────────────────────────────────────────────────
sec "0. 环境准备"
[ -f "$TUNNEL_SH" ] || { echo "找不到 $TUNNEL_SH"; exit 2; }
for c in ssh python3 curl ss; do
  command -v "$c" >/dev/null || { echo "缺少命令：$c"; exit 2; }
done

# 一次性测试密钥：不把真实私钥拷到测试机
SSH_KEY_T="${SSH_KEY_T:-$W/id}"
if [ ! -f "$SSH_KEY_T" ]; then
  ssh-keygen -q -t ed25519 -N '' -C "vrt-e2e-test" -f "$SSH_KEY_T" || exit 2
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  cat "$SSH_KEY_T.pub" >> "$HOME/.ssh/authorized_keys"
  chmod 600 "$HOME/.ssh/authorized_keys"
fi
inf "测试密钥：$SSH_KEY_T"

if ! ssh -i "$SSH_KEY_T" -p "$SSH_PORT_T" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        -o IdentitiesOnly=yes -o ConnectTimeout=5 "$SSH_USER_T@$SSH_HOST_T" true 2>/dev/null; then
  echo "无法免密登录 ${SSH_USER_T}@${SSH_HOST_T}:${SSH_PORT_T}，测试无法进行"
  exit 2
fi
ok "回环 sshd 可登录（${SSH_USER_T}@${SSH_HOST_T}:${SSH_PORT_T}）"

# sshd 是否允许 -R（有些云镜像会关掉）
if ssh -i "$SSH_KEY_T" -p "$SSH_PORT_T" -o BatchMode=yes -o IdentitiesOnly=yes \
      -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes \
      -o ConnectTimeout=5 "$SSH_USER_T@$SSH_HOST_T" \
      -R "127.0.0.1:${FALLBACK}:127.0.0.1:${LOCAL_PORT_T}" -N -f 2>/dev/null; then
  sleep 1
  if ss -tlnH | grep -q ":${FALLBACK}\b"; then ok "sshd 允许 -R（GatewayPorts 默认值可用）"; else bad "sshd 接受连接但没有监听 ${FALLBACK}"; fi
  pkill -f "ssh.*127.0.0.1:${FALLBACK}" 2>/dev/null
else
  bad "sshd 拒绝 -R 转发（检查 AllowTcpForwarding / Match 块）"
fi

for p in "$LOCAL_PORT_T" "$PREFERRED" "$FALLBACK"; do
  if ss -tlnH | grep -q ":${p}\b"; then echo "端口 $p 已被占用，换个值再跑"; exit 2; fi
done
ok "端口 ${LOCAL_PORT_T}/${PREFERRED}/${FALLBACK} 空闲"

mkdir -p "$W/www" && printf 'vrt-e2e-%s\n' "$(date +%s)" > "$W/www/marker.txt"
MARKER="$(cat "$W/www/marker.txt")"

# ── 工具 ────────────────────────────────────────────────────────────────────
start_backend() {
  ( cd "$W/www" && exec python3 -m http.server "$LOCAL_PORT_T" --bind 127.0.0.1 ) \
    >"$W/backend.log" 2>&1 &
  BACKEND_PID=$!
  for _ in $(seq 1 30); do
    (exec 3<>/dev/tcp/127.0.0.1/"$LOCAL_PORT_T") 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
}
stop_backend() { [ -n "$BACKEND_PID" ] && kill "$BACKEND_PID" 2>/dev/null; wait "$BACKEND_PID" 2>/dev/null; BACKEND_PID=""; }

# 占位进程：模拟 "宿主机端口被别的程序（如 VS Code 转发）占着"
squat() {
  python3 - "$1" <<'PY' >/dev/null 2>&1 &
import socket,sys,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(("127.0.0.1",int(sys.argv[1]))); s.listen(5)
time.sleep(3600)
PY
  SQUAT_PID=$!
  for _ in $(seq 1 30); do ss -tlnH | grep -q ":$1\b" && return 0; sleep 0.2; done
  return 1
}
unsquat() { [ -n "$SQUAT_PID" ] && kill "$SQUAT_PID" 2>/dev/null; wait "$SQUAT_PID" 2>/dev/null; SQUAT_PID=""; }

start_tunnel() {  # start_tunnel <升级检查间隔>
  : >"$W/tun.log"
  env -i PATH="$PATH" HOME="$HOME" \
      SSH_HOST="$SSH_HOST_T" SSH_PORT="$SSH_PORT_T" SSH_USER="$SSH_USER_T" SSH_KEY="$SSH_KEY_T" \
      LOCAL_ADDR=127.0.0.1 LOCAL_PORT="$LOCAL_PORT_T" HOST_ADDR=127.0.0.1 \
      HOST_PORT_CANDIDATES="$PREFERRED $FALLBACK" \
      READY_GRACE=2 RETRY_SEC=2 DSH_POLL_SEC=1 UPGRADE_CHECK_SEC="${1:-999}" \
      LOCK_FILE="$W/lock" \
      setsid bash "$TUNNEL_SH" >>"$W/tun.log" 2>&1 &
  TUN_PID=$!
  sleep 0.3
}
stop_tunnel() {
  [ -n "$TUN_PID" ] || return 0
  kill -TERM -"$TUN_PID" 2>/dev/null
  for _ in $(seq 1 40); do kill -0 "$TUN_PID" 2>/dev/null || break; sleep 0.1; done
  kill -KILL -"$TUN_PID" 2>/dev/null
  wait "$TUN_PID" 2>/dev/null
  TUN_PID=""
}
wait_log() {  # wait_log <正则> <秒>
  local pat="$1" n=$(( ${2:-20} * 5 ))
  for _ in $(seq 1 "$n"); do grep -qE "$pat" "$W/tun.log" && return 0; sleep 0.2; done
  return 1
}
serving() {  # serving <端口> → 打印 http code（连不上时输出 000）
  local c
  c=$(curl -s --max-time 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$1/" 2>/dev/null)
  printf '%s' "${c:-000}"
}
body() { curl -s --max-time 3 "http://127.0.0.1:$1/marker.txt" 2>/dev/null || true; }
listening() { ss -tlnH | grep -qE ":$1\b"; }
show_log() { sed -n '1,20p' "$W/tun.log" | sed 's/^/      │ /'; }

# ── S1：dsh 未就绪时等待，就绪后建隧道到首选端口 ────────────────────────────
sec "S1. backend 未就绪 → 等待 → 就绪后落到首选端口"
start_tunnel
if wait_log "等待" 6; then ok "backend 没起来时打印等待日志"; else bad "没有等待日志"; show_log; fi
sleep 1
if listening "$PREFERRED"; then bad "backend 未就绪就抢先监听 $PREFERRED"; else ok "backend 未就绪时不抢先占端口"; fi

start_backend || bad "假 backend 起不来"
if wait_log "隧道已建立" 20; then ok "backend 就绪后建立隧道"; else bad "20s 内没建起隧道"; show_log; fi
if grep -q "宿主机 127.0.0.1:${PREFERRED}" "$W/tun.log"; then ok "落在首选端口 $PREFERRED"; else bad "没有落在首选端口"; grep 隧道已建立 "$W/tun.log"; fi
if [ "$(serving "$PREFERRED")" = "200" ]; then ok "宿主机 :$PREFERRED 端到端 HTTP 200"; else bad "宿主机 :$PREFERRED 不通（HTTP $(serving "$PREFERRED")）"; fi
if [ "$(body "$PREFERRED")" = "$MARKER" ]; then ok "内容正确（$MARKER）"; else bad "内容不对：$(body "$PREFERRED" | head -c 60)"; fi

# ── S2：首选端口被别的进程占着 → 回退到第二候选 ─────────────────────────────
sec "S2. 首选端口被占 → 自动回退到 $FALLBACK"
stop_tunnel
listening "$PREFERRED" && sleep 1
squat "$PREFERRED" || bad "占位进程起不来"
start_tunnel
if wait_log "落地端口 ${PREFERRED} 建立失败" 15; then ok "首选端口失败被识别（不是误判成功）"; else bad "没有识别出首选端口被占"; show_log; fi
if wait_log "隧道已建立" 15; then ok "自动尝试下一个候选并建立"; else bad "回退失败"; show_log; fi
if grep -q "宿主机 127.0.0.1:${FALLBACK}" "$W/tun.log"; then ok "确实落在回退端口 $FALLBACK"; else bad "没有落在 $FALLBACK"; show_log; fi
[ "$(serving "$FALLBACK")" = "200" ] && ok "回退端口端到端 HTTP 200" || bad "回退端口不通"
listening "$PREFERRED" && inf "（$PREFERRED 仍在监听——那是占位进程，不是我们的）"

# ── S3：首选端口空出 → 自动升级回去 ─────────────────────────────────────────
sec "S3. 首选端口空出 → 自动升级回 $PREFERRED"
# 关键：先让隧道在"首选仍被占"的瞬间建起来（落到回退端口），再释放首选端口，
# 这样才是真的"升级"路径，而不是一开始就抢到首选。
stop_tunnel
listening "$PREFERRED" || squat "$PREFERRED" || bad "占位进程起不来"
start_tunnel 5   # 每 5s 检查一次
if wait_log "隧道已建立.*${FALLBACK}" 20; then
  ok "先落在回退端口 $FALLBACK"
else
  bad "没能先落到回退端口"; show_log
fi
inf "释放首选端口 $PREFERRED（模拟 VS Code 关掉）"
unsquat
if wait_log "已空出|升级" 25; then ok "检测到首选端口空出并主动升级"; else bad "25s 内没升级"; show_log; fi
sleep 3
if listening "$PREFERRED" && ! listening "$FALLBACK"; then
  ok "已回到首选端口 $PREFERRED，回退端口已释放"
else
  bad "升级后端口状态：PREF=$(listening "$PREFERRED" && echo 监听 || echo 未监听) FB=$(listening "$FALLBACK" && echo 监听 || echo 未监听)"
fi
[ "$(serving "$PREFERRED")" = "200" ] && ok "升级后端到端仍 200（转发没断链）" || bad "升级后端口不通"

# ── S4：隧道已建立后 backend 死掉 → 隧道还"假活着"吗？───────────────────────
sec "S4. 隧道已建立后 backend 突然死亡（健康检查缺口）"
PORT_NOW=""
if listening "$PREFERRED"; then PORT_NOW="$PREFERRED"; elif listening "$FALLBACK"; then PORT_NOW="$FALLBACK"; fi
if [ -z "$PORT_NOW" ]; then
  bad "没有端口在监听，S4 无法判定"; show_log
else
  inf "当前隧道落在 :$PORT_NOW，现在杀掉 backend"
  stop_backend
  t0=$SECONDS; closed=0
  for _ in $(seq 1 25); do
    listening "$PORT_NOW" || { closed=1; break; }
    sleep 1
  done
  if [ "$closed" = 1 ]; then
    ok "backend 死后 $((SECONDS-t0))s 内隧道自动断开，宿主机 :$PORT_NOW 已释放（不再假活）"
    inf "再把 backend 拉起来，验证能自愈"
    base=$(grep -c "隧道已建立" "$W/tun.log")
    start_backend >/dev/null 2>&1
    reconnected=0
    for _ in $(seq 1 25); do
      [ "$(grep -c "隧道已建立" "$W/tun.log")" -gt "$base" ] && { reconnected=1; break; }
      sleep 1
    done
    [ "$reconnected" = 1 ] && ok "backend 恢复后自动重连成功" || { bad "backend 恢复后 25s 内没重连"; show_log; }
    [ "$(serving "$PORT_NOW")" = "200" ] && ok "重连后端到端恢复 200" || bad "重连后端口仍不通"
  else
    if [ "$(serving "$PORT_NOW")" = "200" ]; then
      bad "backend 已死但隧道仍返回 200（测试本身有问题）"
    else
      bug "backend 已死（HTTP $(serving "$PORT_NOW")），但宿主机 :$PORT_NOW 25s 后仍在监听 → 用户看到 connection refused 而非'隧道挂了'，且不会自愈"
      bug "对应改进项：隧道存活期需周期探测 LOCAL_PORT，失败即 kill ssh 触发重连"
    fi
    start_backend >/dev/null 2>&1
  fi
fi

# ── S5：SIGTERM 收尸 ────────────────────────────────────────────────────────
sec "S5. SIGTERM → 无残留 ssh 子进程"
stop_tunnel
sleep 2
orphans=$(pgrep -af "ssh .*-R .*127.0.0.1:${PREFERRED}|ssh .*-R .*127.0.0.1:${FALLBACK}" 2>/dev/null | grep -v "grep\|pgrep" | wc -l)
[ "$orphans" -eq 0 ] && ok "无残留 ssh 进程" || { bad "残留 $orphans 个 ssh 进程"; pgrep -af "ssh .*-R" | head; }
listening "$PREFERRED" && bad "停止后 $PREFERRED still listening" || ok "停止后端口已释放"
grep -q "收到停止信号" "$W/tun.log" && ok "打印了收尸日志" || inf "（没抓到收尸日志，可能日志已截断）"

# ── S6：宿主机探测失败时会不会误判为"端口空闲"而拆掉健康隧道 ────────────────
sec "S6. host 侧端口探测失败（模拟宿主机没装 ss / 网络抖动）"
stop_backend; stop_tunnel; unsquat 2>/dev/null
mkdir -p "$W/bin"
cat > "$W/bin/ssh" <<'SH'
#!/usr/bin/env bash
# 只让 tunnel.sh 的“探测型” ssh（带 ClearAllForwardings=yes）失败，建隧道的那条放行
for a in "$@"; do [ "$a" = "ClearAllForwardings=yes" ] && { exit 255; }; done
exec /usr/bin/ssh "$@"
SH
chmod +x "$W/bin/ssh"
start_backend
squat "$PREFERRED"
: >"$W/tun.log"
env -i PATH="$W/bin:$PATH" HOME="$HOME" \
    SSH_HOST="$SSH_HOST_T" SSH_PORT="$SSH_PORT_T" SSH_USER="$SSH_USER_T" SSH_KEY="$SSH_KEY_T" \
    LOCAL_ADDR=127.0.0.1 LOCAL_PORT="$LOCAL_PORT_T" HOST_ADDR=127.0.0.1 \
    HOST_PORT_CANDIDATES="$PREFERRED $FALLBACK" \
    READY_GRACE=2 RETRY_SEC=2 DSH_POLL_SEC=1 UPGRADE_CHECK_SEC=4 LOCK_FILE="$W/lock" \
    setsid bash "$TUNNEL_SH" >>"$W/tun.log" 2>&1 &
TUN_PID=$!
wait_log "隧道已建立.*${FALLBACK}" 20 || { bad "没能先落到回退端口，S6 无法判定"; show_log; }
before=$(grep -c "隧道已建立" "$W/tun.log")
sleep 12   # 3 个升级检查周期
after=$(grep -c "隧道已建立" "$W/tun.log")
if [ "$after" -gt "$before" ]; then
  bug "探测失败被当成“端口空闲”：健康隧道在 12s 内被拆了 $((after-before)) 次（$before → $after）"
  bug "对应改进项：host_port_busy 改成 BUSY/FREE/UNKNOWN 三态，UNKNOWN 绝不触发升级"
else
  ok "探测失败没有触发误拆（12s 内没有多余重连）"
fi
stop_tunnel

# ── S7：单实例锁 ────────────────────────────────────────────────────────────
sec "S7. 重复启动不应抢端口（单实例锁）"
unsquat; sleep 1
[ -n "$BACKEND_PID" ] || start_backend
start_tunnel 999
if wait_log "隧道已建立" 20; then ok "第一个实例正常建立"; else bad "第一个实例没建起来"; show_log; fi
out=$(env -i PATH="$PATH" HOME="$HOME" \
      SSH_HOST="$SSH_HOST_T" SSH_PORT="$SSH_PORT_T" SSH_USER="$SSH_USER_T" SSH_KEY="$SSH_KEY_T" \
      LOCAL_ADDR=127.0.0.1 LOCAL_PORT="$LOCAL_PORT_T" HOST_ADDR=127.0.0.1 \
      HOST_PORT_CANDIDATES="$PREFERRED $FALLBACK" \
      READY_GRACE=2 RETRY_SEC=2 DSH_POLL_SEC=1 UPGRADE_CHECK_SEC=999 LOCK_FILE="$W/lock" \
      timeout 6 bash "$TUNNEL_SH" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "已有实例在运行"; then
  ok "第二个实例检测到锁后立即退出（rc=0）"
else
  bad "第二个实例没有正确退出（rc=$rc）：$(printf '%s' "$out" | tail -2)"
fi
sleep 1
PORT_A=""
if listening "$PREFERRED" && [ "$(serving "$PREFERRED")" = "200" ]; then PORT_A=$PREFERRED
elif listening "$FALLBACK" && [ "$(serving "$FALLBACK")" = "200" ]; then PORT_A=$FALLBACK; fi
[ -n "$PORT_A" ] && ok "第一个实例未受影响（:$PORT_A 仍 200）" || bad "第一个实例被第二个实例干扰了（端口都不通）"
stop_tunnel

# ── 汇总 ────────────────────────────────────────────────────────────────────
sec "汇总"
printf '  通过 %d，失败 %d，发现缺陷 %d\n' "$pass" "$fail" "$bugs"
[ "$fail" -eq 0 ] && [ "$bugs" -eq 0 ]
