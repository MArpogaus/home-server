#!/bin/bash
set -euo pipefail

# SecureBlue Deployment Script
# Usage: ./deploy.sh [deploy|validate|start]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="${SCRIPT_DIR}/../ansible-base"

echo "=== SecureBlue Deployment ==="
echo "Working directory: ${SCRIPT_DIR}"

validate_secrets() {
    echo "Validating secrets..."
    [[ -f "${SCRIPT_DIR}/secrets/vars.yml" ]] || { echo "ERROR: secrets/vars.yml not found"; exit 1; }
    [[ -f "${SCRIPT_DIR}/inventory/hosts.ini" ]] || { echo "ERROR: inventory/hosts.ini not found"; exit 1; }
    [[ -f "${SCRIPT_DIR}/ssh/coreos_key" ]] || { echo "ERROR: ssh/coreos_key not found"; exit 1; }
    echo "✓ Secrets validated"
}

deploy_ansible() {
    echo "Running Ansible playbook..."
    cd "${ANSIBLE_DIR}"
    ansible-playbook -i "${SCRIPT_DIR}/inventory/hosts.ini" site.yml \
        --extra-vars "@${SCRIPT_DIR}/secrets/vars.yml" \
        --extra-vars "ansible_ssh_private_key_file=${SCRIPT_DIR}/ssh/coreos_key" \
        -v
    echo "✓ Ansible deployment completed"
}

validate_deployment() {
    local ssh_opts="-tt -p 2222 -i ${SCRIPT_DIR}/ssh/coreos_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    local run0="systemd-run --service-type=exec --uid=0 --pty --working-directory=/tmp --wait --collect --"

    echo "--- Btrfs subvolumes ---"
    ssh ${ssh_opts} core@host.containers.internal "${run0} btrfs subvolume list /var/services" 2>&1 | grep -E "^ID|WARNING" || true

    echo "--- Podman containers ---"
    for user in nextcloud proxy monitoring; do
        echo "  ${user}:"
        uid=$(ssh ${ssh_opts} core@host.containers.internal "${run0} id -u ${user}" 2>/dev/null | tail -1)
        if [[ -n "${uid}" ]]; then
            local run_as="systemd-run --service-type=exec --uid=${uid} --working-directory=/tmp --wait --collect --"
            ssh ${ssh_opts} core@host.containers.internal "${run_as} podman ps -a" 2>&1 | grep -v "^$" || true
        fi
    done

    echo "--- Snapshot timers ---"
    ssh ${ssh_opts} core@host.containers.internal "${run0} systemctl list-timers --all" 2>&1 | grep btrfs-snapshot || true

    echo "✓ Validation complete"
}

main() {
    validate_secrets
    case "${1:-deploy}" in
        deploy)
            deploy_ansible
            echo "✓ Deploy complete"
            ;;
        validate)
            validate_deployment
            ;;
        *)
            echo "Usage: $0 [deploy|validate]"
            exit 1
            ;;
    esac
}
main "$@"
