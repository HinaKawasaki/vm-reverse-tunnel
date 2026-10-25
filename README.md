# vm-reverse-tunnel

> 让跑在 KVM/libvirt 虚拟机里、**只监听 `127.0.0.1`** 的服务，在宿主机上稳定可达 —— 由虚拟机主动拨出的反向 SSH 隧道，带开机自启、断线自愈、端口竞争自动让位。

**English**: A self-healing reverse SSH tunnel that exposes a loopback-only service running inside a KVM/libvirt guest on the host machine (and optionally on the LAN). The guest initiates the connection, so the host needs no polling and no knowledge of the guest's IP. Managed by systemd, with automatic reconnect, boot-time startup, and a preferred/fallback host port strategy. Built for **dsh web** (DeepSeek Harness Web), reusable for any loopback-only HTTP service.

```
┌─ 宿主机 host (sshd) ─────────────────────────────────────────────┐
│                                                                  │
│   127.0.0.1:3080   ← 首选落地端口（空着就用它）                   │
│   127.0.0.1:3000   ← 回退端口（3080 被 VS Code 之类占用时）       │
│         ▲                                                        │
└─────────┼────────────────────────────────────────────────────────┘
          │  ssh -N -R    （虚拟机主动连出；宿主机无需知道虚拟机 IP）
          │  免密 key
┌─────────┼────────────────────────────────────────────────────────┐
│  ┌──────┴───────────────┐      ┌───────────────────────────────┐ │
│  │ dsh-tunnel.service   │      │ dsh-web.service               │ │
│  │ tunnel.sh            │─────▶│ dsh web --host 127.0.0.1      │ │
│  │ 等端口就绪 → 建隧道   │ 等就绪│         --port 3080 --no-open │ │
│  └──────────────────────┘      └───────────────────────────────┘ │
│  虚拟机 guest                                                     │
└──────────────────────────────────────────────────────────────────┘
```

## 它解决什么问题

libvirt 默认的 NAT 网络里，虚拟机在宿主机身后，宿主机**不能**直接访问虚拟机的服务；如果这个服务又出于安全只绑定 `127.0.0.1`
（`dsh web` 甚至有意禁止 `--host 0.0.0.0`），情况更麻烦。

常见做法与代价：

| 做法 | 问题 |
|---|---|
| libvirt hook + iptables DNAT | hook 调试麻烦，依赖虚拟机 IP，DHCP 换 IP 就断 |
| 宿主机轮询端口 + SSH 本地转发 | 要先知道虚拟机 IP，且探测时机不可靠 |
| 让服务直接绑 `0.0.0.0` | 很多服务禁止（会把控制面暴露到网络） |
| **虚拟机内守护脚本 + 反向隧道**（本项目） | 需要虚拟机 → 宿主机免密，这是唯一的前置条件 |

关键点：**"服务就绪了吗"这件事，虚拟机自己最清楚**。所以让虚拟机负责启动服务、等端口就绪、拨出隧道、断线重连；
宿主机只需要有一个跑着的 sshd。

## 特性

- **断线自愈**：`ServerAliveInterval=5 / ServerAliveCountMax=3` 检测 + 外层重连循环 + `systemd Restart=always` 三层兜底。
- **开机自启**：两条 systemd unit，`WantedBy=multi-user.target`。实测从开机到隧道可用 **约 15 秒**（含"网络还没起来"的自愈）。
- **端口竞争自动让位 + 自动升级**：宿主机上按 `HOST_PORT_CANDIDATES`（默认 `3080 3000`）依次尝试；
  若首选端口被别的程序占用（比如 VS Code 的远程端口转发），自动落到回退端口；等首选端口空出后**自动重连升级回去**。
- **不需要宿主机做端口转发、不需要知道虚拟机 IP**：虚拟机 IP 变了也无所谓，因为是虚拟机连出来。
- **默认只绑宿主机回环**，不碰宿主机 sshd 配置；要局域网访问时再显式开启（见下）。
- **后端失联自动断开重连**：隧道存活期间每 `HEALTH_CHECK_SEC`（默认 3s）回探一次本地服务；
  服务崩溃/重启时主动断开隧道，避免宿主机端口"假活着"（能连上但 502/connection refused）。
- **单实例锁**：同一台机器上重复启动（比如手动一份 + systemd 一份）会直接退出，不会互抢端口。
- **运维小工具**：`verify.sh` 端到端体检（能区分"我们的隧道"和"别人的转发"），`url.sh` 直接打印登录 URL。

## 前置条件

- 宿主机：Linux + KVM/libvirt，sshd 在运行。
- 虚拟机：systemd、`bash`、`ssh` 客户端。
- **虚拟机 → 宿主机 SSH 免密**（方向别搞反，见 `setup-key.sh`）。

## 快速开始

全部操作在**虚拟机**里进行（`install-vm.sh` 与 `switch-now.sh` 需要 root）。

```bash
git clone https://github.com/<你>/vm-reverse-tunnel.git
cd vm-reverse-tunnel

# 1) 配置 虚拟机 → 宿主机 免密（按提示把那行公钥装到宿主机）
bash setup-key.sh

# 2) 安装脚本 + systemd unit（自动探测 dsh 用户/家目录/可执行文件/端口）
sudo bash install-vm.sh

# 3) 一键平滑切换成 systemd 托管（带预检，推荐前台跑，进度直接可见）
sudo bash switch-now.sh -f

# 4) 体检 / 拿登录 URL
bash verify.sh
bash url.sh
```

> `install-vm.sh` 只安装不启动（适合先看效果）；`switch-now.sh` 会把正在手动跑的实例换成 systemd 托管，
> **过程中当前 Web 会话会断开**（会话数据已持久化，重连后仍在）。

## 目录结构

```
tunnel.sh               # 核心守护脚本（装到 /usr/local/bin/dsh-tunnel.sh）
url.sh                  # 打印当前有效的登录 URL（自动识别落地端口 + 校验 token）
verify.sh               # 端到端体检
setup-key.sh            # 生成并安装 虚拟机 → 宿主机 免密
install-vm.sh           # root：渲染 unit 模板并安装 + enable
switch-now.sh           # root：一键从手动运行平滑切换到 systemd 托管
install-host.sh         # root（可选）：宿主机开 GatewayPorts + ufw，用于局域网访问
dsh-tunnel.default      # /etc/default/dsh-tunnel 的模板（配置项都在这里）
units/dsh-web.service.in      # 服务本身（模板，@...@ 由 install-vm.sh 替换）
units/dsh-tunnel.service.in   # 隧道守护（模板）
```

## 配置

安装后配置在 `/etc/default/dsh-tunnel`（由 `dsh-tunnel.default` 渲染而来）：

| 变量 | 默认 | 说明 |
|---|---|---|
| `SVC_USER` / `SVC_HOME` / `SVC_BIN` | 自动探测 | 跑服务与隧道的用户、家目录、可执行文件 |
| `LOCAL_PORT` | `3080` | 服务在虚拟机内监听的端口 |
| `SSH_HOST` | 默认网关 | 宿主机地址；留空则用 `ip route` 的默认网关（libvirt NAT 下就是宿主机） |
| `SSH_PORT` / `SSH_USER` / `SSH_KEY` | `22` / 当前用户 / `~/.ssh/dsh-remote` | 宿主机 sshd 端口、账号、私钥 |
| `HOST_PORT_CANDIDATES` | `"3080 3000"` | 宿主机落地端口，按优先级尝试；第一个是首选 |
| `HOST_ADDR` | `127.0.0.1` | 隧道绑定地址；`0.0.0.0` 才对外（需宿主机 GatewayPorts） |
| `HEALTH_CHECK_SEC` | `3` | 隧道存活期回探本地服务的间隔 |
| `LOCK_FILE` | 自动 | 单实例锁文件；非 root 时自动退到 `$TMPDIR` |
| `READY_GRACE` / `RETRY_SEC` / `UPGRADE_CHECK_SEC` … | `4` / `3` / `60` | 时序参数，一般不用动 |

改完执行 `sudo systemctl restart dsh-tunnel.service`。

## 局域网访问（可选）

默认 `-R` 只绑宿主机 `127.0.0.1`。要让局域网其他机器访问，**宿主机** root 执行：

```bash
sudo bash install-host.sh        # 写 GatewayPorts clientspecified + ufw 放行
```

然后在虚拟机：

```bash
echo 'HOST_ADDR=0.0.0.0' | sudo tee -a /etc/default/dsh-tunnel
sudo systemctl restart dsh-tunnel.service
```

之后局域网可用 `http://<宿主机IP>:3080`。

> 用 `GatewayPorts clientspecified` 而不是 `yes`：只有显式写 `0.0.0.0:PORT` 的转发才会对外监听，更安全。

## 日常运维

```bash
bash verify.sh                            # 体检：服务、隧道、端到端
bash url.sh                               # 当前有效的登录 URL（自动识别端口）
bash url.sh --all                         # 列出所有候选端口的 URL
bash url.sh --write                       # 写入 web-url.txt，之后 cat 即可看

systemctl status dsh-web.service dsh-tunnel.service
journalctl -u dsh-tunnel.service -f       # 实时看重连
```

**关于登录令牌（以 dsh web 为例，概念通用）**：

- 登录 token 是**进程级**的，服务一重启就换，旧 URL 立即作废；
- 登录 cookie 通常 30 天有效，但可能**绑定 authority（host:port）** —— 端口一变就要重新登录一次；
- 所以 `url.sh` 的价值是：一条命令拿到**当前有效**的 URL（它会当场验证 token，避免拿到上一个进程的旧 token）。
  把 `url.sh --all` 列出的每条都在浏览器打开一次，之后端口怎么切都不用再登录。

## 排障

| 现象 | 原因 / 处理 |
|---|---|
| 宿主机落地端口不通 | 看 `journalctl -u dsh-tunnel.service`；服务没起时脚本会一直打印"等待 … 就绪" |
| 日志一直 `落地端口 … 建立失败` | 候选端口都被别的程序占了；改 `HOST_PORT_CANDIDATES` |
| 日志 `EADDRINUSE: address already in use` | 服务之外还有实例在跑（比如手动启动的）；清掉后 `systemctl restart dsh-web.service` |
| 日志 `Network is unreachable` | 开机瞬间网络还没好；脚本会自动重试，无需处理 |
| 浏览器 401 / 要求令牌 | 跑 `url.sh` 拿当前 URL（端口变了或服务刚重启） |
| 浏览器 403 | 用的是非 loopback 主机名，且没配 GatewayPorts/ufw |
| `Permission denied (publickey)` | 免密没配好；重跑 `setup-key.sh` 并确认公钥进了宿主机的 `authorized_keys` |
| `journalctl` 提示权限不足 | 普通用户看不到 system 单元日志；用运行该服务的用户或 root 执行 |

## 卸载 / 回滚

```bash
sudo systemctl disable --now dsh-tunnel.service dsh-web.service
sudo rm -f /etc/systemd/system/dsh-{web,tunnel}.service \
           /usr/local/bin/dsh-tunnel.sh /etc/default/dsh-tunnel
sudo systemctl daemon-reload
```

## 设计取舍与已知限制

- **必须让服务只绑回环**：这是安全前提；对外暴露交给隧道，而不是把服务绑到 `0.0.0.0`。
- **宿主机的落地端口必须可用**：如果候选端口全被占用，隧道起不来（会持续重试）。首选/回退机制就是为了绕开"某个程序偶尔占着某端口"的场景。
- **默认只绑回环**：要局域网访问必须动宿主机 sshd 的 `GatewayPorts`，这是 OpenSSH 的设计，不是本项目的限制。
- **依赖系统服务名**：unit 名带 `dsh-` 前缀。换成别的服务时，改 `units/*.in` 与 `tunnel.sh` 里的 `LOCAL_PORT` 即可，逻辑与 dsh 无关。

## 实测记录

以下都是在真实 KVM 客户机上做过的验证（环境细节已脱敏）：

| 测试 | 结果 |
|---|---|
| 开机自启（真实重启虚拟机） | 开机 4s 隧道服务启动 → 6s 服务就绪 → 网络未通时自动重试 → **15s 隧道可用**，零人工干预 |
| 断网自愈（开机瞬间 `Network is unreachable`） | 自动重试并落到回退端口建连 |
| 首选端口空出后自动升级 | 模拟占用后释放：60s 内检测到并主动重连升级回首选端口 |
| 隧道被掐断 | 服务上下文下约 3–10s 自动重建 |
| 服务被强杀 | `Restart=always` 持续重启（端口被别人占用时每 ~7s 重试一次） |
| 端到端鉴权 | 无 token → 401；带 token → 303 + Set-Cookie；带 cookie → 200（完整页面） |
| 端口归属误判防护 | `verify.sh` 用 `ss -tlnHe` 的 uid 区分"我们的隧道"与第三方转发，避免假绿灯 |
| `SIGTERM` 收尸 | 主脚本退出后无残留 ssh 子进程 |

## License

[MIT](LICENSE)
