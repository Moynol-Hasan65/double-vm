#!/usr/bin/env bash
# deploy.sh (VM2 app) — render phish config, check VM1 is reachable, bring up
# user, lms, web, phish and nginx. Run vm1-infra/deploy.sh on VM1 first.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if ! command -v docker &>/dev/null; then
    echo "ERROR: Docker not found. Install it first: https://docs.docker.com/engine/install/"
    exit 1
fi

gen_secret() {
    if command -v openssl &>/dev/null; then
        openssl rand -hex 32
    elif command -v xxd &>/dev/null; then
        head -c 32 /dev/urandom | xxd -p -c 256
    else
        head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
    fi
}

gen_alnum() {
    # head closes the pipe as soon as it has $1 bytes, so tr gets SIGPIPE
    # (exit 141) — harmless, but pipefail+set -e would otherwise abort
    # the script on it. Scoped to a subshell so pipefail stays on globally.
    local len="$1"
    ( set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$len" )
}

gen_password() {
    gen_alnum 10
}

# Escapes \, | and & so a value is safe as a sed replacement below.
sed_escape() {
    printf '%s' "$1" | sed -e 's/[\\|&]/\\&/g'
}

set_env() {
    sed -i "s|^$1=.*|$1=$(sed_escape "$2")|" .env
}

# Reads KEY=value from vm2-shared.env without sourcing it.
shared_val() {
    grep "^$1=" vm2-shared.env | cut -d= -f2-
}

if [[ ! -f .env ]]; then
    if [[ ! -f .env.example ]]; then
        echo "ERROR: .env.example not found."
        exit 1
    fi

    if grep -q 'cyberwise-production-x\.x\.x' .env.example; then
        echo "ERROR: .env.example still has placeholder image tags (x.x.x)."
        echo "  Edit USER_IMAGE / LMS_IMAGE / WEB_IMAGE / PHISH_IMAGE in .env.example to real versions first, then rerun."
        exit 1
    fi

    if [[ ! -f vm2-shared.env ]]; then
        echo "ERROR: vm2-shared.env not found."
        echo "  Run vm1-infra/deploy.sh on VM1 first, then copy the vm2-shared.env"
        echo "  it writes into this folder ($(pwd))."
        exit 1
    fi

    for key in VM1_HOST MYSQL_USER MYSQL_PASSWORD MINIO_ACCESS_KEY MINIO_SECRET_KEY; do
        if [[ -z "$(shared_val "$key")" ]]; then
            echo "ERROR: ${key} missing or empty in vm2-shared.env."
            exit 1
        fi
    done

    echo "No .env found — running first-time setup."

    read -rp "Enter this VM's public IP or domain (what browsers use): " VM2_HOST_INPUT
    if [[ ! "$VM2_HOST_INPUT" =~ ^[A-Za-z0-9.-]+$ ]]; then
        echo "ERROR: '${VM2_HOST_INPUT}' is not a valid IP or domain."
        exit 1
    fi

    VM1_HOST_VAL=$(shared_val VM1_HOST)
    DB_USER_VAL=$(shared_val MYSQL_USER)
    DB_PASSWORD_VAL=$(shared_val MYSQL_PASSWORD)

    cp .env.example .env

    # Placeholders first — they appear inside several URLs.
    sed -i \
        -e "s|__VM1_HOST__|$(sed_escape "$VM1_HOST_VAL")|g" \
        -e "s|__VM2_HOST__|$(sed_escape "$VM2_HOST_INPUT")|g" \
        .env

    set_env MYSQL_USER "$DB_USER_VAL"
    set_env MYSQL_PASSWORD "$DB_PASSWORD_VAL"
    set_env DATABASE_USER "$DB_USER_VAL"
    set_env DATABASE_PASSWORD "$DB_PASSWORD_VAL"
    set_env MINIO_ACCESS_KEY "$(shared_val MINIO_ACCESS_KEY)"
    set_env MINIO_SECRET_KEY "$(shared_val MINIO_SECRET_KEY)"

    echo "Generating secrets..."
    set_env JWT_SECRET "$(gen_secret)"
    set_env LICENSE_SECRET "$(gen_secret)"
    set_env PHISH_WEBHOOK_SECRET "$(gen_secret)"
    SUPER_ADMIN_PASSWORD_VAL=$(gen_password)
    set_env SUPER_ADMIN_PASSWORD "$SUPER_ADMIN_PASSWORD_VAL"

    SUPER_ADMIN_EMAIL_VAL=$(grep '^SUPER_ADMIN_EMAIL=' .env | cut -d= -f2-)

    echo "✓ .env created — VM1 ${VM1_HOST_VAL}, VM2 ${VM2_HOST_INPUT}, 3 secrets + super admin password generated."
    echo "  Super Admin login:  ${SUPER_ADMIN_EMAIL_VAL} / ${SUPER_ADMIN_PASSWORD_VAL}"
    echo "  Write it down — it isn't shown again."
    echo "  vm2-shared.env is no longer needed here; delete it: rm vm2-shared.env"
    echo "  Review the remaining placeholders in .env if needed: SMTP (MAIL_*) creds."
fi

if ! command -v envsubst &>/dev/null; then
    echo "ERROR: envsubst not found (part of gettext)."
    echo "  Debian/Ubuntu: sudo apt-get install -y gettext-base"
    exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

# Hosts aren't stored in .env on their own — read them back from the URLs they
# were substituted into, so editing those URLs is the single source of truth.
host_of() {
    printf '%s' "$1" | sed -E 's|^[a-z]+://([^:/]+).*|\1|'
}
export VM1_HOST="$(host_of "$MINIO_URL")"
VM2_HOST="$(host_of "$MAIL_LOGIN_URL")"

echo "Rendering phish/config.json..."
# Explicit list: only these get substituted, any other $... in the template stays literal.
envsubst '${MYSQL_USER} ${MYSQL_PASSWORD} ${VM1_HOST} ${SUPER_ADMIN_EMAIL} ${PHISH_WEBHOOK_SECRET}' \
    < phish/config.json.tpl > phish/config.json
echo "✓ phish/config.json rendered"

echo "Checking VM1 (${VM1_HOST}) is reachable..."
for port in 3306 9000; do
    if ! timeout 5 bash -c "</dev/tcp/${VM1_HOST}/${port}" 2>/dev/null; then
        echo "ERROR: cannot reach ${VM1_HOST}:${port} from this VM."
        echo "  Is vm1-infra deployed, and does VM1's firewall allow this VM's IP on ${port}?"
        exit 1
    fi
done
echo "✓ MySQL and MinIO reachable"

echo ""
echo "Starting all services..."
docker compose up -d

echo ""
echo "=== Deployment started ==="
echo "  Web App:        http://${VM2_HOST}:3000/auth/login"
echo ""
echo "Check status:  docker compose ps"
echo "Check logs:    docker compose logs -f <service>   (nginx, user, lms, web, phish)"
