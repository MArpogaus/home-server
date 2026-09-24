# shellcheck shell=bash
# Sourced by deploy.sh and functional_test.sh after they set SCRIPT_DIR.

SECRETS_DIR="${SECRETS_DIR:-${SCRIPT_DIR}/../home-server-secrets}"
SSH_KEY_FILE="${SSH_KEY_FILE:-${SCRIPT_DIR}/test/coreos_key}"
TARGET_HOST="${TARGET_HOST:-127.0.0.1}"
TARGET_NAME="${TARGET_NAME:-test}"
TARGET_PORT="${TARGET_PORT:-2222}"

# Ansible's own interpreter: it is the one with PyYAML, passlib and bcrypt.
ansible_python() {
    dirname "$(readlink -f "$(command -v ansible)")"
}

export ANSIBLE_VAULT_PASSWORD_FILE="${ANSIBLE_VAULT_PASSWORD_FILE:-${HOME}/.config/home-server/vault-password}"

require_vault_password() {
    [[ -s "${ANSIBLE_VAULT_PASSWORD_FILE}" ]] || {
        echo "ERROR: no vault password in ${ANSIBLE_VAULT_PASSWORD_FILE}." >&2
        echo "       README.md, \"Vault\", has the setup." >&2
        exit 1
    }
}

# The host file wins over the shared one, the same order deploy.sh hands them
# to ansible-playbook.
read_var() {
    "$(ansible_python)/python" - "$1" \
        "${SECRETS_DIR}/secrets/vars.yml" "${SECRETS_DIR}/secrets/vars.${TARGET_NAME}.yml" <<'PY'
import os, sys, yaml
from ansible.parsing.vault import VaultLib, VaultSecret
secret = VaultSecret(open(os.environ["ANSIBLE_VAULT_PASSWORD_FILE"], "rb").read().strip())
vault = VaultLib([("default", secret)])
value = ""
for path in sys.argv[2:]:
    if os.path.exists(path):
        data = open(path, "rb").read()
        if vault.is_encrypted(data):
            data = vault.decrypt(data)
        value = (yaml.safe_load(data) or {}).get(sys.argv[1], value)
print(value if value is not None else "")
PY
}

# Sets HOST_KEY_OPTS and SSH_OPTS (host key policy plus identity).
ssh_opts() {
    case "${TEST_VM:-}:${TARGET_HOST}" in
    1:* | *:127.* | *:169.254.* | *:localhost)
        [[ "${TARGET_NAME}" == test ]] || {
            echo "ERROR: ${TARGET_HOST} is a test VM address, but TARGET_NAME is ${TARGET_NAME}." >&2
            echo "       Only the test VM skips the host key check." >&2
            exit 1
        }
        HOST_KEY_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
        ;;
    *)
        [[ -s "${SECRETS_DIR}/ssh/known_hosts" ]] || {
            echo "ERROR: ${SECRETS_DIR}/ssh/known_hosts is missing or empty." >&2
            echo "       Record the host key once, from a session you trust:" >&2
            echo "       ssh-keyscan -H -p ${TARGET_PORT} ${TARGET_HOST} 2>/dev/null >> ${SECRETS_DIR}/ssh/known_hosts" >&2
            exit 1
        }
        HOST_KEY_OPTS=(-o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${SECRETS_DIR}/ssh/known_hosts")
        ;;
    esac
    SSH_OPTS=("${HOST_KEY_OPTS[@]}")
    if [[ "${SSH_AUTH_KEY:-file}" == "file" ]]; then
        [[ -f "${SSH_KEY_FILE}" ]] || { echo "ERROR: ${SSH_KEY_FILE} not found" >&2; exit 1; }
        SSH_OPTS+=(-i "${SSH_KEY_FILE}" -o IdentitiesOnly=yes)
    else
        ssh-add -l >/dev/null 2>&1 || { echo "ERROR: no SSH agent with a key. Plug in the YubiKey, or set SSH_AUTH_KEY=file" >&2; exit 1; }
    fi
}
