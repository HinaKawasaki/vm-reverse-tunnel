#!/usr/bin/env bash
# ============================================================================
#  tests/units.sh —— 不需要 root，校验 systemd unit 的"安装预演"
#
#  做法：用 DESTDIR 让 install-vm.sh 把 unit/脚本/配置渲染到临时目录，
#        然后检查占位符是否全部替换、ExecStart 是否指向正确路径、
#        systemd-analyze verify 是否通过。
#
#  这能抓到"模板漏渲染"这类问题（v0.1 的 Documentation=.../OWNER/... 就是
#  因为 install-vm.sh 少替换了一个占位符，装完只剩死链）。
#
#  用法： bash tests/units.sh
# ============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/vrt-units.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=$((fail+1)); }
sec() { printf '\n\033[1m%s\033[0m\n' "$*"; }

STAGE="$TMP/stage"
UNIT_DIR="$STAGE/etc/systemd/system"

sec "1. DESTDIR 预演安装（非 root）"
if DESTDIR="$STAGE" \
   SVC_USER="$(id -un)" SVC_HOME="$HOME" SVC_BIN=/bin/true LOCAL_PORT=3080 \
   REPO_URL="https://github.com/example/vm-reverse-tunnel" \
   bash "$REPO/install-vm.sh" >"$TMP/install.log" 2>&1; then
  ok "install-vm.sh 在 DESTDIR 下成功执行"
else
  bad "install-vm.sh 执行失败"; sed 's/^/      │ /' "$TMP/install.log"; exit 1
fi

for f in "etc/systemd/system/dsh-web.service" \
         "etc/systemd/system/dsh-tunnel.service" \
         "usr/local/bin/dsh-tunnel.sh" \
         "etc/default/dsh-tunnel"; do
  [ -e "$STAGE/$f" ] && ok "生成 $f" || bad "缺少 $f"
done

sec "2. 占位符必须全部替换"
leftover=0
for u in dsh-web dsh-tunnel; do
  if grep -nE '@[A-Z_]+@' "$UNIT_DIR/$u.service" >"$TMP/left.txt" 2>/dev/null; then
    bad "$u.service 残留占位符"; sed 's/^/      │ /' "$TMP/left.txt"; leftover=1
  fi
done
[ "$leftover" -eq 0 ] && ok "两个 unit 都没有 @XXX@ 残留"

if grep -q 'OWNER' "$UNIT_DIR"/*.service; then
  bad "unit 里仍有字面量 OWNER（v0.1 的回归点）"
else
  ok "没有字面量 OWNER"
fi

if grep -q '^Documentation=https://github.com/example/vm-reverse-tunnel$' "$UNIT_DIR/dsh-tunnel.service"; then
  ok "REPO_URL 被正确渲染进 Documentation"
else
  bad "Documentation 不是预期的仓库地址：$(grep '^Documentation=' "$UNIT_DIR/dsh-tunnel.service")"
fi

sec "3. ExecStart / 用户 / 端口"
if grep -q '^ExecStart=/usr/local/bin/dsh-tunnel.sh$' "$UNIT_DIR/dsh-tunnel.service"; then
  ok "dsh-tunnel 的 ExecStart 指向 /usr/local/bin/dsh-tunnel.sh"
else
  bad "dsh-tunnel ExecStart 不对：$(grep '^ExecStart=' "$UNIT_DIR/dsh-tunnel.service")"
fi
if grep -q -- '--port 3080' "$UNIT_DIR/dsh-web.service"; then
  ok "dsh-web 的 ExecStart 带 --port 3080"
else
  bad "dsh-web ExecStart 缺 --port：$(grep '^ExecStart=' "$UNIT_DIR/dsh-web.service")"
fi
if grep -q "^User=$(id -un)$" "$UNIT_DIR/dsh-web.service"; then
  ok "User= 渲染正确（$(id -un)）"
else
  bad "User= 渲染错误：$(grep '^User=' "$UNIT_DIR/dsh-web.service")"
fi
if [ "$(stat -c %a "$STAGE/usr/local/bin/dsh-tunnel.sh")" = "755" ]; then
  ok "隧道脚本权限 0755"
else
  bad "隧道脚本权限是 $(stat -c %a "$STAGE/usr/local/bin/dsh-tunnel.sh")，应为 755"
fi

sec "4. systemd-analyze verify"
if command -v systemd-analyze >/dev/null 2>&1; then
  # DESTDIR 里 ExecStart 还没进 /usr/local/bin，这条警告属预期
  out=$(systemd-analyze verify "$UNIT_DIR/dsh-web.service" "$UNIT_DIR/dsh-tunnel.service" 2>&1 \
        | grep -v 'is not executable' || true)
  if [ -z "$out" ]; then
    ok "systemd-analyze verify 无告警"
  else
    bad "systemd-analyze verify 有告警："; printf '%s\n' "$out" | sed 's/^/      │ /'
  fi
else
  printf '  \033[33m•\033[0m 没有 systemd-analyze，跳过（Debian/Ubuntu: apt install systemd）\n'
fi

STAGE2="$TMP/stage2"
if git -C "$REPO" remote get-url origin >/dev/null 2>&1; then
  sec "5. 有 git remote 时推导 https 文档地址"
  STAGE3="$TMP/stage3"
  DESTDIR="$STAGE3" SVC_USER="$(id -un)" SVC_HOME="$HOME" SVC_BIN=/bin/true LOCAL_PORT=3080 \
    bash "$REPO/install-vm.sh" >"$TMP/install3.log" 2>&1 || bad "安装失败"
  doc=$(grep '^Documentation=' "$STAGE3/etc/systemd/system/dsh-tunnel.service" 2>/dev/null || true)
  case "$doc" in
    *"https://github.com/"*) ok "从 remote 推导：$doc" ;;
    *OWNER*)              bad "仍然是 OWNER 死链：$doc" ;;
    *"file:"*)            bad "退化成了本地文件（权限/ownership 问题没处理）：$doc" ;;
    *)                    bad "结果异常：${doc:-（空）}" ;;
  esac
  case "$doc" in
    *.git) bad "没有去掉 .git 后缀：$doc" ;;
    *)     ok "URL 已去掉 .git 后缀" ;;
  esac
else
  sec "5. 没有 git remote 时的回退（不能退回 OWNER）"
  DESTDIR="$STAGE2" SVC_USER="$(id -un)" SVC_HOME="$HOME" SVC_BIN=/bin/true LOCAL_PORT=3080 \
    bash "$REPO/install-vm.sh" >"$TMP/install2.log" 2>&1 || bad "无 REPO_URL 时安装失败"
  doc=$(grep '^Documentation=' "$STAGE2/etc/systemd/system/dsh-tunnel.service" 2>/dev/null || true)
  case "$doc" in
    *OWNER*)                 bad "回退路径仍然产生了 OWNER 死链：$doc" ;;
    *"file:"*)               ok "回退到本地文档：$doc" ;;
    https://*|'')            ok "回退结果可接受：${doc:-（空）}" ;;
    *)                       bad "回退结果异常：$doc" ;;
  esac
fi

sec "汇总"
printf '  通过 %d，失败 %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
