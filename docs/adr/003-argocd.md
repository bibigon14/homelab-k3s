# ADR-003: ArgoCD for GitOps Delivery

Date: 2026-06
Status: Accepted

## Context

Needed a way to deploy Kubernetes manifests and Helm charts without manual kubectl apply after every change. Options: manual kubectl, Flux CD, ArgoCD, Helm-only CI.

## Decision

Use ArgoCD.

## Reasons

- Pull-based GitOps: no push credentials on a CI runner needed to reach the cluster.
- Helm native: renders Helm charts server-side including override values.
- Visual diff: UI shows exactly what will change before sync.
- selfHeal: automatically reverts manual kubectl edits back to git state.
- Industry standard: most widely adopted GitOps controller.

## Consequences

- Secret management tension: selfHeal overwrites live Secrets with empty values if secrets are not in git. Fix: secrets created imperatively outside ArgoCD; Applications use ignoreDifferences on Secret /data.
- Sync delay: ~3 min between git push and cluster sync. Webhook integration would reduce this to seconds.
