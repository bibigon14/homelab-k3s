# Ingress Health Check Runbook

**Scope**: homelab k3s cluster on `homebridge` (Raspberry Pi 5, 192.168.50.212)
**Stack**: k3s v1.35+ with default Traefik ingress, klipper-lb, self-signed wildcard TLS (`*.homelab.local`), Blackbox exporter + Prometheus for E2E probing

## Purpose

Verify that the ingress path is healthy end-to-end: control plane (Traefik), data plane (Ingress resources and their backends), TLS trust chain, and the external probe harness that watches all of it. Use this on-demand during incident triage, or as a periodic sanity check after cluster upgrades.

Target completion time: 2-3 minutes if everything is green.

## Prerequisites

- `kubectl` on your workstation with `homelab-k3s` context active (not EKS/GKE)
- SSH access to `homebridge` for Blackbox-side checks
- Blackbox exporter listening on `localhost:9115` on the Pi

### Context sanity

The single most common wrong-cluster footgun. Verify current context before running anything:

```bash
kubectl config current-context
# must print: homelab-k3s
```

If it prints anything else (EKS/GKE/minikube) stop and switch:

```bash
kubectl config use-context homelab-k3s
```

## Step 1 - Traefik control plane

```bash
kubectl -n kube-system get pods -l app.kubernetes.io/name=traefik -o wide
kubectl -n kube-system get deploy traefik
kubectl -n kube-system get svc traefik
```

**Expected**:
- Pod `Running`, low restart count, age consistent with last planned change
- Deployment `READY 1/1`, `AVAILABLE 1`
- Service `LoadBalancer`, `EXTERNAL-IP 192.168.50.212` (klipper-lb binds to node IP), ports `80:3xxxx/TCP,443:3xxxx/TCP`

**Red flags**:
- Pod `CrashLoopBackOff` or restart count climbing in last hour -> jump to Step 1a (logs)
- Service stuck `<pending>` on EXTERNAL-IP -> klipper-lb or k3s LoadBalancer broken, check `kubectl -n kube-system get pods -l svccontroller.k3s.cattle.io/svcname=traefik`
- Deploy `0/1` for extended period -> readiness or image pull problem

### Step 1a - Traefik logs (only if Step 1 flagged)

```bash
kubectl -n kube-system logs -l app.kubernetes.io/name=traefik --tail=200 --timestamps
kubectl -n kube-system logs -l app.kubernetes.io/name=traefik --previous
```

Look for `error`, `config reload failed`, `cannot find TLS cert`, repeated `backend down` entries.

## Step 2 - Ingress resources and backends

```bash
# All Ingress - ADDRESS column must be populated (192.168.50.212)
kubectl get ingress -A

# IngressRoute (Traefik CRD) - we don't use these, should be empty
kubectl get ingressroute -A 2>/dev/null

# Backend endpoints must be non-empty for every Service referenced by an Ingress
kubectl get endpoints -A | grep -v '<none>'
```

**Expected**:
- Every Ingress has `ADDRESS = 192.168.50.212`
- Every Service backing an Ingress has at least one IP in `ENDPOINTS`

**Red flags**:
- Ingress with empty ADDRESS -> Traefik hasn't programmed the LB yet, or `ingressClassName` mismatch
- `ENDPOINTS <none>` on a Service referenced by Ingress -> pod not Ready, or Service selector doesn't match pod labels. This causes silent 503s.

If an Ingress looks suspicious:

```bash
kubectl -n <ns> describe ingress <name>
```

Events at the bottom will show TLS secret misses, backend 404s, or admission webhook rejections.

## Step 3 - TLS wildcard certificate

### Expiry check

```bash
kubectl -n monitoring get secret homelab-tls -o jsonpath='{.data.tls\.crt}' | \
  base64 -d | openssl x509 -noout -dates -subject -issuer
```

**Expected**:
- `notAfter` more than 30 days out
- `subject CN=*.homelab.local`
- `issuer CN=Homelab CA` (internal self-signed)

The wildcard is **self-signed, not cert-manager managed**. Rotation is manual. Alert on expiry via x509-exporter + Prometheus; don't rely on remembering.

### cert-manager state (for the public `sre.dstepanov.dev` cert)

```bash
kubectl get certificate -A
```

**Expected**: `monitoring/sre-tls READY=True`. Managed automatically.

### Cross-namespace TLS secret replication

`homelab-tls` must exist in `argocd`, `default`, and `monitoring` namespaces (any namespace that terminates `*.homelab.local`). Verify:

```bash
kubectl get secret -A -o wide | grep homelab-tls
```

Three rows expected. If missing in a namespace, Traefik serves the default/fallback cert for that host - browsers will reject it even though ingress "works".

## Step 4 - End-to-end probe via Blackbox

SSH to the Pi:

```bash
ssh bibigon88@192.168.50.212
```

### Full probe sweep

```bash
# Internal homelab targets (self-signed, use https_homelab module)
for host in argocd grafana homebridge influxdb pihole uptime cadvisor; do
  r=$(curl -s "http://localhost:9115/probe?target=https://${host}.homelab.local&module=https_homelab" | \
      awk '/^probe_success/ {print $2}')
  printf '%-12s %s\n' "$host" "$r"
done

# External HTTP (public CA, use http_2xx module)
for site in 11446500 11447650; do
  url="https://waterservices.usgs.gov/nwis/iv/?sites=${site}&parameterCd=00060&format=json&period=PT1H"
  r=$(curl -s "http://localhost:9115/probe?target=${url}&module=http_2xx" | \
      awk '/^probe_success/ {print $2}')
  printf 'usgs %s  %s\n' "$site" "$r"
done

# DNS probe (Pi-hole)
r=$(curl -s "http://localhost:9115/probe?target=127.0.0.1:53&module=dns_pihole_homelab" | \
    awk '/^probe_success/ {print $2}')
echo "dns          $r"
```

**Expected**: all 10 return `1`.

**Red flags**: any `0`.

### Deep probe on a single target

```bash
curl -s 'http://localhost:9115/probe?target=https://grafana.homelab.local&module=https_homelab' | \
  grep -E '^probe_success|probe_http_status|probe_ssl|probe_http_version'
```

Decode:
- `probe_success 1` - probe succeeded end-to-end
- `probe_http_status_code 200` - HTTP response was 200. If 0, connection failed before HTTP.
- `probe_http_version 2` - HTTP/2 via Traefik
- `probe_ssl_earliest_cert_expiry <unix_ts>` - decode with `date -d @<ts>`, must match the secret expiry from Step 3
- `probe_ssl_last_chain_expiry_timestamp_seconds -6.21355968e+10` - this is Go's `time.Time{}` zero value, meaning no expired cert in chain. **Not a bug.**
- `probe_ssl_last_chain_info{...} 1` - leaf cert details, including SAN and issuer

### Gotcha: module selection matters

Blackbox has two HTTP modules:

| Module | Use for | TLS validation |
|--------|---------|----------------|
| `http_2xx` | External public-CA sites (USGS, etc) | Full validation |
| `https_homelab` | Internal `*.homelab.local` targets | `insecure_skip_verify: true` (TODO: switch to `ca_file`) |

Probing `*.homelab.local` with `http_2xx` **will fail with `probe_success 0`** because the self-signed cert won't validate against public CAs. This is correct behavior, not a probe failure.

## Step 5 - Prometheus scrape configuration

Verify Prometheus is actually scraping Blackbox with the right modules:

```bash
sudo grep -B2 -A25 'job_name.*blackbox' /etc/prometheus/prometheus.yml | head -100
```

**Expected jobs**:
- `blackbox-homelab-https` with `module: [https_homelab]`, 7 targets (`*.homelab.local`)
- `blackbox-external-http` with `module: [http_2xx]`, USGS endpoints
- `blackbox-dns-homelab` with `module: [dns_pihole_homelab]`, `127.0.0.1:53`

**Red flag**: `*.homelab.local` target under `module: [http_2xx]` instead of `https_homelab` -> silent `probe_success 0`, dashboards will look broken for no reason.

## Step 6 - Grafana SLO dashboard cross-check

Open `grafana.sre.dstepanov.dev` -> `SLO Error Budgets`.

**Expected**: all 7 https targets at identical `99.9802%` or similar (they share a single Traefik ingress, so one goes down = all go down. Identical numbers = healthy).

**Red flags**:
- One target below the rest -> backend application issue, not ingress
- All 7 synchronously down -> ingress/node/TLS/DNS problem
- All 7 at `0%` -> probably Blackbox or Prometheus itself is down

## Appendix A - Common failure modes

### "ADDRESS is empty on all Ingress"

k3s LoadBalancer controller (klipper-lb) crashed or Traefik Service lost its node binding.

```bash
kubectl -n kube-system get pods | grep svclb-traefik
kubectl -n kube-system logs <svclb-pod>
```

### "probe_success 0 for one host, others fine"

Backend problem, not ingress:

```bash
kubectl get endpoints -A | grep <service-name>
# empty? pods not Ready. check:
kubectl -n <ns> get pods -l app=<app>
kubectl -n <ns> describe pod <pod>
```

### "probe_success 0 for all hosts"

Traefik or node-level problem:

1. Is Traefik pod Running? (Step 1)
2. Is `192.168.50.212:443` reachable from the Pi? `curl -k https://localhost:443 -I`
3. Is DNS resolving? `getent hosts grafana.homelab.local` should return `192.168.50.212`

### "TLS handshake succeeds but probe says probe_success 0"

Wrong module. Verify with:

```bash
curl -s "http://localhost:9115/probe?target=https://<host>.homelab.local&module=https_homelab" | \
  grep probe_success
```

### "Deprecated v1 Endpoints warning"

Cosmetic. k8s 1.33+ uses EndpointSlice internally. Can ignore until Endpoints API is actually removed (not before 1.40).

## Appendix B - Known tech debt

1. `https_homelab` module uses `insecure_skip_verify: true` instead of `ca_file`. This masks cert expiry and mismatch detection. See `TODO.md` for remediation plan.
2. `blackbox.yml` lives only on the Pi, not in `homelab-observability` git repo.
3. `blackbox-external-http` job doesn't tag targets with `slo="probe_external"` label, so Alertmanager routing by SLO class doesn't fully work for external probes.

## Appendix C - References

- Traefik v3 docs: https://doc.traefik.io/traefik/
- Blackbox exporter config: https://github.com/prometheus/blackbox_exporter/blob/master/CONFIGURATION.md
- k3s networking: https://docs.k3s.io/networking
- x509-exporter: see `/areas/x509-exporter.md` in internal notes

---

**Last verified**: 2026-10-01. All 10 probe targets green, Traefik up 93 days, wildcard TLS valid until 2027-07-30.
