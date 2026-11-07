#!/bin/bash
# Проверяет здоровье всех контейнеров, targets Prometheus и наличие дашборда.
set -euo pipefail
set -a; . /run/secrets/env; set +a
FAIL=0

echo "== containers"
for c in mariadb uptime-kuma prometheus grafana node-exporter cadvisor mysqld-exporter blackbox-exporter; do
  state=$(docker inspect -f '{{.State.Status}}{{if .State.Health}}/{{.State.Health.Status}}{{end}}' "$c" 2>/dev/null || echo "missing")
  printf '  %-18s %s\n' "$c" "$state"
  case "$state" in running|running/healthy) ;; *) FAIL=1 ;; esac
done

q() { docker run --rm --network kuma-net curlimages/curl:8.11.1 -s "$@"; }

echo "== prometheus targets"
q http://prometheus:9090/api/v1/targets | jq -r '.data.activeTargets[] | "  \(.labels.job)\t\(.health)"'
down=$(q http://prometheus:9090/api/v1/targets | jq '[.data.activeTargets[] | select(.health!="up")] | length')
[ "$down" = "0" ] || FAIL=1

echo "== grafana"
for f in compose/monitoring/grafana/dashboards/*.json; do
  uid=$(jq -r .uid "$f")
  code=$(q -o /dev/null -w "%{http_code}" -u "$GRAFANA_ADMIN_USER:$GRAFANA_ADMIN_PASSWORD" "http://grafana:3000/api/dashboards/uid/$uid")
  echo "  $(basename "$f") uid=$uid HTTP $code"
  [ "$code" = "200" ] || FAIL=1
done
[ $FAIL = 0 ] && echo "RESULT: ALL OK" || { echo "RESULT: FAILED"; exit 1; }

