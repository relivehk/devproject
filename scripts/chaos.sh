#!/bin/bash
# chaos.sh <mariadb|uptime-kuma> <stop|crash>
#   stop  — docker stop (ручная остановка: restart-policy по правилам Docker НЕ срабатывает),
#           проверяем DOWN на дашборде, затем docker start и проверяем UP.
#   crash — SIGKILL главному процессу в обход Docker (как настоящее падение),
#           проверяем DOWN, затем ждём, пока restart-policy сама поднимет контейнер (RestartCount растёт), и UP.
set -euo pipefail
TARGET="${1:-mariadb}"; MODE="${2:-stop}"
POLL=10

case "$TARGET" in
  mariadb)     Q='mysql_up' ;;
  uptime-kuma) Q='probe_success{job="blackbox-kuma"}' ;;
  *) echo "unknown target: $TARGET (mariadb|uptime-kuma)"; exit 1 ;;
esac
case "$MODE" in stop|crash) ;; *) echo "unknown mode: $MODE (stop|crash)"; exit 1 ;; esac

docker rm -f chaos-probe >/dev/null 2>&1 || true
docker run -d --rm --name chaos-probe --network kuma-net --entrypoint sh curlimages/curl:8.11.1 -c 'sleep 900' >/dev/null
trap 'docker rm -f chaos-probe >/dev/null 2>&1 || true' EXIT

pq() { docker exec chaos-probe curl -s http://prometheus:9090/api/v1/query --data-urlencode "query=$1" \
       | jq -r '.data.result[0].value[1] // "none"'; }

wait_metric() {  # wait_metric <expected> <timeout_sec>
  local t=0 v
  while [ $t -le "$2" ]; do
    v=$(pq "$Q"); printf '  t+%-4ss %s = %s\n' "$t" "$Q" "$v"
    [ "$v" = "$1" ] && return 0
    sleep $POLL; t=$((t+POLL))
  done
  return 1
}

echo "== baseline ($TARGET)"
wait_metric 1 60 || { echo "target is not healthy before the test"; exit 1; }
before=$(docker inspect -f '{{.RestartCount}}' "$TARGET")

if [ "$MODE" = "stop" ]; then
  echo "== docker stop $TARGET"
  docker stop "$TARGET" >/dev/null
else
  pid=$(docker inspect -f '{{.State.Pid}}' "$TARGET")
  echo "== simulating crash: SIGKILL to host pid $pid of $TARGET (bypassing docker)"
  docker run --rm --privileged --pid=host alpine:3.21 kill -9 "$pid"
fi

echo "== waiting for DOWN on dashboard"
if wait_metric 0 90; then
  echo "  -> DOWN confirmed (dashboard panel is red)"
elif [ "$MODE" = "crash" ]; then
  echo "  -> DOWN not caught by scrape: container restarted faster than scrape interval"
else
  echo "  -> DOWN never observed"; exit 1
fi

if [ "$MODE" = "stop" ]; then
  echo "== manual stop: restart-policy does not apply by design, running docker start"
  docker start "$TARGET" >/dev/null
else
  echo "== waiting for restart-policy to bring container back"
fi

echo "== waiting for UP"
wait_metric 1 180 || { echo "  -> no recovery within 180s"; exit 1; }
echo "  -> UP confirmed (dashboard panel is green)"

after=$(docker inspect -f '{{.RestartCount}}' "$TARGET")
health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' "$TARGET")
echo "== summary: mode=$MODE RestartCount $before -> $after, health=$health"
if [ "$MODE" = "crash" ] && [ "$after" -le "$before" ]; then
  echo "RESULT: FAILED — restart-policy did not restart the container"; exit 1
fi
echo "RESULT: CHAOS TEST PASSED"
