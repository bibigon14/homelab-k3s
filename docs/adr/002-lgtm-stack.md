# ADR-002: LGTM Observability Stack

Date: 2026-06
Status: Accepted

## Context

Needed full observability (metrics, logs, traces) on constrained ARM64 hardware. Options: ELK, PLG, Datadog/New Relic (SaaS), LGTM.

## Decision

Use Prometheus + Loki + Tempo + Grafana (LGTM) with Thanos for long-term metrics.

## Reasons

- Resource efficiency: Loki indexes only metadata - 10-100x less RAM than Elasticsearch for the same log volume.
- Single UI: Grafana unifies metrics, logs, and traces with correlated views.
- Production alignment: LGTM is the stack used at scale by cloud-native companies. PromQL, LogQL, TraceQL skills transfer directly.
- Open source: Apache 2.0 / AGPL. No per-host licensing cost.
- Thanos: adds deduplication, unlimited retention, and global query across multiple Prometheus instances.

## Consequences

- Five separate services vs. a single SaaS agent. Accepted - operating this stack is the point.
- Tempo distributed mode runs 5 components even single-replica. Mirrors production topology.
- No object storage (local filesystem). Migration is a config change when needed.
