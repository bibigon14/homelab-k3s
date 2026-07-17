# Homelab Roadmap

This tracks planned upgrades to the homelab beyond the current single-node
setup. Each phase builds on the previous one - don't skip ahead, the
dependencies are real (storage before stateful workloads, networking before
mesh, etc.).

Status legend: not started / in progress / done

---

## Phase 0 - No new hardware needed

Can start any time on the current single Pi 5.

| Item | Status | Why |
|------|--------|-----|
| Kyverno (policy as code) | not started | Block deploys missing resource limits/probes - a common CrashLoopBackOff cause in my k8s troubleshooting practice |
| Trivy image scanning in CI | not started | Scan images in GitHub Actions before they ever reach the cluster |
| Argo Rollouts | not started | Canary/blue-green on top of ArgoCD, works fine even with replicas=1 today |

## Phase 1 - Second and third node (after next hardware purchase)

Requires 2 additional Raspberry Pis joined as k3s agents.

| Item | Status | Why |
|------|--------|-----|
| Multi-node k3s | not started | Join new Pis as agents; enables real scheduling and nodeAffinity |
| Move Prometheus + Alertmanager into k8s | not started | Currently bare-metal systemd services competing with docker builds for CPU/IO on the same node - see [runbook: Local Image Builds](runbooks/local-image-builds.md). Containerizing lets us pin them to a dedicated "monitoring" node via nodeAffinity |
| Rook-Ceph or Longhorn | not started | Real distributed storage across nodes. Needed before other stateful workloads scale - see [ADR-001](adr/001-k3s.md), which already flags local-path as not portable |
| Velero | not started | Backup/DR practice, makes sense once there's real distributed storage to protect |

## Phase 2 - Networking layer (higher risk, plan a maintenance window)

| Item | Status | Why |
|------|--------|-----|
| Cilium (replace flannel CNI) | not started | eBPF-based networking + Hubble for traffic visibility. Best done via fresh k3s install with `--flannel-backend=none` rather than a live CNI swap |
| Service mesh (Linkerd) | not started | mTLS between services, canary routing, retry/circuit-breaking out of the box - direct upgrade over the hand-rolled retry logic in river-bot/wc2026bot |

## Phase 3 - Security hardening

| Item | Status | Why |
|------|--------|-----|
| Falco | not started | Runtime anomaly detection |
| Expanded Kyverno policies | not started | Deny privilege escalation, require cosign-signed images |

## Phase 4 - AI/ML infra

| Item | Status | Why |
|------|--------|-----|
| Self-hosted inference (Ollama/vLLM) | not started | Quantized models to start - 8GB per Pi 5 is tight for full-size models. Directly relevant to modern AI infra observability work |
| Inference latency/throughput metrics | not started | Feed into existing Prometheus/Grafana stack, same SLO discipline as everything else |

---

## Open questions

- Registry: local-build-and-import (`k3s ctr images import`) doesn't scale past one node. Need a real registry (self-hosted `registry:2` or similar) before Phase 1 pods can be scheduled anywhere but the original node.
- Storage class migration: existing PVs are local-path (node-local). Rook-Ceph/Longhorn migration needs a data-move plan, not just a fresh StorageClass.
- Cilium swap risk: a live CNI replacement can take down pod networking cluster-wide if it goes wrong. Strongly prefer a fresh k3s install for this step over an in-place migration.
