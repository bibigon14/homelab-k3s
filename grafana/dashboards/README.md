# Grafana dashboards

JSON exports of Grafana dashboards used on the homelab. Source of truth for
panel layout, queries, and thresholds. To restore on a fresh Grafana instance:

    curl -X POST http://localhost:3000/api/dashboards/db \
      -H "Authorization: Bearer $GRAFANA_TOKEN" \
      -H "Content-Type: application/json" \
      -d @grafana/dashboards/<name>.json

Dashboards listed here are committed alongside the code/charts that produce
the metrics they visualize, so dashboard + metric source stay in sync via git.

## telegram-bots.json

RED panels for alertmanager-telegram-bridge and wc2026bot.
Datasource: prometheus.
