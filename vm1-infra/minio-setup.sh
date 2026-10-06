#!/usr/bin/env bash
# minio-setup.sh — wait for MinIO healthy, provision access credentials if unset.
# Called by deploy.sh after `docker compose up -d`. Also runnable standalone.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

set -a
# shellcheck disable=SC1091
source .env
set +a

echo "Waiting for MinIO to become healthy..."
tries=0
until [[ "$(docker inspect -f '{{.State.Health.Status}}' cyberwise-minio 2>/dev/null)" == "healthy" ]]; do
    tries=$((tries + 1))
    if (( tries > 60 )); then
        echo "ERROR: MinIO did not become healthy in time."
        exit 1
    fi
    sleep 2
done

if [[ "${MINIO_ACCESS_KEY}" == "your_access_key" ]]; then
    echo "Provisioning MinIO access credentials..."
    MC_IMAGE="quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z"
    MC_NET=$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' cyberwise-minio)

    MC_OUTPUT=""
    if docker image inspect "${MC_IMAGE}" &>/dev/null || { echo "Pulling ${MC_IMAGE} (one-time)..."; timeout 120 docker pull "${MC_IMAGE}"; }; then
        MC_OUTPUT=$(docker run --rm --network "${MC_NET}" --entrypoint sh "${MC_IMAGE}" -c "
            mc alias set local http://cyberwise-minio:9000 '${MINIO_ROOT_USER}' '${MINIO_ROOT_PASSWORD}' >/dev/null &&
            mc admin user svcacct add local '${MINIO_ROOT_USER}'
        " 2>&1) || true
    else
        echo "⚠ Could not pull ${MC_IMAGE} (no registry access?) — skipping to fallback."
    fi

    if [[ -n "$MC_OUTPUT" ]] && echo "$MC_OUTPUT" | grep -q "Access Key"; then
        MINIO_ACCESS_KEY_VAL=$(echo "$MC_OUTPUT" | grep "Access Key" | awk '{print $3}')
        MINIO_SECRET_KEY_VAL=$(echo "$MC_OUTPUT" | grep "Secret Key" | awk '{print $3}')
        sed -i \
            -e "s|^MINIO_ACCESS_KEY=.*|MINIO_ACCESS_KEY=${MINIO_ACCESS_KEY_VAL}|" \
            -e "s|^MINIO_SECRET_KEY=.*|MINIO_SECRET_KEY=${MINIO_SECRET_KEY_VAL}|" \
            .env
        echo "✓ MinIO access credentials generated"
    else
        echo "⚠ Could not create a MinIO service account — falling back to root credentials."
        [[ -n "$MC_OUTPUT" ]] && echo "$MC_OUTPUT"
        sed -i \
            -e "s|^MINIO_ACCESS_KEY=.*|MINIO_ACCESS_KEY=${MINIO_ROOT_USER}|" \
            -e "s|^MINIO_SECRET_KEY=.*|MINIO_SECRET_KEY=${MINIO_ROOT_PASSWORD}|" \
            .env
    fi
fi
