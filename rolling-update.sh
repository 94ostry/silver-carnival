#!/usr/bin/env bash
# rolling-update.sh – Zero-downtime rolling update for silver-carnival services.
#
# Usage:
#   ./rolling-update.sh [NEW_VERSION]
#
# NEW_VERSION (optional) – Docker image tag to build and deploy, e.g. "1.2.3".
#   Defaults to "latest" when omitted.
#
# Strategy (core-service, processing-service, task-service):
#   Each service runs with 2 replicas.  For every replica we:
#     1. Scale the service up to replicas+1  → Docker Compose starts one new
#        container using the freshly-built image while the old ones keep serving.
#     2. Wait for the new container to become healthy.
#     3. Scale back down to the original replica count → Docker Compose removes
#        the oldest (now-outdated) container.
#     4. Repeat until all replicas have been replaced.
#   At no point does the number of healthy replicas drop below 1.
#
# import-service has a single replica and is not required to be kept alive
# during the update, so it is restarted in-place after the critical services.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

COMPOSE_FILE="$(dirname "$0")/docker-compose.yml"
NEW_VERSION="${1:-latest}"

# Services that must stay available (rolling update, replicas=2 each).
ROLLING_SERVICES=("core-service" "processing-service" "task-service")
ROLLING_REPLICAS=2          # matches docker-compose.yml deploy.replicas

# Health-check settings (seconds).
HEALTH_TIMEOUT=120          # maximum wait per container
HEALTH_INTERVAL=5           # poll interval
CONTAINER_SHUTDOWN_GRACE=2  # seconds to allow a stopped container to exit cleanly

# Colour helpers (no-op when not a terminal).
if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; NC=''
fi

log()  { echo -e "${GREEN}[rolling-update]${NC} $*"; }
warn() { echo -e "${YELLOW}[rolling-update] WARNING:${NC} $*"; }
die()  { echo -e "${RED}[rolling-update] ERROR:${NC} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# wait_healthy <service> <expected_count>
#   Waits until exactly <expected_count> containers for <service> are healthy.
wait_healthy() {
    local service="$1"
    local expected="$2"
    local elapsed=0

    log "Waiting for ${expected} healthy container(s) of ${service} …"

    while true; do
        local healthy
        healthy=$(docker compose -f "$COMPOSE_FILE" ps --format json "$service" 2>/dev/null \
                  | grep -c '"Health":"healthy"' || true)

        if [ "$healthy" -ge "$expected" ]; then
            log "${service}: ${healthy}/${expected} healthy ✓"
            return 0
        fi

        if [ "$elapsed" -ge "$HEALTH_TIMEOUT" ]; then
            die "Timed out waiting for ${service} to become healthy (${healthy}/${expected} healthy after ${elapsed}s)."
        fi

        sleep "$HEALTH_INTERVAL"
        elapsed=$(( elapsed + HEALTH_INTERVAL ))
        log "${service}: ${healthy}/${expected} healthy – waiting … (${elapsed}s / ${HEALTH_TIMEOUT}s)"
    done
}

# rolling_update <service> <replicas>
#   Replaces every running container for <service> one at a time.
rolling_update() {
    local service="$1"
    local replicas="$2"

    log "──────────────────────────────────────────────"
    log "Rolling update: ${service}  (${replicas} replicas)"
    log "──────────────────────────────────────────────"

    for (( i=1; i<=replicas; i++ )); do
        local scaled=$(( replicas + 1 ))
        log "[${service}] Step ${i}/${replicas}: scaling to ${scaled} containers …"

        # Start one additional container with the new image.
        docker compose -f "$COMPOSE_FILE" up -d \
            --no-deps \
            --scale "${service}=${scaled}" \
            --no-recreate \
            "$service"

        # Wait for the newly-added container to be healthy before removing old one.
        wait_healthy "$service" "$scaled"

        log "[${service}] New container is healthy. Scaling back to ${replicas} …"

        # Scale down – Docker Compose removes the oldest container.
        docker compose -f "$COMPOSE_FILE" up -d \
            --no-deps \
            --scale "${service}=${replicas}" \
            --no-recreate \
            "$service"

        # Allow a moment for the removed container to exit cleanly.
        sleep "$CONTAINER_SHUTDOWN_GRACE"
    done

    # Final health confirmation.
    wait_healthy "$service" "$replicas"
    log "${service}: rolling update complete ✓"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

cd "$(dirname "$0")"

log "Starting rolling update → version: ${NEW_VERSION}"
log "Docker Compose file: ${COMPOSE_FILE}"
echo ""

# 1. Build updated images.
log "Building Docker images (version=${NEW_VERSION}) …"
mvn -q -DskipTests clean package
docker compose -f "$COMPOSE_FILE" build \
    --build-arg VERSION="$NEW_VERSION" \
    "${ROLLING_SERVICES[@]}" import-service

# Tag images with the requested version (in addition to :latest used in compose).
if [ "$NEW_VERSION" != "latest" ]; then
    for svc in "${ROLLING_SERVICES[@]}" import-service; do
        docker tag "silver-carnival/${svc}:latest" "silver-carnival/${svc}:${NEW_VERSION}"
        log "Tagged silver-carnival/${svc}:latest → silver-carnival/${svc}:${NEW_VERSION}"
    done
fi

echo ""

# 2. Rolling update for critical services (must stay available).
for svc in "${ROLLING_SERVICES[@]}"; do
    rolling_update "$svc" "$ROLLING_REPLICAS"
    echo ""
done

# 3. Restart import-service (single instance, no zero-downtime requirement).
log "Restarting import-service …"
docker compose -f "$COMPOSE_FILE" up -d --no-deps --force-recreate import-service
wait_healthy "import-service" 1
log "import-service restarted ✓"
echo ""

# 4. Summary.
log "All services updated to version '${NEW_VERSION}'."
docker compose -f "$COMPOSE_FILE" ps
