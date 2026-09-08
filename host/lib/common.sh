# common.sh - shared functions for the incus-backup-* commands.
# Installed as /usr/lib/incus-backup/common.sh. Sourced by bash 4.4 or later.
# Requires: jq, flock (util-linux), incus or lxc, kopia.

ib_die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
ib_warn() { printf 'WARNING: %s\n' "$*" >&2; }

# Load /etc/incus-backup.conf (or $INCUS_BACKUP_CONFIG) and apply defaults.
ib_load_config() {
    IB_CONFIG_FILE="${INCUS_BACKUP_CONFIG:-/etc/incus-backup.conf}"
    [[ -r "${IB_CONFIG_FILE}" ]] || ib_die "cannot read ${IB_CONFIG_FILE}"
    # shellcheck disable=SC1090
    source "${IB_CONFIG_FILE}"

    : "${KOPIA_SERVER_URL:?KOPIA_SERVER_URL is not set in ${IB_CONFIG_FILE}}"
    : "${KOPIA_SERVER_FINGERPRINT:?KOPIA_SERVER_FINGERPRINT is not set in ${IB_CONFIG_FILE}}"
    : "${KOPIA_ADMIN_USERNAME:=admin}"
    : "${KOPIA_ADMIN_HOSTNAME:=$(hostname -f 2>/dev/null || hostname)}"
    : "${KOPIA_ADMIN_PASSWORD_FILE:=/etc/incus-backup/admin.password}"
    : "${KOPIA_ADMIN_CONFIG:=/etc/incus-backup/admin.repository.config}"
    : "${KOPIA_BIN:=/usr/bin/kopia}"
    : "${CREDENTIAL_DIR:=/etc/incus-backup/credentials}"
    : "${POLICY_DIR:=/etc/incus-backup/policies.d}"
    : "${STATE_DIR:=/var/lib/incus-backup}"
    : "${LOCK_DIR:=/run/incus-backup}"
    : "${LOG_DIR:=/var/log/incus-backup}"
    : "${REMOTE_RUNTIME_DIR:=/run/incus-backup}"
    : "${REMOTE_CACHE_DIR:=/var/cache/kopia}"
    : "${DEFAULT_INTERVAL:=24h}"
    : "${MAX_JOBS:=1}"
    : "${MAX_NORMALIZED_LOAD:=1.25}"
    : "${DEFAULT_METADATA_CACHE_MB:=64}"
    : "${DEFAULT_METADATA_CACHE_LIMIT_MB:=128}"
    : "${DEFAULT_CONTENT_CACHE_MB:=32}"
    : "${DEFAULT_CONTENT_CACHE_LIMIT_MB:=64}"
    : "${DEFAULT_ROOT_POLICY:=root-server}"
    : "${DEFAULT_DATA_POLICY:=data}"
    : "${PROVISION_AUTH_TIMEOUT:=120}"

    [[ "${KOPIA_SERVER_FINGERPRINT}" =~ ^[0-9a-fA-F]{64}$ ]] \
        || ib_die "KOPIA_SERVER_FINGERPRINT in ${IB_CONFIG_FILE} must be a 64-character hex SHA-256 fingerprint"
    [[ -x "${KOPIA_BIN}" ]] || ib_die "${KOPIA_BIN} is not executable"

    # Host-side kopia invocations log here instead of /root/.cache/kopia.
    export KOPIA_LOG_DIR="${LOG_DIR}/kopia"
    export KOPIA_CHECK_FOR_UPDATES=false
}

# Set CLI to "incus" or "lxc". Override with INCUS_BACKUP_CLI.
ib_detect_cli() {
    if [[ -n "${INCUS_BACKUP_CLI:-}" ]]; then CLI="${INCUS_BACKUP_CLI}"
    elif command -v incus >/dev/null 2>&1; then CLI=incus
    elif command -v lxc >/dev/null 2>&1; then CLI=lxc
    else ib_die "neither incus nor lxc is installed"
    fi
}

ib_is_true() { case "${1,,}" in 1|yes|true|on) return 0 ;; *) return 1 ;; esac; }

# Print the instance object as JSON. The CLI unwraps the API envelope, so the
# object has .expanded_config, .expanded_devices, .status and .type at top level.
ib_instance_json() { "${CLI}" query "/1.0/instances/$1"; }

# ib_cfg JSON KEY [DEFAULT] - read one key from expanded_config (profiles included).
ib_cfg() {
    local v
    v="$(jq -r --arg k "$2" '(.expanded_config // .config // {})[$k] // empty' <<<"$1")"
    printf '%s' "${v:-${3:-}}"
}

# ib_volume_rows JSON - print "device<TAB>path<TAB>pool<TAB>source" for every
# attached custom storage volume. Root disks and host bind mounts are excluded.
ib_volume_rows() {
    jq -r '
      (.expanded_devices // .devices // {})
      | to_entries[]
      | select(.value.type == "disk")
      | select((.value.path // "") != "" and .value.path != "/")
      | select((.value.pool // "") != "")
      | select((.value.source // "") != "")
      | select((.value.source | startswith("/")) | not)
      | [.key, .value.path, .value.pool, .value.source]
      | @tsv
    ' <<<"$1" | sort -t$'\t' -k2,2
}

# ib_sources JSON - print "kind<TAB>path<TAB>class<TAB>device" for each source
# selected by user.backup.root, user.backup.volumes and user.backup.policy.*.
ib_sources() {
    local json="$1" root volumes root_policy data_policy dev path _pool _source d
    local -A wanted=()
    root="$(ib_cfg "${json}" user.backup.root true)"
    volumes="$(ib_cfg "${json}" user.backup.volumes auto)"
    root_policy="$(ib_cfg "${json}" user.backup.policy.root "${DEFAULT_ROOT_POLICY}")"
    data_policy="$(ib_cfg "${json}" user.backup.policy.data "${DEFAULT_DATA_POLICY}")"

    if ib_is_true "${root}"; then
        printf 'root\t/\t%s\t-\n' "${root_policy}"
    fi
    [[ "${volumes}" == none ]] && return 0

    if [[ "${volumes}" != auto ]]; then
        IFS=',' read -ra req <<<"${volumes}"
        for d in "${req[@]}"; do
            d="${d//[[:space:]]/}"
            [[ -n "${d}" ]] && wanted["${d}"]=1
        done
    fi

    while IFS=$'\t' read -r dev path _pool _source; do
        [[ -n "${dev}" ]] || continue
        if [[ "${volumes}" != auto ]]; then
            [[ -n "${wanted[${dev}]:-}" ]] || continue
            unset "wanted[${dev}]"
        fi
        printf 'volume\t%s\t%s\t%s\n' "${path}" "${data_policy}" "${dev}"
    done < <(ib_volume_rows "${json}")

    for d in "${!wanted[@]}"; do
        ib_warn "user.backup.volumes names device '${d}' but no attached custom volume has that name"
    done
}

# ib_identity JSON - print the lowercase stable FQDN from user.backup.hostname.
ib_identity() {
    local id
    id="$(ib_cfg "$1" user.backup.hostname)"
    [[ -n "${id}" ]] || return 1
    id="${id,,}"
    [[ "${id}" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || ib_die "user.backup.hostname '${id}' is not a valid hostname"
    printf '%s' "${id}"
}

# ib_interval_seconds 6h -> 21600. Accepts s, m, h, d, w suffixes.
ib_interval_seconds() {
    local n unit
    [[ "$1" =~ ^([0-9]+)([smhdw]?)$ ]] || return 1
    n="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]:-s}"
    case "${unit}" in
        s) echo "${n}" ;;
        m) echo $((n * 60)) ;;
        h) echo $((n * 3600)) ;;
        d) echo $((n * 86400)) ;;
        w) echo $((n * 604800)) ;;
    esac
}

# 1-minute load average divided by CPU count.
ib_normalized_load() { awk -v n="$(nproc)" '{ printf "%.2f", $1 / n }' /proc/loadavg; }

# ib_shell_quote STRING - single-quote for POSIX sh.
ib_shell_quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# Read the trusted-host admin password into KOPIA_ADMIN_PASSWORD (file, else prompt).
ib_read_admin_password() {
    if [[ -r "${KOPIA_ADMIN_PASSWORD_FILE}" ]]; then
        KOPIA_ADMIN_PASSWORD="$(<"${KOPIA_ADMIN_PASSWORD_FILE}")"
    else
        read -rsp "Kopia password for ${KOPIA_ADMIN_USERNAME}@${KOPIA_ADMIN_HOSTNAME}: " KOPIA_ADMIN_PASSWORD
        echo >&2
    fi
    [[ -n "${KOPIA_ADMIN_PASSWORD}" ]] || ib_die "empty admin password"
}

# Connect the host-side admin identity. Credentials are not persisted; callers
# must keep KOPIA_PASSWORD exported for later kopia invocations.
ib_admin_connect() {
    export KOPIA_PASSWORD="${KOPIA_ADMIN_PASSWORD}"
    install -d -m 0700 "$(dirname "${KOPIA_ADMIN_CONFIG}")"
    rm -f "${KOPIA_ADMIN_CONFIG}" "${KOPIA_ADMIN_CONFIG}.kopia-password"
    "${KOPIA_BIN}" --config-file="${KOPIA_ADMIN_CONFIG}" --no-persist-credentials \
        repository connect server \
        --url="${KOPIA_SERVER_URL}" \
        --server-cert-fingerprint="${KOPIA_SERVER_FINGERPRINT}" \
        --override-username="${KOPIA_ADMIN_USERNAME}" \
        --override-hostname="${KOPIA_ADMIN_HOSTNAME}" \
        --no-check-for-updates >/dev/null
}

# kopia_admin ARGS... - run kopia with the admin config (after ib_admin_connect).
kopia_admin() { "${KOPIA_BIN}" --config-file="${KOPIA_ADMIN_CONFIG}" "$@"; }

# ib_load_too_high - true when load gating is enabled and the normalized load
# is at or above MAX_NORMALIZED_LOAD. Sets IB_LOAD for logging.
ib_load_too_high() {
    IB_LOAD=""
    awk -v m="${MAX_NORMALIZED_LOAD}" 'BEGIN { exit !(m > 0) }' || return 1
    [[ -r /proc/loadavg ]] || return 1
    IB_LOAD="$(ib_normalized_load)"
    awk -v l="${IB_LOAD}" -v m="${MAX_NORMALIZED_LOAD}" 'BEGIN { exit !(l >= m) }'
}
