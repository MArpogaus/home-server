#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

echo "=== Deploying to ${TARGET_HOST} (${TARGET_NAME}) ==="

validate_secrets() {
    [[ -f "${SECRETS_DIR}/secrets/vars.yml" ]] || { echo "ERROR: secrets/vars.yml not found"; exit 1; }
    [[ -f "${SECRETS_DIR}/secrets/vars.${TARGET_NAME}.yml" ]] || {
        echo "ERROR: no secrets/vars.${TARGET_NAME}.yml in ${SECRETS_DIR}. Known names:"
        # shellcheck disable=SC2012
        ls "${SECRETS_DIR}"/secrets/vars.*.yml 2>/dev/null | sed -E 's|.*/vars\.(.*)\.yml|    \1|'
        exit 1
    }
    require_vault_password
    chmod -R go-rwx "${SECRETS_DIR}"
    echo "✓ Secrets validated"
}

validate_python_deps() {
    "$(ansible_python)/python" -c 'import passlib, bcrypt' 2>/dev/null \
        || { echo "ERROR: Ansible's Python lacks passlib and bcrypt. Run: uv tool install --reinstall ansible --with passlib --with bcrypt"; exit 1; }
}

deploy_ansible() {
    printf -v ANSIBLE_SSH_COMMON_ARGS '%q ' "${SSH_OPTS[@]}"
    export ANSIBLE_SSH_COMMON_ARGS
    cd "${SCRIPT_DIR}"
    # Last command: `if deploy_ansible` disables errexit inside, so the
    # playbook's status is the function's.
    ansible-playbook -i "${SCRIPT_DIR}/inventory/hosts.ini" site.yml \
        --extra-vars "@${SECRETS_DIR}/secrets/vars.yml" \
        --extra-vars "@${SECRETS_DIR}/secrets/vars.${TARGET_NAME}.yml" \
        --extra-vars "ansible_host=${TARGET_HOST} ansible_port=${TARGET_PORT}" \
        --extra-vars "secrets_dir=${SECRETS_DIR}"
}

notify() {
    local host token
    host=$(read_var ntfy_hostname)
    token=$(read_var monitoring_service_ntfy_token)
    [[ -n "$host" && -n "$token" ]] || return 0
    curl -s -o /dev/null --max-time 10 -K <(printf 'header = "Authorization: Bearer %s"\n' "${token}") \
        -H "Title: deploy ${TARGET_HOST}" -H "Tags: ${2}" -d "$1" "https://${host}/alerts" || true
}

validate_secrets
ssh_opts
validate_python_deps
ansible-galaxy collection install -r "${SCRIPT_DIR}/requirements.yml" >/dev/null
if deploy_ansible; then
    notify "Deploy to ${TARGET_HOST} succeeded" rocket
    echo "✓ Deploy complete"
else
    notify "Deploy to ${TARGET_HOST} FAILED" x
    exit 1
fi
