#!/usr/bin/env bash
# ============================================================================
#  install-host.sh —— 【可选】在【宿主机】上以 root 执行：开启局域网访问
#
#  作用：
#    1. /etc/ssh/sshd_config.d/10-dsh-tunnel.conf 写入
#         GatewayPorts clientspecified
#       —— 允许虚拟机用 ssh -R 0.0.0.0:PORT:... 把隧道绑到全网卡
#       （默认 GatewayPorts no 时只会绑到宿主机的 127.0.0.1，局域网访问不了）
#    2. ufw 放行对应 TCP 端口（如果 ufw 在用）
#
#  用法：
#    sudo bash install-host.sh               # 默认放行 3000 与 3080
#    sudo bash install-host.sh 3000          # 只放行 3000
#
#  执行完之后，还要在【虚拟机】把隧道绑定地址改成 0.0.0.0：
#    /etc/default/dsh-tunnel 里加一行： HOST_ADDR=0.0.0.0
#    systemctl restart dsh-tunnel.service
#  （只做宿主机本机访问时，本脚本不需要运行。）
# ============================================================================
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "错误：必须以 root 运行：sudo bash $0" >&2; exit 1; }

PORTS=("$@")
if [ "${#PORTS[@]}" -eq 0 ]; then PORTS=(3000 3080); fi

CONF=/etc/ssh/sshd_config.d/10-dsh-tunnel.conf
if [ -f "$CONF" ]; then
  echo "[install-host] $CONF 已存在，内容："
  cat "$CONF"
else
  echo "[install-host] 写入 $CONF"
  cat > "$CONF" <<'EOF'
# 由 ssh_tunnel 项目写入：允许 ssh -R 客户端指定绑定地址（局域网访问 dsh web）
# clientspecified 比 yes 更安全：只有显式写了 0.0.0.0:PORT 的转发才会对外监听。
GatewayPorts clientspecified
EOF
fi

echo "[install-host] 校验 sshd 配置"
sshd -t
echo "[install-host] 重启 sshd（已有连接不会断）"
systemctl restart ssh 2>/dev/null || systemctl restart sshd

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  for p in "${PORTS[@]}"; do
    echo "[install-host] ufw allow ${p}/tcp"
    ufw allow "${p}/tcp" >/dev/null
  done
  ufw status | grep -E "($(IFS='|'; echo "${PORTS[*]}"))/tcp" || true
else
  echo "[install-host] ufw 未启用，跳过防火墙放行"
fi

echo
echo "[install-host] 完成。现在到【虚拟机】执行："
echo "    echo 'HOST_ADDR=0.0.0.0' >> /etc/default/dsh-tunnel"
echo "    systemctl restart dsh-tunnel.service"
echo "之后局域网可用： http://<宿主机IP>:3080  或  http://<宿主机IP>:3000"
