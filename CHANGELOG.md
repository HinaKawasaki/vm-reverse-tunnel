# Changelog

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)，
格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

## [Unreleased]

## [0.3.0] - 2026-10-25

主题：**从"一个能跑的工具"变成"一套能维护的项目"** —— 配置收敛到单一来源、可守护任意服务、双语。

### Added

- `deploy.sh` + `local.env.example`：仓库只放通用值，本机差异写进 gitignored 的
  `local.env`，由 `deploy.sh` 渲染进 `/etc/default/dsh-tunnel` 的**托管块**
  （重跑整体替换，块外内容保留）。从此不会再出现"仓库和机器各改各的"。
- `SERVICE_LABEL`：日志里怎么称呼被守护的服务（不再硬编码 dsh web）。
- `HEALTH_URL`：用 HTTP 健康检查替代 TCP 连通性判断；端口开着但服务返回 5xx/404 时
  不会建立隧道（宁可不通，也不暴露半死服务）。
- `install-vm.sh` 现在会把辅助脚本装成 `vmrt-url` / `vmrt-verify` / `vmrt-setup-key` /
  `vmrt-uninstall`，删掉克隆目录后命令依然可用。
- `tests/deploy.sh`：21 项断言，覆盖托管块、幂等、块外内容保留、同机端口自撞检测。
- `tests/e2e.sh` 新增 S8：`HEALTH_URL` 不通过时拒绝建隧道（并从日志确认
  `SERVICE_LABEL` 生效）。整套 8 个场景 / 32 项断言。
- `README.en.md`：完整英文版；中文 README 顶部互链。

### Changed

- `url.sh` 的 `web-url.txt` 默认写到
  `$XDG_STATE_HOME/vm-reverse-tunnel/`（`~/.local/state/...`），装到 `/usr/local/bin`
  之后普通用户也能写。
- `uninstall.sh` 一并清理 `vmrt-*` 辅助命令。
- README 新增「守护别的服务（不限于 dsh web）」与 Jupyter 示例。
- CI 的离线校验 job 增加 `tests/deploy.sh`。

### Fixed

- `deploy.sh` 的 EXIT trap 在 `--destdir` 模式下会让脚本以非零码退出（自测时发现：
  清理函数最后一条 `[ -n "" ] && rm` 返回 1，把退出码带偏）。
- `deploy.sh` 曾错误地把"虚拟机端口 == 宿主机落地端口"判为自撞；两台机器上这是
  默认形态，只有 `SSH_HOST` 指向本机时才需要拦。

## [0.2.0] - 2026-10-25

主题：**让"能不能改"变成"敢改"** —— 补测试、补可观测性、修掉会误伤用户的边角。

### Added

- `tests/e2e.sh`：不需要 libvirt / 两台机器，单机即可端到端验证隧道状态机。
  覆盖 7 个场景：就绪等待、首选端口被占回退、空出后自动升级、**后端猝死后自愈**、
  SIGTERM 收尸、**宿主机探测失败不误拆**、**重复启动不抢端口**。
- `tests/units.sh`：无需 root，用 `DESTDIR` 预演安装并校验 unit 渲染 +
  `systemd-analyze verify`。
- `.github/workflows/ci.yml`：`bash -n`、`shellcheck`、unit 渲染、e2e 三个 job。
- `uninstall.sh`：一键卸载；`--purge-host` 可清掉宿主机侧的 GatewayPorts 与 ufw 规则。
- `tunnel.sh`：`HEALTH_CHECK_SEC`（默认 3s）存活期健康检查，后端失联即断开重连。
- `tunnel.sh`：`LOCK_FILE` 单实例锁（`flock`），非 root 时自动退到 `$TMPDIR`。
- `install-vm.sh`：支持 `DESTDIR` 预演安装（不需要 root、不碰系统）。
- README：新增「依赖清单」，明确虚拟机/宿主机各需要哪些命令。

### Fixed

- **unit 里的 `Documentation=` 不再是死链**：v0.1 的 `https://github.com/OWNER/…`
  是 `install-vm.sh` 漏替换的占位符，现在由 `@REPO_URL@` 从 `git remote` 推导，
  推不出来就回退到 `file:<本地 README>`；渲染后还会检查残留占位符并直接报错。
- **宿主机探测失败不再被当成"端口空闲"**：`host_port_busy` 改为
  `host_port_state`（BUSY/FREE/UNKNOWN）。`ss` 缺失、ssh 连不上、输出看不懂一律
  UNKNOWN，绝不触发"升级"，避免每 `UPGRADE_CHECK_SEC` 秒误拆一条健康隧道。
- **磁盘/服务假活**：隧道建立后本地服务崩溃，宿主机端口仍监听（能连上但 502），
  现在会在 `HEALTH_CHECK_SEC` 内主动断开并重连。
- **`switch-now.sh` 不再 `pkill -f "port 309[9]"`**：那是写死 3099 的调试残留，
  改 `PREFLIGHT_PORT` 就失效，还可能误杀无关进程；改为 `setsid` + 按进程组收尸。
- **`switch-now.sh` 清理残留隧道时限定 `-u "$SVC_USER"`** 并锚定脚本名：
  v0.1 的 `pgrep -f tunnel.sh` 在 root 下会连别的用户/别的项目的同名脚本一起杀。
- **`verify.sh` / `url.sh` 缺依赖时明确报错**；宿主机缺 `ss`/`curl` 时如实输出
  `NOSS` / `NOCURL`，而不是误报"无人监听"。
- **卸载不再留尾巴**：v0.1 只删 unit，`sshd_config.d/10-dsh-tunnel.conf` 与 ufw
  规则会残留（局域网仍然可达）。
- `switch-now.sh` 预检里的 `su -c` 命令对含空格的路径做了正确引用。

### Changed

- 日志措辞 `dsh web` → `本地服务`（同一套逻辑可服务任意回环服务）。
- `install-vm.sh` 开始前会校验 `systemd-analyze`，发现必填命令缺失直接提示。

## [0.1.0] - 2026-10-12

- 首个公开版本：虚拟机主动拨出的反向 SSH 隧道，systemd 托管，
  断线自愈 + 开机自启 + 宿主机首选/回退端口自动让位与升级。
