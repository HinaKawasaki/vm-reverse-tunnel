# vm-reverse-tunnel

> Expose a **loopback-only** service running inside a KVM/libvirt guest on the host —
> with a reverse SSH tunnel initiated by the guest, systemd supervision, automatic
> reconnect, and a preferred/fallback host-port strategy.

**中文**: [README.md](README.md)

```
┌─ host (sshd) ─────────────────────────────────────────────────────┐
│                                                                   │
│   127.0.0.1:3080   ← preferred landing port (used when free)       │
│   127.0.0.1:3000   ← fallback (when 3080 is taken by e.g. VS Code) │
│         ▲                                                         │
└─────────┼─────────────────────────────────────────────────────────┘
          │  ssh -N -R        (guest dials out; host needs no guest IP)
          │  key auth
┌─────────┼─────────────────────────────────────────────────────────┐
│  ┌──────┴───────────────┐      ┌───────────────────────────────┐  │
│  │ dsh-tunnel.service   │      │ dsh-web.service               │  │
│  │ tunnel.sh            │─────▶│ dsh web --host 127.0.0.1      │  │
│  │ wait → tunnel        │ wait │         --port 3080 --no-open │  │
│  └──────────────────────┘      └───────────────────────────────┘  │
│  guest                                                            │
└───────────────────────────────────────────────────────────────────┘
```

## Why

A libvirt guest sits behind NAT: the host cannot reach it. If the service also binds
`127.0.0.1` only (many do, by design), you have three common options, all with a catch:

| Approach | Problem |
|---|---|
| libvirt hook + iptables DNAT | fragile, depends on the guest IP (DHCP changes break it) |
| host polls the port + ssh local forward | needs the guest IP, and readiness timing is unreliable |
| bind the service to `0.0.0.0` | often disallowed, and exposes the control plane |
| **guest-side daemon + reverse tunnel** (this project) | needs guest→host key auth — the only prerequisite |

Key insight: **the guest is the only one that knows when its own service is ready.**
So the guest starts the service, waits for readiness, dials the tunnel, and reconnects
on failure. The host just needs a running sshd.

## Features

- **Self-healing**: `ServerAliveInterval/CountMax` + an outer reconnect loop +
  `systemd Restart=always` — three layers. Measured: tunnel usable ~15 s after boot.
- **Liveness check while up**: if the local service dies, the tunnel is dropped and
  rebuilt (`HEALTH_CHECK_SEC`, default 3 s) instead of silently keeping a dead port open.
- **Port contention**: tries `HOST_PORT_CANDIDATES` in order; if the preferred port is
  taken, it falls back and later **upgrades back** once the port frees up. A failed probe
  is treated as `UNKNOWN`, never as "free" — so a healthy tunnel is never torn down by mistake.
- **Single instance**: `flock` prevents a manual copy and the systemd unit from fighting.
- **Service-agnostic**: works for any loopback TCP service; set `HEALTH_URL` to require a
  2xx/3xx HTTP health response before the tunnel is considered up.
- **One source of truth**: the repo holds generic values, machine-specific values live in a
  gitignored `local.env`, and `deploy.sh` renders them into a managed block.

## Requirements

| Where | Commands | Needed for |
|---|---|---|
| guest | `bash`, `ssh`, `ip`, `flock` | the tunnel itself |
| guest | `curl` | preflight, `verify.sh`, `url.sh` (and `HEALTH_URL`) |
| guest | `journalctl` | reading the token / tunnel logs |
| host | `ss` (iproute2) | deciding whether a port is ours / free |
| host | `curl` | end-to-end checks |

Plus: **guest → host passwordless SSH** (see `setup-key.sh`; the direction matters).

## Quick start

All commands run **inside the guest** (`deploy.sh` and `switch-now.sh` need root).

```bash
git clone https://github.com/<you>/vm-reverse-tunnel.git
cd vm-reverse-tunnel

# 1) only machine-specific values (gitignored)
cp local.env.example local.env && vi local.env

# 2) guest → host passwordless SSH
bash setup-key.sh

# 3) deploy: units + scripts + config (dry-run first if you like)
bash deploy.sh --dry-run
sudo bash deploy.sh

# 4) switch a manually started instance over to systemd (this disconnects the GUI once)
sudo bash switch-now.sh -f

# 5) health check / login URL
vmrt-verify
vmrt-url
```

`local.env` keys: `SSH_HOST` `SSH_PORT` `SSH_USER` `SSH_KEY` `LOCAL_PORT`
`HOST_PORT_CANDIDATES` `HOST_ADDR` `SERVICE_LABEL` `HEALTH_URL` `SVC_USER` `SVC_HOME` `SVC_BIN`.
See `local.env.example` for the documented list.

## Using it for a different service

Nothing here is dsh-specific — only the unit names are. For Jupyter, for example:

```bash
cat > local.env <<'EOF'
LOCAL_PORT=8888
SERVICE_LABEL="jupyter"
HEALTH_URL=http://127.0.0.1:8888/api
HOST_PORT_CANDIDATES="8888 8889"
SVC_USER=you
SVC_HOME=/home/you
SVC_BIN=/usr/bin/python3
EOF
sudo bash deploy.sh --restart
```

Without `HEALTH_URL` the readiness check is plain TCP connect, which works for any protocol.
With it, the URL must return 2xx/3xx when the service is actually usable — otherwise the
tunnel stays down on purpose (better no access than a half-dead endpoint).

## Config

Rendered into `/etc/default/dsh-tunnel`; the `local.env` values live in a managed block
that `deploy.sh` rewrites on every run (anything outside the block is preserved).

| Variable | Default | Meaning |
|---|---|---|
| `LOCAL_PORT` | `3080` | port the service listens on inside the guest |
| `SSH_HOST` | default gateway | host address (`ip route` gateway under libvirt NAT) |
| `SSH_PORT` / `SSH_USER` / `SSH_KEY` | `22` / current user / `~/.ssh/dsh-remote` | host sshd endpoint and key |
| `HOST_PORT_CANDIDATES` | `"3080 3000"` | landing ports on the host, in priority order |
| `HOST_ADDR` | `127.0.0.1` | `0.0.0.0` exposes to the LAN (needs `GatewayPorts`) |
| `SERVICE_LABEL` | `本地服务` | log wording only |
| `HEALTH_URL` | empty | HTTP health check instead of TCP connect |
| `HEALTH_CHECK_SEC` | `3` | how often to re-check the service while the tunnel is up |
| `LOCK_FILE` | auto | single-instance lock (falls back to `$TMPDIR` for non-root) |

Apply changes with `sudo systemctl restart dsh-tunnel.service` (or `deploy.sh --restart`).

## LAN access (optional)

By default the tunnel binds host loopback only. On the **host** as root:

```bash
sudo bash install-host.sh        # writes GatewayPorts clientspecified + ufw rules
```

Then in the guest add `HOST_ADDR=0.0.0.0` to `local.env`, `sudo bash deploy.sh --restart`.

`GatewayPorts clientspecified` (not `yes`): only forwards explicitly asking for
`0.0.0.0:PORT` get exposed.

## Tests & CI

No libvirt, no second machine:

```bash
bash tests/units.sh             # render units + systemd-analyze verify (no root)
bash tests/deploy.sh            # local.env → managed block (idempotent, preserves extras)
bash tests/e2e.sh ./tunnel.sh   # 8 scenarios against a real sshd on 127.0.0.1
```

`tests/e2e.sh` lets one machine play both guest and host (`ssh -R` into its own sshd);
it generates a throwaway key, cleans up afterwards, and covers readiness wait, fallback,
upgrade, backend death, `HEALTH_URL` gating, `SIGTERM` cleanup, failed probes, and
double-start. CI runs all of the above plus `bash -n` and `shellcheck`.

## Uninstall

```bash
sudo bash uninstall.sh --dry-run
sudo bash uninstall.sh              # guest side
sudo bash uninstall.sh --purge-host # on the host: remove GatewayPorts drop-in + ufw rules
```

## Known limitations

- The service must stay bound to loopback; exposing it is the tunnel's job.
- At least one landing port on the host must be available.
- Unit names are still `dsh-*` for backward compatibility; renaming them is v0.4 work.

## License

[MIT](LICENSE)
