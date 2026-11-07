#!/bin/sh
# Накатывает datasource и дашборды через Grafana HTTP API. Идемпотентен.
set -eu
apk add --no-cache curl jq >/dev/null

G="http://grafana:3000"
AUTH="$GRAFANA_ADMIN_USER:$GRAFANA_ADMIN_PASSWORD"

echo "waiting for grafana..."
i=0
until curl -sf "$G/api/health" >/dev/null; do
  i=$((i+1)); [ $i -ge 30 ] && { echo "grafana not healthy after 60s"; exit 1; }
  sleep 2
done

code=$(curl -s -o /tmp/ds.json -w '%{http_code}' -u "$AUTH" -H 'Content-Type: application/json' \
  -X POST "$G/api/datasources" -d '{
    "name":"Prometheus","type":"prometheus","uid":"prometheus",
    "url":"http://prometheus:9090","access":"proxy","isDefault":true}')
case "$code" in
  200) echo "datasource: created" ;;
  409) echo "datasource: already exists" ;;
  *)   echo "datasource: HTTP $code"; cat /tmp/ds.json; exit 1 ;;
esac

for f in /dash/*.json; do
  jq -n --slurpfile d "$f" '{dashboard: ($d[0] | .id = null), overwrite: true, folderId: 0}' > /tmp/payload.json
  code=$(curl -s -o /tmp/out.json -w '%{http_code}' -u "$AUTH" -H 'Content-Type: application/json' \
    -X POST "$G/api/dashboards/db" -d @/tmp/payload.json)
  if [ "$code" = "200" ]; then
    echo "dashboard $(basename "$f"): ok -> $(jq -r .url /tmp/out.json)"
  else
    echo "dashboard $(basename "$f"): HTTP $code"; cat /tmp/out.json; exit 1
  fi
done
