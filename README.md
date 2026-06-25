# homelab-k3s

Kubernetes manifests and Helm charts for my Raspberry Pi 5 homelab — a single-node [k3s](https://k3s.io/) cluster managed via [Helm](https://helm.sh/) and [ArgoCD](https://argo-cd.readthedocs.io/).

## Why

Started on Docker Compose and systemd (see [wc2026-telegram-bot](https://github.com/bibigon14/wc2026-telegram-bot), [alertmanager-telegram-bridge](https://github.com/bibigon14/alertmanager-telegram-bridge), [iptv-traceroute-analyzer](https://github.com/bibigon14/iptv-traceroute-analyzer)), then migrated everything to k3s and progressively added Helm packaging, GitOps-style delivery via ArgoCD, and Traefik-based ingress with local TLS for all homelab services.

This repo holds infrastructure manifests and Helm charts separately from application code — closer to how most teams split app repos from infra/GitOps repos in practice.

## Cluster

- Single-node k3s on a Raspberry Pi 5 8GB
- `local-path` is the default StorageClass (k3s built-in)
- Traefik ingress controller (k3s default) — used for all `*.homelab.local` services

## Structure

```
namespaces/
  homelab.yaml                        # homelab namespace
charts/
  alertmanager-telegram-bridge/       # Helm chart: Deployment + NodePort Service + Secret
  redis/                              # Helm chart: Deployment + PVC + ClusterIP Service
  wc2026bot/                          # Helm chart: Deployment + PVC + Secret + initContainer
  iptv-traceroute-analyzer/           # Helm chart: 3 CronJobs + Secret
  kube-state-metrics/                 # Helm chart: ClusterRole/ClusterRoleBinding + Deployment + Service
  loki/                               # Helm chart: single-binary Loki, Deployment + PVC + Service
  alloy/                              # Helm chart: Grafana Alloy DaemonSet + RBAC (log shipper)
argocd/
  bridge-app.yaml                     # ArgoCD Application for bridge
  redis-app.yaml                      # ArgoCD Application for redis
  wc2026bot-app.yaml                  # ArgoCD Application for wc2026bot
  iptv-app.yaml                       # ArgoCD Application for iptv (auto-sync disabled, see below)
  kube-state-metrics-app.yaml         # ArgoCD Application for kube-state-metrics
  loki-app.yaml                       # ArgoCD Application for loki
  alloy-app.yaml                      # ArgoCD Application for alloy
ingress/
  argocd-ingress.yaml                 # IngressRoute: argocd.homelab.local
  grafana-ingress.yaml                # IngressRoute: grafana.homelab.local
  uptime-kuma-ingress.yaml            # IngressRoute: uptime.homelab.local
  homebridge-ingress.yaml             # IngressRoute: homebridge.homelab.local
  influxdb-ingress.yaml               # IngressRoute: influxdb.homelab.local
  pihole-ingress.yaml                 # IngressRoute: pihole.homelab.local
  cadvisor-ingress.yaml               # IngressRoute: cadvisor.homelab.local
  thanos-ingress.yaml                 # IngressRoute: thanos.homelab.local
  alertmanager-ingress.yaml           # IngressRoute: alertmanager.homelab.local
  prometheus-ingress.yaml             # IngressRoute: prometheus.homelab.local
certs/
  ca.crt                              # Homelab CA certificate (add to Keychain for trusted TLS)
  homelab.local.crt                   # Wildcard cert for *.homelab.local
```

## Apps

### redis

Shared cache and state store used by `wc2026bot` and `iptv-notify`/`iptv-auto-switch` (alert dedup, current-server state). Persists to a 1Gi PVC. Exposed as `redis:6379` within the `homelab` namespace.

### wc2026bot

[World Cup 2026 Telegram bot](https://github.com/bibigon14/wc2026-telegram-bot) — Redis-cached API calls, per-user rate limiting. `access.log` persisted to a 64Mi PVC via `subPath` mount (initContainer ensures the file exists before the main container starts).

> If `local-path`'s PVC is ever recreated (helm uninstall/install, PV reclaim), the backing directory under `/var/lib/rancher/k3s/storage/` gets a new name (it's keyed by PV UID), silently breaking any symlink pointing at the old path. See `relink-logs.sh` in the [wc2026-telegram-bot](https://github.com/bibigon14/wc2026-telegram-bot) repo for a script that re-detects the current path via `kubectl` and fixes the symlink. Also worth granting your user read access once instead of `sudo cat`-ing every time:
> ```bash
> sudo apt install -y acl
> sudo setfacl -R -m u:<your-user>:rX /var/lib/rancher/k3s/storage/
> sudo setfacl -d -m u:<your-user>:rX /var/lib/rancher/k3s/storage/
> ```

### bridge (alertmanager-telegram-bridge)

[Prometheus Alertmanager → Telegram forwarder](https://github.com/bibigon14/alertmanager-telegram-bridge). Exposed via `NodePort 30119` so the host's systemd-managed Alertmanager can reach it at `http://localhost:30119/webhook`. Config (token, chat ID, routing rules, quiet hours) mounted from a Secret as `/config/config.yaml`.

### iptv (iptv-traceroute-analyzer)

[IPTV server health monitor](https://github.com/bibigon14/iptv-traceroute-analyzer) — three CronJobs replacing host crontab entries:

- `iptv-influx-writer` — every 30 min, `mtr`-based checks against 8 servers, writes to InfluxDB
- `iptv-notify` — at :15 and :45, 7am–11pm Pacific, Telegram alerts on degradation (dedup via Redis)
- `iptv-auto-switch` — hourly, switches active IPTV server based on hysteresis logic, persists current server choice to Redis (`iptv:current_server`)

All three require `NET_RAW`/`NET_ADMIN` for `mtr` and explicit `timeZone: "America/Los_Angeles"` (k8s CronJob defaults to UTC). All three get their full env from the `iptv-env` Secret via `envFrom` — no per-CronJob `env:` overrides; keep it that way (see the ArgoCD section below for why a stray per-CronJob `env:` block caused hours of debugging here).

Images are built locally and imported via `k3s ctr images import` — no registry needed on a single-node cluster.

> InfluxDB and Alertmanager run on the host via systemd. CronJobs reach them via `192.168.50.212`.

### kube-state-metrics

[Kubernetes object-state exporter](https://github.com/kubernetes/kube-state-metrics) — exposes Prometheus metrics for Pod/Deployment/Job/CronJob/PVC status that no resource-usage-based exporter (like cAdvisor) can see. Backed by a ClusterRole with read-only `list`/`watch` access to most cluster object types. Paired with [homelab-observability's k3s-alerts.yml](https://github.com/bibigon14/homelab-observability) for alerting — see that repo for the full rationale and alert rules.

### loki + alloy

Centralized log aggregation: [Loki](https://grafana.com/oss/loki/) (single-binary mode, 10Gi PVC, 7-day retention, filesystem storage backend) paired with [Grafana Alloy](https://grafana.com/docs/alloy/) as the log shipper, deployed as a DaemonSet.

Alloy discovers pods via the Kubernetes API (`discovery.kubernetes`), filters to the `homelab` namespace, and builds the on-disk log path matching k3s/containerd's layout (`/var/log/pods/<namespace>_<pod>_<uid>/*/*.log`) via a hostPath mount — this requires `runAsUser: 0` since `/var/log/pods` is root-owned. Logs are parsed with `stage.cri {}` to extract the actual message from containerd's structured JSON wrapper before shipping to Loki.

Exposed via `NodePort 30811` (same reasoning as kube-state-metrics/argocd-metrics — Grafana runs on the host, outside the cluster, with no DNS resolution for in-cluster Service names like `loki`). Add it as a Grafana data source pointing at `http://localhost:30811`, type Loki.

On first deploy this immediately surfaced two real issues that had been invisible without searchable logs: a Telegram `getUpdates` `409 Conflict` (two long-pollers fighting over one bot token) and a `kube-state-metrics` RBAC gap on `mutatingwebhookconfigurations` at cluster scope.

### thanos

[Thanos](https://thanos.io/) v0.41.0 — long-term metric storage with unlimited retention, deployed as four systemd services on the host (not in k3s, since Prometheus itself runs on the host):

- **Sidecar** (`:10901` gRPC, `:19191` HTTP) — connects to Prometheus TSDB, ships completed 2h blocks to object storage
- **Store Gateway** (`:10902` gRPC, `:19192` HTTP) — serves historical blocks from object storage for queries
- **Query** (`:10903` gRPC, `:19193` HTTP) — unified PromQL endpoint, fans out to Sidecar (real-time) + Store (historical)
- **Compactor** (`:19194` HTTP) — compacts and downsamples blocks in object storage

Object storage: **Cloudflare R2** bucket `homelab-thanos` (WNAM region, S3-compatible API, free egress). Config at `/etc/thanos/objstore.yml`. Prometheus was reconfigured with `--storage.tsdb.min-block-duration=2h --storage.tsdb.max-block-duration=2h` to produce Thanos-compatible blocks (disables Prometheus's own compaction — Thanos Compactor handles it instead).

Added as a Grafana datasource ("Thanos", type Prometheus, `http://localhost:19193`). All existing PromQL queries and dashboards work unchanged — just switch the datasource selector from "prometheus" to "Thanos" for unlimited time range.

**UI:** `https://thanos.homelab.local`

## Helm

Each app is packaged as a Helm chart under `charts/`. Sensitive values (tokens, API keys) live in `values.secret.yaml` which is excluded from the repo via `.gitignore`.

### Install / upgrade

```bash
cd charts/<chart-name>
helm install <release-name> . -f values.secret.yaml -n homelab
helm upgrade <release-name> . -f values.secret.yaml -n homelab
```

> `kube-state-metrics`, `loki`, and `alloy` have no secrets, so they're installed without `-f values.secret.yaml`:
> `helm install kube-state-metrics . -n homelab`

### Check releases

```bash
helm list -n homelab
```

### values.secret.yaml structure

**bridge** — `charts/alertmanager-telegram-bridge/values.secret.yaml`:

```yaml
config:
  telegram:
    token: "<bot-token>"
    default_chat_id: "<chat-id>"
  routes:
    - match:
        severity: critical
      chat_id: "<chat-id>"
      continue: false
    - match:
        severity: warning
      chat_id: "<chat-id>"
      continue: false
```

**wc2026bot** — `charts/wc2026bot/values.secret.yaml`:

```yaml
env:
  BOT_TOKEN: "<token>"
  CHAT_ID: "<chat-id>"
  CHECK_INTERVAL: "5"
  FOOTBALL_API_KEY: "<key>"
  LANG_BOT: "ru"
  SEND_TIME: "08:00"
```

**iptv** — `charts/iptv-traceroute-analyzer/values.secret.yaml`:

```yaml
env:
  CBILLING_USER: "<user>"
  CBILLING_PASS: "<pass>"
  CBILLING_SESSION: "<session>"
  CBILLING_PACKAGE: "<package>"
  INFLUX_URL: "http://192.168.50.212:8086"
  INFLUX_TOKEN: "<token>"
  INFLUX_ORG: "homebridge"
  INFLUX_BUCKET: "iptv_metrics"
  TELEGRAM_TOKEN: "<token>"
  TELEGRAM_CHAT_ID: "<chat-id>"
  IPTV_REDIS_HOST: "redis"
  IPTV_REDIS_PORT: "6379"
```

> After editing any `values.secret.yaml`, run `helm upgrade` immediately — the file is gitignored, so there's no diff/PR trail to catch a stale deploy. A `values.secret.yaml` edit that isn't followed by an upgrade is invisible drift: `helm get values` will show the new file, but the live Secret in the cluster keeps the old one until the next upgrade.

> Also keep all per-app env vars inside the **Secret** (i.e. under `values.secret.yaml`'s `env:` map), not as one-off `env:` entries hand-added to a specific CronJob/Deployment template. A stray `env:` block added to only one of several CronJob templates is easy to miss when something has 3+ near-identical jobTemplates — it silently works for that one job and silently doesn't exist for the others, with no error, just wrong behavior. Keeping `envFrom: secretRef` as the *only* source of env vars means there's exactly one place to look.

## ArgoCD

ArgoCD watches this repo and syncs apps on every push to `main` — but **not automatically for every app**, see below.

**UI:** `https://argocd.homelab.local`

### Apply ArgoCD Applications

```bash
kubectl apply -f argocd/
```

### Check sync status

```bash
argocd app list
```

### selfHeal vs values.secret.yaml — a real incident

`syncPolicy.automated.selfHeal: true` makes ArgoCD continuously reconcile live cluster state back to whatever's in git. Since `values.secret.yaml` is gitignored, ArgoCD's own Helm render of a chart has **no secret values at all** — every key in the Secret renders empty. With `selfHeal: true`, ArgoCD will periodically re-apply that empty-valued Secret over whatever a manual `helm upgrade -f values.secret.yaml` just deployed, and the live Secret silently reverts.

This actually happened to `iptv`: a `TELEGRAM_TOKEN` and `IPTV_REDIS_HOST`/`PORT` fix kept appearing to "not take" across multiple `helm upgrade` runs, because ArgoCD's selfHeal sync was racing the manual upgrade and winning a few minutes later. An `ignoreDifferences` rule on the Secret's `/data` path was already in place but didn't prevent this reliably.

**Fix applied:** `argocd/iptv-app.yaml` now has `syncPolicy: {}` — no `automated` block, so ArgoCD only syncs `iptv` on an explicit `argocd app sync iptv` / UI sync click. Manifests (CronJobs, etc.) still need a manual sync after a git push; the Secret is managed entirely outside ArgoCD via `helm upgrade -f values.secret.yaml`.

**One more wrinkle found later the same day:** even after applying `syncPolicy: {}`, the Secret went empty again hours later. `kubectl get application iptv -n argocd -o jsonpath='{.status.history}'` showed an `automated: true`-initiated sync timestamped right around when the `syncPolicy: {}` fix was applied — a sync that was already in flight (queued against the old, still-automated spec) landed *after* `kubectl apply` updated the spec, so it looked like the fix "didn't take" when really it was the last automated sync to sneak through during the transition. Re-running `helm upgrade -f values.secret.yaml` resolved it, and `.status.history` confirmed the next sync was `initiatedBy: {username: admin}` (manual), not automated. Lesson: after disabling `automated` sync on an app with a secret-drift problem, don't assume it's instantly safe — verify the Secret immediately after, and check `.status.history` if it looks like déjà vu.

Apps with no secrets at all (`kube-state-metrics`, `loki`, `alloy`) keep `automated.selfHeal: true` — there's no gitignored values file for ArgoCD's render to diverge from, so auto-sync is safe there.

If you hit something similar on another app here, the general options are:
1. Disable `automated` sync for that Application (what we did for `iptv`) — simplest, but you lose auto-deploy-on-push for everything in that app, not just the Secret.
2. Keep the Secret out of the Helm chart entirely — create/manage it with a separate `kubectl create secret` (or a tool like `sealed-secrets`/`external-secrets`) that ArgoCD's `Application` doesn't own or track at all.
3. Trust `ignoreDifferences` on `/data` — works in many setups, but as seen above isn't airtight against every sync trigger.

### Expose ArgoCD server (one-time setup)

```bash
kubectl patch svc argocd-server -n argocd \
  -p '{"spec": {"type": "NodePort", "ports": [{"port": 443, "targetPort": 8080, "nodePort": 30808, "name": "https"}]}}'
```

### Expose ArgoCD metrics for Prometheus (optional, one-time setup)

Only needed if running Prometheus on the host (outside the cluster), to scrape ArgoCD sync/health status — see [homelab-observability's argocd-alerts.yml](https://github.com/bibigon14/homelab-observability):

```bash
kubectl patch svc argocd-metrics -n argocd \
  -p '{"spec": {"type": "NodePort", "ports": [{"port": 8082, "targetPort": 8082, "nodePort": 30810, "name": "metrics"}]}}'
```

### Get admin password

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

## Traefik Ingress

All homelab services are exposed via Traefik with a wildcard TLS certificate for `*.homelab.local`. DNS is handled by Pi-hole.

### Services

| URL | Service | Port |
|-----|---------|------|
| `https://argocd.homelab.local` | ArgoCD | 80 (internal) |
| `https://grafana.homelab.local` | Grafana | 3000 |
| `https://uptime.homelab.local` | Uptime Kuma | 3001 |
| `https://homebridge.homelab.local` | Homebridge | 8581 |
| `https://influxdb.homelab.local` | InfluxDB | 8086 |
| `https://pihole.homelab.local` | Pi-hole | 8090 |
| `https://cadvisor.homelab.local` | cAdvisor | 8080 |
| `https://thanos.homelab.local` | Thanos Query | 19193 |
| `https://alertmanager.homelab.local` | Alertmanager | 9093 |
| `https://prometheus.homelab.local` | Prometheus | 9090 |

> Note: Pi-hole web interface was moved from port 80 to 8090 to avoid conflict with Traefik.

### NodePort services (not behind Traefik)

Some services are reached directly via NodePort rather than through Traefik/TLS — mostly internal scrape/query targets for host-based Prometheus and Grafana, or webhooks from host-based daemons. Both run outside the cluster, so they can't resolve in-cluster Service DNS names:

| Port | Service | Purpose |
|------|---------|---------|
| `30119` | bridge (alertmanager-telegram-bridge) | Alertmanager webhook target |
| `30808` | argocd-server | HTTPS UI/API, alternative to the Traefik route |
| `30809` | kube-state-metrics | Prometheus scrape target |
| `30810` | argocd-metrics | Prometheus scrape target |
| `30811` | loki | Grafana data source query target |
| `19193` | thanos-query | Grafana data source + UI (host systemd, not NodePort) |

### TLS setup

A local CA (`certs/ca.crt`) signs a wildcard certificate for `*.homelab.local`. To trust it on macOS:

1. Download `certs/ca.crt` from this repo
2. Double-click → Keychain Access → add to **System** keychain
3. Find **Homelab CA** → Get Info → Trust → **Always Trust**

### DNS setup (Pi-hole)

```bash
sudo pihole-FTL --config dns.hosts '[
  "192.168.50.1 router.asus.com",
  "192.168.50.212 argocd.homelab.local",
  "192.168.50.212 grafana.homelab.local",
  "192.168.50.212 uptime.homelab.local",
  "192.168.50.212 homebridge.homelab.local",
  "192.168.50.212 influxdb.homelab.local",
  "192.168.50.212 pihole.homelab.local",
  "192.168.50.212 cadvisor.homelab.local",
  "192.168.50.212 thanos.homelab.local",
  "192.168.50.212 alertmanager.homelab.local",
  "192.168.50.212 prometheus.homelab.local"
]'
sudo systemctl restart pihole-FTL
```

### Regenerate certificates (valid 10 years)

```bash
cd certs/
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
  -out ca.crt -subj "/C=US/ST=California/L=Roseville/O=Homelab/CN=Homelab CA"
openssl genrsa -out homelab.local.key 2048
openssl req -new -key homelab.local.key -out homelab.local.csr \
  -subj "/CN=*.homelab.local" \
  -addext "subjectAltName=DNS:*.homelab.local,DNS:homelab.local"
openssl x509 -req -in homelab.local.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out homelab.local.crt -days 3650 -sha256 \
  -extfile <(echo "subjectAltName=DNS:*.homelab.local,DNS:homelab.local")
kubectl create secret tls homelab-tls --cert=homelab.local.crt --key=homelab.local.key \
  -n argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret tls homelab-tls --cert=homelab.local.crt --key=homelab.local.key \
  -n default --dry-run=client -o yaml | kubectl apply -f -
```

## Update workflow

After a code change in an app repo:

```bash
cd /path/to/app-repo
docker build -t <image>:latest .
docker save <image>:latest | sudo k3s ctr images import -
kubectl rollout restart deployment/<name> -n homelab
# CronJobs pick up the new image on their next scheduled run
```

To update chart configuration (non-secret values):

```bash
# Edit charts/<chart>/values.yaml, then:
git add charts/<chart>/values.yaml
git commit -m "chore: update <chart> values"
git push
# ArgoCD syncs automatically within ~3 minutes for apps with automated
# sync enabled. For iptv (automated sync disabled, see ArgoCD section),
# sync manually: argocd app sync iptv
```

> Note: editing a ConfigMap (e.g. `alloy/templates/configmap.yaml`) via `helm upgrade` does **not** restart pods that mount it — kubelet eventually syncs the file in-place, but a running process (like Alloy) won't reload it without a restart. After a ConfigMap-only change: `kubectl rollout restart daemonset/<name> -n homelab` (or `deployment/<name>`).

## Status

```bash
kubectl get pods -n homelab
kubectl get cronjobs -n homelab
helm list -n homelab
argocd app list
kubectl get ingressroute -n default
kubectl get ingressroute -n argocd
```

## License

MIT
