#!/usr/bin/env bash
# Repro: a sink removed from the config during a SIGHUP reload keeps running forever if its
# downstream never recovers (orphaned sink task).
#
#   1. One demo_logs source routed to two http sinks: "good" (always 200) and "bad" (always 429,
#      which is retriable, so the bad sink retries the same batch indefinitely).
#   2. After both sinks have traffic, remove sink_bad from the config and SIGHUP.
#   3. The reload completes. Then count requests still reaching the bad receiver well after the
#      60s reload drain timeout. Any request there is the orphaned task of a sink that no longer
#      exists in the running config.
#
# Usage: ./testing/orphan-sink/reproduce-orphan-sink.sh <image> [label]
#
# Exit codes:
#   0 - bug reproduced (removed sink still sending after reload + drain timeout)
#   1 - no orphan (removed sink stopped within the drain timeout)
#   2 - inconclusive (setup or reload failed)
set -euo pipefail
IMAGE="${1:?usage: $0 <image> [label]}"
LABEL="${2:-$IMAGE}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECEIVER_PY="$SCRIPT_DIR/receiver.py"
BASE_YAML="$SCRIPT_DIR/base.yaml"

SUFFIX="$$"
NETWORK="vector-orphan-net-$SUFFIX"
VECTOR_C="vector-orphan-$SUFFIX"
GOOD_C="recv-good-$SUFFIX"
BAD_C="recv-bad-$SUFFIX"
WORKDIR="$(mktemp -d)"

DRAIN_TIMEOUT=60          # RELOAD_DRAIN_TIMEOUT in src/topology/running.rs
GRACE=20                  # extra seconds after the drain timeout before judging
OBSERVE=40                # observation window after that

cleanup() {
  docker rm -f "$VECTOR_C" "$GOOD_C" "$BAD_C" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

write_sinks() {
  # $1 = "both" or "good-only"
  {
    echo "sinks:"
    echo "  sink_good:"
    echo "    type: http"
    echo "    inputs: [router.all]"
    echo "    uri: http://$GOOD_C:8001"
    echo "    method: post"
    echo "    encoding: { codec: json }"
    if [ "$1" = both ]; then
      echo "  sink_bad:"
      echo "    type: http"
      echo "    inputs: [router.all]"
      echo "    uri: http://$BAD_C:8001"
      echo "    method: post"
      echo "    encoding: { codec: json }"
    fi
  } > "$WORKDIR/sinks.yaml"
}

bad_requests_since() {
  # $1 = unix time; counts receiver log lines newer than it
  docker logs "$BAD_C" 2>/dev/null | awk -v t="$1" '$1=="REQ" && $2>t {n++} END{print n+0}'
}
good_requests_since() {
  docker logs "$GOOD_C" 2>/dev/null | awk -v t="$1" '$1=="REQ" && $2>t {n++} END{print n+0}'
}
reload_markers() {
  docker logs "$VECTOR_C" 2>&1 | grep -c "New configuration loaded successfully" || true
}

echo "==> [$LABEL] image: $IMAGE"
cp "$BASE_YAML" "$WORKDIR/base.yaml"
write_sinks both

docker network create "$NETWORK" >/dev/null
docker run -d --name "$GOOD_C" --network "$NETWORK" -e PORT=8001 -e STATUS=200 \
  -v "$RECEIVER_PY:/receiver.py:ro" python:3.12-alpine python3 /receiver.py >/dev/null
docker run -d --name "$BAD_C" --network "$NETWORK" -e PORT=8001 -e STATUS=429 \
  -v "$RECEIVER_PY:/receiver.py:ro" python:3.12-alpine python3 /receiver.py >/dev/null
docker run -d --name "$VECTOR_C" --network "$NETWORK" \
  -v "$WORKDIR:/etc/vector:ro" "$IMAGE" --config-dir /etc/vector >/dev/null

echo "==> waiting for both sinks to see traffic"
t0=$(date +%s)
for _ in $(seq 60); do
  if [ "$(good_requests_since 0)" -gt 0 ] && [ "$(bad_requests_since 0)" -gt 0 ]; then break; fi
  sleep 1
done
if [ "$(bad_requests_since 0)" -eq 0 ]; then
  echo "SETUP FAILED: bad receiver never got a request"; docker logs "$VECTOR_C" 2>&1 | tail -20; exit 2
fi
echo "    good=$(good_requests_since 0) bad=$(bad_requests_since 0) requests after $(( $(date +%s) - t0 ))s"

echo "==> letting the bad sink accumulate retries for 20s"
sleep 20
echo "    bad receiver requests so far: $(bad_requests_since 0)"

echo "==> removing sink_bad from the config and sending SIGHUP"
write_sinks good-only
sleep 2
before=$(reload_markers)
t_reload=$(date +%s)
docker kill -s SIGHUP "$VECTOR_C" >/dev/null
for _ in $(seq 60); do
  [ "$(reload_markers)" -gt "$before" ] && break
  sleep 1
done
if [ "$(reload_markers)" -le "$before" ]; then
  echo "INCONCLUSIVE: reload did not complete within 60s"; docker logs "$VECTOR_C" 2>&1 | tail -20; exit 2
fi
echo "    reload completed after $(( $(date +%s) - t_reload ))s"

wait_until=$(( t_reload + DRAIN_TIMEOUT + GRACE ))
echo "==> waiting until drain timeout + grace (${DRAIN_TIMEOUT}+${GRACE}s after reload)"
while [ "$(date +%s)" -lt "$wait_until" ]; do sleep 2; done

t_obs=$(date +%s)
echo "==> observing for ${OBSERVE}s: requests from the REMOVED sink reaching the bad receiver"
sleep "$OBSERVE"
bad_after=$(bad_requests_since "$t_obs")
good_after=$(good_requests_since "$t_obs")
echo "    bad receiver:  $bad_after requests in the window   (expected 0 if the removed sink was stopped)"
echo "    good receiver: $good_after requests in the window   (sanity: must be >0)"
echo "==> vector log lines about the removed sink after the reload:"
docker logs "$VECTOR_C" 2>&1 | grep -E "sink_bad|detach|abort|drain" | tail -6 | cut -c1-200 || true

if [ "$good_after" -eq 0 ]; then
  echo "INCONCLUSIVE: good sink stopped too (pipeline stalled)"; exit 2
fi
if [ "$bad_after" -gt 0 ]; then
  echo "RESULT [$LABEL]: BUG REPRODUCED - removed sink_bad still sending $(( DRAIN_TIMEOUT + GRACE ))s+ after reload (orphaned task)"
  exit 0
fi
echo "RESULT [$LABEL]: NO ORPHAN - removed sink_bad stopped within the drain timeout"
exit 1
