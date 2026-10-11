#!/usr/bin/env bash
# ============================================================================
#  verify.sh —— 在【虚拟机】内以运行 dsh 的用户执行：端到端健康检查
#  用法： bash verify.sh
#
#  关键点：宿主机上某个端口在监听，不等于它就是我们的反向隧道 ——
#  VS Code Remote-SSH 也会把虚拟机 3080 转发到宿主机 127.0.0.1:3080。
#  这里用 `ss -tlnHe` 的 uid 字段区分：只有监听者 uid == 我们的 SSH 账号 uid
#  才算自己的隧道，避免隧道已死却给出假绿灯。
# ============================================================================
set -uo pipefail

# 读取 install-vm.sh 生成的配置（存在即生效，不存在则用下面的默认值）
CONF=/etc/default/dsh-tunnel
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"

# ── 默认值：宿主机地址 = 本机默认网关（libvirt NAT 下它就是宿主机）─────────
default_gateway() { ip route show default 2>/dev/null | awk '{print $3; exit}'; }


SSH_HOST="${SSH_HOST:-$(default_gateway)}"
SSH_PORT="${SSH_PORT:-22}"
SSH_USER="${SSH_USER:-$(id -un)}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/dsh-remote}"
LOCAL_PORT="${LOCAL_PORT:-3080}"
PORTS="${HOST_PORT_CANDIDATES:-3080 3000}"

pass=0; fail=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=$((fail+1)); }
inf() { printf '  \033[33m•\033[0m %s\n' "$*"; }

SSH_BASE=(-T -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new
          -o ConnectTimeout=10 -i "$SSH_KEY" -p "$SSH_PORT" "$SSH_USER@$SSH_HOST")

hcode() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null || echo 000; }

echo "== 1. 虚拟机内 dsh web (127.0.0.1:${LOCAL_PORT}) =="
c=$(hcode "http://127.0.0.1:${LOCAL_PORT}/")
[ "$c" != "000" ] && ok "dsh web 响应 HTTP $c（401=需 token，正常）" || bad "dsh web 无响应"

echo "== 2. systemd 服务 =="
for u in dsh-web.service dsh-tunnel.service; do
  s=$(systemctl is-active "$u" 2>/dev/null || true)
  e=$(systemctl is-enabled "$u" 2>/dev/null || true)
  if [ "$s" = "active" ]; then
    ok "$u active（$e）"
  elif [ "$e" = "not-found" ]; then
    inf "$u 尚未安装（还没跑 install-vm.sh / switch-now.sh）"
  else
    bad "$u 状态=$s（$e）"
  fi
done

echo "== 3. 宿主机侧隧道（按 uid 归属识别，排除 VS Code 转发）=="
probe=$(ssh "${SSH_BASE[@]}" bash -s -- "$PORTS" <<'RSCRIPT' 2>/dev/null
uid=$(id -u)
for p in $*; do
  line=$(ss -tlnHe "sport = :$p" 2>/dev/null | head -1)
  if [ -z "$line" ]; then
    echo "$p ABSENT - -"
    continue
  fi
  case "$line" in
    *"uid:$uid"*) own=OURS ;;
    *)            own=OTHER ;;
  esac
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$p/" 2>/dev/null)
  [ -n "$code" ] || code=000
  echo "$p $own $code"
done
RSCRIPT
)

if [ -z "$probe" ]; then
  bad "无法通过 SSH 探测宿主机（检查网络/密钥/sshd）"
else
  ours=""
  while read -r p own code; do
    [ -n "${p:-}" ] || continue
    case "$own" in
      OURS)
        if [ "$code" != "000" ]; then
          ok "宿主机 127.0.0.1:${p} 是我们的隧道 -> dsh（HTTP ${code}）  ← 浏览器用 http://127.0.0.1:${p}"
          ours=$p
        else
          bad "宿主机 127.0.0.1:${p} 是我们的隧道，但取不到内容"
        fi
        ;;
      OTHER)
        inf "宿主机 127.0.0.1:${p} 在监听，但属于别的进程（HTTP ${code}）——不是我们的隧道，已排除"
        ;;
      ABSENT)
        inf "宿主机 127.0.0.1:${p} 无人监听"
        ;;
    esac
  done <<<"$probe"
  [ -n "$ours" ] || bad "宿主机上没有找到属于我们的隧道端口（候选：${PORTS}）"
fi

echo
echo "结果：通过 $pass，失败 $fail"
[ "$fail" -eq 0 ] || { echo "排障： journalctl -u dsh-tunnel.service -n 50 --no-pager"; exit 1; }
