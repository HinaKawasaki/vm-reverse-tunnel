#!/usr/bin/env bash
# ============================================================================
#  setup-key.sh —— 在【虚拟机】内运行：配置 虚拟机 → 宿主机 的 SSH 免密
#
#  注意方向：是虚拟机主动连宿主机（反向隧道），所以公钥要加到【宿主机】上。
#  用法： bash setup-key.sh
# ============================================================================
set -uo pipefail

CONF=/etc/default/dsh-tunnel
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"

default_gateway() { ip route show default 2>/dev/null | awk '{print $3; exit}'; }

KEY="${SSH_KEY:-$HOME/.ssh/dsh-remote}"
HOST="${SSH_HOST:-$(default_gateway)}"
PORT="${SSH_PORT:-22}"
RUSER="${SSH_USER:-$(id -un)}"

if [ -z "$HOST" ]; then
  echo "拿不到宿主机地址，请显式指定： SSH_HOST=192.168.122.1 bash $0" >&2
  exit 1
fi

echo "密钥：    $KEY"
echo "目标：    ${RUSER}@${HOST}:${PORT}"
echo

if [ ! -f "$KEY" ]; then
  echo "-> 生成密钥（无口令）"
  mkdir -p "$(dirname "$KEY")" && chmod 700 "$(dirname "$KEY")"
  ssh-keygen -t ed25519 -N '' -C "vm-reverse-tunnel" -f "$KEY"
else
  echo "-> 密钥已存在，复用"
fi

echo
echo "公钥："
cat "$KEY.pub"
cat <<EOF

把公钥装到宿主机（下面这条会从本机把公钥追加进去，需要你输一次宿主机密码）：
  ssh -p ${PORT} ${RUSER}@${HOST} 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys' < ${KEY}.pub

验证免密（应当直接输出 OK，不提示密码）：
  ssh -i ${KEY} -p ${PORT} -o BatchMode=yes -o StrictHostKeyChecking=accept-new ${RUSER}@${HOST} true && echo OK
EOF
