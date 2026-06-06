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
#     1. Snapshot the IDs of all currently-running containers (the "old" set).
#     2. Scale the service up to replicas+1 → Docker Compose starts one new
#        container using the freshly-built image while the old ones keep serving.
#     3. Wait for the new container to become healthy (identified as whichever
#        running container is NOT in the snapshot taken in step 1).
#     4. Explicitly stop and remove exactly one old container (by its saved ID),
#        then tell Compose to reconcile back to the target replica count.
#        Because we target a specific container ID we are guaranteed to remove an
#        old instance, never the newly-started one.
#     5. Repeat until all replicas have been replaced.
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
#   Waits until at least <expected_count> containers for <service> are healthy.
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

# get_container_ids <service>
#   Prints the IDs of all currently-running containers for <service>, one per line.
get_container_ids() {
    docker compose -f "$COMPOSE_FILE" ps -q "$1" 2>/dev/null || true
}

# wait_new_healthy <service> <old_ids_var>
#   Waits until a container that is NOT in <old_ids_var> (a newline-separated
#   list of old IDs) becomes healthy.  Returns the new container's ID via stdout.
wait_new_healthy() {
    local service="$1"
    local old_ids="$2"
    local elapsed=0

    log "Waiting for new ${service} container to become healthy …"

    while true; do
        local cid
        while IFS= read -r cid; do
            [ -z "$cid" ] && continue
            # Skip containers that existed before the scale-up.
            if echo "$old_ids" | grep -qF "$cid"; then
                continue
            fi
            local health
            health=$(docker inspect --format '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo "none")
            if [ "$health" = "healthy" ]; then
                log "New container ${cid} is healthy ✓"
                echo "$cid"
                return 0
            fi
        done < <(get_container_ids "$service")

        if [ "$elapsed" -ge "$HEALTH_TIMEOUT" ]; then
            die "Timed out waiting for new ${service} container to become healthy (${elapsed}s)."
        fi

        sleep "$HEALTH_INTERVAL"
        elapsed=$(( elapsed + HEALTH_INTERVAL ))
        log "${service}: new container not yet healthy – waiting … (${elapsed}s / ${HEALTH_TIMEOUT}s)"
    done
}

# rolling_update <service> <replicas>
#   Replaces every running container for <service> one at a time,
#   always removing a known-old container by ID — never the new one.
rolling_update() {
    local service="$1"
    local replicas="$2"

    log "──────────────────────────────────────────────"
    log "Rolling update: ${service}  (${replicas} replicas)"
    log "──────────────────────────────────────────────"

    for (( i=1; i<=replicas; i++ )); do
        local scaled=$(( replicas + 1 ))
        log "[${service}] Step ${i}/${replicas}: scaling to ${scaled} containers …"

        # Snapshot the IDs of containers that are running RIGHT NOW (old set).
        local old_ids
        old_ids=$(get_container_ids "$service")
        if [ -z "$old_ids" ]; then
            die "No running containers found for ${service} before scale-up."
        fi
        log "[${service}] Old container IDs: $(echo "$old_ids" | tr '\n' ' ')"

        # Pick the first old container to be removed once the new one is healthy.
        local victim_id
        victim_id=$(echo "$old_ids" | head -n1)

        # Start one additional container with the new image.
        docker compose -f "$COMPOSE_FILE" up -d \
            --no-deps \
            --scale "${service}=${scaled}" \
            --no-recreate \
            "$service"

        # Wait for the newly-started container (not in old_ids) to be healthy.
        wait_new_healthy "$service" "$old_ids" > /dev/null

        log "[${service}] Removing old container ${victim_id} …"

        # Explicitly stop and remove the chosen old container.
        docker stop "$victim_id" > /dev/null
        docker rm   "$victim_id" > /dev/null

        # Tell Compose to reconcile its state back to the target replica count
        # (it will not start another container because replicas == running count).
        docker compose -f "$COMPOSE_FILE" up -d \
            --no-deps \
            --scale "${service}=${replicas}" \
            --no-recreate \
            "$service"

        # Allow a moment for the stopped container to fully exit.
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
