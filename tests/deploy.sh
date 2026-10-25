#!/usr/bin/env bash
# ============================================================================
#  tests/deploy.sh —— 验证 deploy.sh 的"仓库是唯一源 + local.env 只放私有值"
#
#  不需要 root：deploy.sh --dry-run 会把结果渲染到临时目录，这里对渲染结果
#  做断言（托管块、幂等、块外内容保留、自撞检测）。
#
#  用法： bash tests/deploy.sh
# ============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/vrt-deploy.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=$((fail+1)); }
sec() { printf '\n\033[1m%s\033[0m\n' "$*"; }

BEGIN='# >>> vm-reverse-tunnel local.env（deploy.sh 托管，重跑会整体替换）>>>'
END='# <<< vm-reverse-tunnel local.env <<<'
STAGE="$TMP/stage"
ENVF="$TMP/local.env"
CONF="$STAGE/etc/default/dsh-tunnel"

cat > "$ENVF" <<'EOF'
SSH_HOST=198.51.100.7
SSH_PORT=2604
SSH_USER=dsh-ssh
LOCAL_PORT=3080
SERVICE_LABEL="dsh web"
HOST_PORT_CANDIDATES="3080 3000"
HOST_ADDR=127.0.0.1
SVC_BIN=/bin/true
NOT_ALLOWED_KEY=should-be-ignored
EOF

deploy() { bash "$REPO/deploy.sh" --dry-run --destdir "$STAGE" --env "$ENVF" >"$TMP/out.log" 2>&1; }

sec "1. 首次部署渲染"
if deploy; then ok "deploy.sh --dry-run 成功"; else bad "deploy.sh 失败"; sed 's/^/      │ /' "$TMP/out.log"; fi
for f in etc/systemd/system/dsh-web.service etc/systemd/system/dsh-tunnel.service \
         etc/default/dsh-tunnel usr/local/bin/dsh-tunnel.sh usr/local/bin/vmrt-url \
         usr/local/bin/vmrt-verify usr/local/bin/vmrt-uninstall; do
  [ -e "$STAGE/$f" ] && ok "生成 $f" || bad "缺少 $f"
done

sec "2. local.env 的值进了托管块"
for kv in "SSH_HOST=198.51.100.7" "SSH_PORT=2604" "SSH_USER=dsh-ssh" \
          "HOST_PORT_CANDIDATES=\"3080 3000\"" "SERVICE_LABEL=\"dsh web\""; do
  grep -qF "$kv" "$CONF" && ok "托管块含 $kv" || bad "托管块缺 $kv"
done
[ "$(grep -cF "$BEGIN" "$CONF")" = "1" ] && ok "开始标记只有一处" || bad "开始标记重复"
[ "$(grep -cF "$END" "$CONF")" = "1" ] && ok "结束标记只有一处" || bad "结束标记重复"
grep -q "NOT_ALLOWED_KEY" "$CONF" && bad "非白名单键被写进了配置" || ok "非白名单键被忽略"

sec "3. 幂等：重复部署不重复追加"
deploy
[ "$(grep -cF "$BEGIN" "$CONF")" = "1" ] && ok "重跑后开始标记仍只有一处" || bad "重跑导致托管块重复"

sec "4. 托管块之外的内容必须保留"
printf 'MY_CUSTOM_LINE=1\n' >> "$CONF"
deploy
grep -q '^MY_CUSTOM_LINE=1$' "$CONF" && ok "块外自定义行仍在" || bad "块外自定义行被删掉了"
[ "$(grep -cF "$BEGIN" "$CONF")" = "1" ] && ok "托管块仍唯一" || bad "托管块重复"

sec "5. 同一台机器上端口自撞要被拦住"
cat > "$ENVF" <<'EOF'
SSH_HOST=127.0.0.1
LOCAL_PORT=18080
HOST_PORT_CANDIDATES="13080 18080"
SVC_BIN=/bin/true
EOF
if deploy; then bad "自撞配置居然通过了"; else
  if grep -q 'SSH_HOST 是本机时' "$TMP/out.log"; then
    ok "正确拒绝（提示落点与 LOCAL_PORT 相同）"
  else
    bad "退出非零，但原因不对"; sed 's/^/      │ /' "$TMP/out.log"
  fi
fi

sec "6. 远程宿主机允许端口相同（默认形态）"
cat > "$ENVF" <<'EOF'
SSH_HOST=198.51.100.7
LOCAL_PORT=3080
HOST_PORT_CANDIDATES="3080 3000"
SVC_BIN=/bin/true
EOF
if deploy; then ok "虚拟机 3080 -> 宿主机 3080 正常放行"; else bad "误拦截了默认形态"; fi

sec "汇总"
printf '  通过 %d，失败 %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
