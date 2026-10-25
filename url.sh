#!/usr/bin/env bash
# ============================================================================
#  url.sh —— 打印当前 dsh web 的登录 URL（带 token），不用自己去翻 journalctl
#
#  为什么需要它：dsh 的登录令牌是【进程级】的，每次 dsh 重启就换一个，
#  旧 URL 立即作废。登录 cookie 虽然是 30 天有效（用持久化密钥签的），
#  但 cookie 里绑定了 authority（host:port），端口一变也要重新登录一次。
#
#  用法（在【虚拟机】里跑）：
#    bash url.sh              # 打印当前可用的登录 URL（自动识别隧道落在哪个端口）
#    bash url.sh 3000         # 指定端口
#    bash url.sh --all        # 列出所有候选端口的 URL（两个都开一次 = 以后不用再登录）
#    bash url.sh --write      # 顺便写入稳定文件 web-url.txt（cat 即可看）
#    bash url.sh --help       # 用法
# ============================================================================
set -uo pipefail

# 读取 install-vm.sh 生成的配置（存在即生效，不存在则用下面的默认值）
CONF=/etc/default/dsh-tunnel
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"

# ── 默认值：宿主机地址 = 本机默认网关（libvirt NAT 下它就是宿主机）─────────
default_gateway() { ip route show default 2>/dev/null | awk '{print $3; exit}'; }


for _c in curl ssh; do
  command -v "$_c" >/dev/null 2>&1 || { echo "缺少依赖：${_c}（apt install curl openssh-client）" >&2; exit 2; }
done

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
UNIT="${UNIT:-dsh-web.service}"
STATE="${WEB_URL_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/vm-reverse-tunnel/web-url.txt}"
CANDIDATES="${HOST_PORT_CANDIDATES:-3080 3000}"
LOCAL_PORT="${LOCAL_PORT:-3080}"   # 虚拟机上 dsh web 的端口（用于当场验证 token）

SSH_HOST="${SSH_HOST:-$(default_gateway)}"
SSH_PORT="${SSH_PORT:-22}"
SSH_USER="${SSH_USER:-$(id -un)}"
# 密钥：默认按当前用户的 HOME 找。找不就会跳过“自动识别隧道端口”那一步
# （仍然会列出所有候选 URL，只是不标注哪个是我们的）
SSH_KEY="${SSH_KEY:-$HOME/.ssh/dsh-remote}"

for a in "$@"; do
  case "$a" in
    -h|--help)
      sed -n '2,14p' "$SELF" | sed 's/^# \{0,1\}//'
      echo
      echo "在【虚拟机】里以运行 dsh 的用户执行 —— 它读取本机 dsh-web.service 的日志，"
      echo "并自动判断我们的隧道当前落在宿主机的哪个端口，打印出可直接在宿主机浏览器打开的 URL。"
      exit 0 ;;
  esac
done

WANT_PORT=""
WRITE=0
for a in "$@"; do
  case "$a" in
    --all)   WANT_PORT="ALL" ;;
    --write) WRITE=1 ;;
    ''|*[!0-9]*) ;;
    *)       WANT_PORT="$a" ;;
  esac
done

# ── 1) 取当前进程的 token ───────────────────────────────────────────────────
# dsh 把带 token 的 URL 打印到自己的 stdout，也就是 journal。
# 服务以该用户身份运行，所以本用户就能读自己的单元日志，不需要 root。
#
# 关键：拿到候选 token 后要【当场验证】——dsh 刚重启时，journal 里最后一条可能是
# 上一个进程留下的旧 token（旧 token 一律 401）。逐个试，取第一个真正有效的。
token_candidates() {
  journalctl -u "$UNIT" --no-pager -n 3000 2>/dev/null \
    | grep -o 'token=[A-Za-z0-9_-]*' | cut -d= -f2 | uniq
  for f in /var/log/dsh-web/output.log "$STATE"; do
    [ -r "$f" ] || continue
    grep -o 'token=[A-Za-z0-9_-]*' "$f" 2>/dev/null | cut -d= -f2 | uniq
  done
}

TOKEN=""
while read -r t; do
  [ -n "$t" ] || continue
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
         "http://127.0.0.1:${LOCAL_PORT:-3080}/?token=$t" 2>/dev/null || true)
  if [ "$code" != "401" ] && [ "$code" != "000" ]; then
    TOKEN="$t"          # 有效（303=种下 cookie / 200=已认证）
    break
  fi
done < <(token_candidates | tac | head -10)

if [ -z "${TOKEN:-}" ]; then
  cat >&2 <<EOF
拿不到【当前有效】的 token，可能原因：
  1) dsh-web.service 还没起来：   systemctl status $UNIT
  2) 刚重启过、URL 还没打印：     等几秒再试一次
  3) 本地 dsh 不通：               curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:${LOCAL_PORT:-3080}/
  4) 日志被轮转：                  journalctl -u $UNIT | tail -50
EOF
  exit 1
fi

# ── 2) 判断我们的隧道当前落在宿主机的哪个端口 ──────────────────────────────
# 只看"端口在监听"不够：VS Code 的转发也会监听，且指向同一个 dsh。
# 用 ss -tlnHe 的 uid 字段区分（只有 uid == 我们 SSH 账号的那条才是我们的隧道）。
# shellcheck disable=SC2086  # 有意按空格拆分端口列表
our_port=$(ssh -T -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
               -o ConnectTimeout=6 -i "$SSH_KEY" -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" \
               bash -s -- $CANDIDATES <<'RS' 2>/dev/null
uid=$(id -u)
for p in $*; do
  if ss -tlnHe "sport = :$p" 2>/dev/null | grep -q "uid:$uid"; then echo "$p"; exit 0; fi
done
RS
)

# ── 3) 输出 ─────────────────────────────────────────────────────────────────
mk_url() { printf 'http://127.0.0.1:%s/?token=%s\n' "$1" "$TOKEN"; }

echo "dsh web 登录 URL（token 已就绪，重启 dsh 后会变，重跑本脚本即可）："
echo

if [ "$WANT_PORT" = "ALL" ]; then
  for p in $CANDIDATES; do
    if [ "$p" = "${our_port:-}" ]; then
      printf '  %s   ← 我们的隧道当前就在这个端口（直接用这个）\n' "$(mk_url "$p")"
    else
      printf '  %s   （该端口当前不是我们的隧道；如果它也能打开 dsh，同样需要用它登录一次）\n' "$(mk_url "$p")"
    fi
  done
elif [ -n "$WANT_PORT" ]; then
  mk_url "$WANT_PORT"
elif [ -n "${our_port:-}" ]; then
  mk_url "$our_port"
  echo "  （我们的隧道在宿主机 127.0.0.1:${our_port}；同一端口登录一次后 cookie 30 天有效）"
else
  echo "  ! 没能从宿主机确认隧道端口，列出全部候选："
  for p in $CANDIDATES; do mk_url "$p"; done
fi

if [ "$WRITE" -eq 1 ]; then
  mkdir -p "$(dirname "$STATE")"
  { echo "# dsh web 登录 URL —— 由 url.sh 于 $(date '+%F %T') 写入"; echo "# 端口变化或 dsh 重启后重跑： vmrt-url --write"; } > "$STATE"
  if [ -n "${our_port:-}" ] && [ "$WANT_PORT" != "ALL" ]; then
    mk_url "${WANT_PORT:-$our_port}" >> "$STATE"
  else
    for p in $CANDIDATES; do mk_url "$p" >> "$STATE"; done
  fi
  chmod 600 "$STATE"
  echo
  echo "已写入 $STATE（cat 即可查看）"
fi
