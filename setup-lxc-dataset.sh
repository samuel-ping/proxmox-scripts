#!/usr/bin/env bash
# setup-lxc-dataset.sh
# Automates ZFS dataset creation and LXC container configuration for Docker apps on Proxmox.
# Run as root on the Proxmox host.
#
# Usage (direct):
#   ./setup-lxc-dataset.sh -c CTID -n DATASET -a APP [OPTIONS]
#
# Usage (curl):
#   bash <(curl -fsSL https://raw.githubusercontent.com/samuel-ping/proxmox-scripts/main/setup-lxc-dataset.sh)
#
# To pass flags via curl:
#   bash <(curl -fsSL <url>) -c 101 -n docs -a paperless --docker

set -euo pipefail

### Defaults
ZFS_POOL="motherpool"
LXC_UID=1000
LXC_GID=1000
ADD_DOCKER=false
BACKUP=1
DIRS=()
MOUNTPOINT=""
DRY_RUN=false

### Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
step()  { echo -e "\n${BOLD}${BLUE}[STEP]${NC}${BOLD} $*${NC}"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

run() {
    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY]${NC}   $*"
    else
        "$@"
    fi
}

run_pct() {
    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY]${NC}   pct exec ${CTID} -- $*"
    else
        pct exec "${CTID}" -- "$@"
    fi
}

# confirm: print a y/N prompt and return 0 only if the user answers yes.
# In dry-run mode, always proceeds (prints [DRY] instead).
# Reads from /dev/tty so the prompt works when stdin is not a terminal
# (e.g. when the script is run via bash -c "$(curl ...)").
confirm() {
    local msg="$1"
    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY]${NC}   (would confirm: ${msg})"
        return 0
    fi
    local response
    echo -e -n "  ${YELLOW}?${NC} ${msg} [y/N]: " >/dev/tty
    read -r response </dev/tty
    [[ "${response,,}" =~ ^y(es)?$ ]]
}

# prompt_required: prompt for a value, loop until non-empty
prompt_required() {
    local msg="$1"
    local val=""
    while [[ -z "$val" ]]; do
        echo -n "  ${msg}: " >/dev/tty
        read -r val </dev/tty
    done
    echo "$val"
}

# prompt_default: prompt for a value, fall back to default on empty input
prompt_default() {
    local msg="$1" default="$2"
    local val
    echo -n "  ${msg} [${default}]: " >/dev/tty
    read -r val </dev/tty
    echo "${val:-$default}"
}

# prompt_bool: y/N prompt, echoes "true" or "false"
prompt_bool() {
    local msg="$1" default="${2:-false}"
    local hint="y/N"
    [[ "$default" == "true" ]] && hint="Y/n"
    local val
    echo -n "  ${msg} [${hint}]: " >/dev/tty
    read -r val </dev/tty
    if [[ -z "$val" ]]; then
        echo "$default"
    elif [[ "${val,,}" =~ ^y(es)?$ ]]; then
        echo "true"
    else
        echo "false"
    fi
}

usage() {
    cat <<EOF
Usage: $(basename "$0") -c CTID -n DATASET -a APP [OPTIONS]

Automates ZFS dataset creation and LXC container configuration for a Docker app.
Must be run as root on the Proxmox host. If required args are omitted, the script
will prompt for them interactively.

Required:
  -c, --ctid CTID        LXC container ID
  -n, --dataset NAME     Dataset name under pool (e.g. "docs" creates POOL/docs;
                         "sping/docs" creates the nested POOL/sping/docs)
  -a, --app APP          App name — used to create APP-user / APP-users in the LXC

Options:
  -p, --pool POOL        ZFS pool name (default: ${ZFS_POOL})
  -m, --mountpoint PATH  Mount point inside LXC (default: /mnt/NAME)
      --uid UID          UID for the new LXC user (default: ${LXC_UID})
      --gid GID          GID for the new LXC group (default: ${LXC_GID})
      --dirs DIR,...     Comma-separated subdirs to create under the mountpoint
      --docker           Add user to docker group in LXC
      --no-backup        Disable backup for this mount point
      --dry-run          Print actions without executing them
  -h, --help             Show this help and exit

Example:
  $(basename "$0") -c 101 -n docs -a paperless --dirs conf,data,media,database --docker

Curl usage:
  bash -c "\$(curl -fsSL https://raw.githubusercontent.com/samuel-ping/proxmox-scripts/main/setup-lxc-dataset.sh)"
EOF
    exit "${1:-0}"
}

### Argument parsing
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--ctid)       CTID="$2";                          shift 2 ;;
        -n|--dataset)    DATASET_NAME="$2";                  shift 2 ;;
        -a|--app)        APP_NAME="$2";                      shift 2 ;;
        -p|--pool)       ZFS_POOL="$2";                      shift 2 ;;
        -m|--mountpoint) MOUNTPOINT="$2";                    shift 2 ;;
        --uid)           LXC_UID="$2";                       shift 2 ;;
        --gid)           LXC_GID="$2";                       shift 2 ;;
        --dirs)          IFS=',' read -ra DIRS <<< "$2";     shift 2 ;;
        --docker)        ADD_DOCKER=true;                     shift ;;
        --no-backup)     BACKUP=0;                            shift ;;
        --dry-run)       DRY_RUN=true;                        shift ;;
        -h|--help)       usage 0 ;;
        *)               error "Unknown option: $1" ;;
    esac
done

### Root check before prompting
[[ $EUID -ne 0 ]] && error "This script must be run as root"

### Interactive prompts for any missing required args
echo ""
echo -e "${BOLD}ZFS Dataset → LXC Setup${NC}"
echo "────────────────────────────────────────"

if [[ -z "${CTID:-}" ]]; then
    CTID=$(prompt_required "LXC container ID")
fi
[[ ! "$CTID" =~ ^[0-9]+$ ]] && error "CTID must be a number"

CONF="/etc/pve/lxc/${CTID}.conf"
[[ ! -f "$CONF" ]] && error "LXC config not found: ${CONF} — does container ${CTID} exist?"

if [[ -z "${DATASET_NAME:-}" ]]; then
    DATASET_NAME=$(prompt_required "Dataset name (e.g. docs)")
fi

if [[ -z "${APP_NAME:-}" ]]; then
    APP_NAME=$(prompt_required "App name — used to name the LXC user/group, e.g. paperless → paperless-user/paperless-users")
fi

ZFS_POOL=$(prompt_default "ZFS pool" "$ZFS_POOL")

_default_mp="/mnt/$(basename "${DATASET_NAME}")"
if [[ -z "${MOUNTPOINT:-}" ]]; then
    MOUNTPOINT=$(prompt_default "LXC mount point" "$_default_mp")
fi

LXC_UID=$(prompt_default "LXC user UID" "$LXC_UID")
LXC_GID=$(prompt_default "LXC group GID" "$LXC_GID")

[[ "$LXC_UID" -lt 1 || "$LXC_UID" -gt 65534 ]] && error "UID must be between 1 and 65534"
[[ "$LXC_GID" -lt 1 || "$LXC_GID" -gt 65534 ]] && error "GID must be between 1 and 65534"

if [[ ${#DIRS[@]} -eq 0 ]]; then
    echo -n "  Subdirectories to create (comma-separated, or leave blank): "
    read -r _dirs_input
    if [[ -n "$_dirs_input" ]]; then
        IFS=',' read -ra DIRS <<< "$_dirs_input"
    fi
fi

if ! $ADD_DOCKER; then
    ADD_DOCKER=$(prompt_bool "Add user to docker group in LXC?")
fi

### Derived values
DATASET_PATH="${ZFS_POOL}/${DATASET_NAME}"
HOST_PATH="/${DATASET_PATH}"
LXC_MP="${MOUNTPOINT}"
USERNAME="${APP_NAME}-user"
GROUPNAME="${APP_NAME}-users"

### Summary
echo ""
echo "────────────────────────────────────────"
echo -e "${BOLD}Plan${NC}"
echo "────────────────────────────────────────"
echo "  Container:   ${CTID}  (${CONF})"
echo "  ZFS dataset: ${DATASET_PATH}  →  ${HOST_PATH}"
echo "  LXC mount:   ${LXC_MP}"
echo "  User/Group:  ${USERNAME} / ${GROUPNAME}  (${LXC_UID}:${LXC_GID})"
[[ ${#DIRS[@]} -gt 0 ]] && echo "  Directories: ${DIRS[*]}"
echo "  Docker:      ${ADD_DOCKER}"
echo "  Backup:      ${BACKUP}"
$DRY_RUN && echo -e "  ${YELLOW}Mode: DRY RUN — no changes will be made${NC}"
echo "────────────────────────────────────────"
echo ""

confirm "Proceed with setup?" || { echo "Aborted."; exit 0; }

# ────────────────────────────────────────────────────────────
step "1/7  Create ZFS dataset"
if zfs list "${DATASET_PATH}" &>/dev/null; then
    warn "Dataset ${DATASET_PATH} already exists — skipping creation"
else
    confirm "Create ZFS dataset '${DATASET_PATH}'?" || error "Aborted at step 1"
    run zfs create -p "${DATASET_PATH}"
    info "Created ${DATASET_PATH}"
fi

# ────────────────────────────────────────────────────────────
step "2/7  Stop LXC ${CTID}"
if pct status "${CTID}" | grep -q "running"; then
    confirm "Stop LXC ${CTID}?" || error "Aborted at step 2"
    run pct stop "${CTID}"
    info "Stopped"
else
    info "Container is already stopped"
fi

# ────────────────────────────────────────────────────────────
step "3/7  Add mountpoint to LXC config"
if grep -q "mp=${LXC_MP}" "$CONF"; then
    warn "Mount point ${LXC_MP} already present in config — skipping"
else
    mp_idx=0
    while grep -q "^mp${mp_idx}:" "$CONF"; do ((mp_idx++)); done
    mp_line="mp${mp_idx}: ${HOST_PATH},mp=${LXC_MP},backup=${BACKUP}"
    confirm "Append to ${CONF}:  ${mp_line}" || error "Aborted at step 3"
    run bash -c "echo '${mp_line}' >> '${CONF}'"
    info "Mountpoint added"
fi

# ────────────────────────────────────────────────────────────
step "4/7  Configure UID/GID idmaps in LXC config"
# Creates a "hole" in the unprivileged container's idmap so that
# LXC uid/gid N maps directly to host uid/gid N instead of the
# default 100000+N offset — lets us chown the ZFS dataset to N
# on the host and have the LXC user own it too.
if grep -q "^lxc.idmap:" "$CONF"; then
    warn "idmap entries already present in ${CONF} — skipping"
    warn "If you need another uid/gid hole, edit ${CONF} manually"
else
    uid_tail=$((65536 - LXC_UID - 1))
    gid_tail=$((65536 - LXC_GID - 1))

    idmap_block=""
    idmap_block+="\n# UID/GID passthrough for ${APP_NAME} (uid=${LXC_UID}, gid=${LXC_GID})"
    idmap_block+="\nlxc.idmap: u 0 100000 ${LXC_UID}"
    idmap_block+="\nlxc.idmap: u ${LXC_UID} ${LXC_UID} 1"
    [[ $uid_tail -gt 0 ]] && idmap_block+="\nlxc.idmap: u $((LXC_UID + 1)) $((100000 + LXC_UID + 1)) ${uid_tail}"
    idmap_block+="\nlxc.idmap: g 0 100000 ${LXC_GID}"
    idmap_block+="\nlxc.idmap: g ${LXC_GID} ${LXC_GID} 1"
    [[ $gid_tail -gt 0 ]] && idmap_block+="\nlxc.idmap: g $((LXC_GID + 1)) $((100000 + LXC_GID + 1)) ${gid_tail}"

    echo -e "  Will append to ${CONF}:${idmap_block}"
    confirm "Add idmap lines to ${CONF}?" || error "Aborted at step 4"

    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY]${NC}   (skipped write)"
    else
        echo -e "${idmap_block}" >> "$CONF"
        info "idmap lines added"
    fi
fi

# ────────────────────────────────────────────────────────────
step "5/7  Update /etc/subuid and /etc/subgid"
if grep -q "^root:${LXC_UID}:1$" /etc/subuid; then
    info "subuid entry already exists for ${LXC_UID}"
else
    confirm "Append 'root:${LXC_UID}:1' to /etc/subuid?" || error "Aborted at step 5"
    run bash -c "echo 'root:${LXC_UID}:1' >> /etc/subuid"
fi

if grep -q "^root:${LXC_GID}:1$" /etc/subgid; then
    info "subgid entry already exists for ${LXC_GID}"
else
    confirm "Append 'root:${LXC_GID}:1' to /etc/subgid?" || error "Aborted at step 5"
    run bash -c "echo 'root:${LXC_GID}:1' >> /etc/subgid"
fi

# ────────────────────────────────────────────────────────────
step "6/7  Set dataset ownership"
confirm "Run: chown ${LXC_UID}:${LXC_GID} ${HOST_PATH}?" || error "Aborted at step 6"
run chown "${LXC_UID}:${LXC_GID}" "${HOST_PATH}"
info "Ownership set"

# ────────────────────────────────────────────────────────────
step "7/7  Start LXC and configure user/group"
confirm "Start LXC ${CTID} and set up user/group?" || error "Aborted at step 7"
run pct start "${CTID}"

if ! $DRY_RUN; then
    info "Waiting for container to become ready..."
    for i in {1..15}; do
        if pct exec "${CTID}" -- true 2>/dev/null; then break; fi
        sleep 4
        [[ $i -eq 15 ]] && error "Container did not become ready after 60s"
    done
fi

info "Creating group '${GROUPNAME}' (gid=${LXC_GID})"
if ! $DRY_RUN && pct exec "${CTID}" -- getent group "${GROUPNAME}" &>/dev/null; then
    warn "Group ${GROUPNAME} already exists — skipping"
else
    run_pct groupadd --gid "${LXC_GID}" "${GROUPNAME}"
fi

info "Creating user '${USERNAME}' (uid=${LXC_UID})"
if ! $DRY_RUN && pct exec "${CTID}" -- id "${USERNAME}" &>/dev/null; then
    warn "User ${USERNAME} already exists — skipping"
else
    run_pct useradd "${USERNAME}" \
        --uid "${LXC_UID}" \
        --gid "${GROUPNAME}" \
        --create-home \
        --shell /bin/bash
fi

if [[ ${#DIRS[@]} -gt 0 ]]; then
    info "Creating subdirectories under ${LXC_MP}"
    for dir in "${DIRS[@]}"; do
        info "  mkdir ${LXC_MP}/${dir}"
        run_pct sudo -u "${USERNAME}" mkdir -p "${LXC_MP}/${dir}"
    done
fi

if [[ "$ADD_DOCKER" == "true" ]]; then
    info "Adding ${USERNAME} to docker group"
    if ! $DRY_RUN && ! pct exec "${CTID}" -- getent group docker &>/dev/null; then
        warn "Docker group not found in LXC — is Docker installed? Skipping."
    else
        run_pct usermod -aG docker "${USERNAME}"
    fi
fi

# ────────────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────"
echo -e "${GREEN}${BOLD}Done!${NC}"
echo "────────────────────────────────────────"
echo "  ZFS dataset:  ${DATASET_PATH}"
echo "  Host path:    ${HOST_PATH}"
echo "  LXC mount:    ${LXC_MP}"
echo "  User/Group:   ${USERNAME} / ${GROUPNAME} (${LXC_UID}:${LXC_GID})"
[[ ${#DIRS[@]} -gt 0 ]] && echo "  Directories:  ${DIRS[*]}"
echo ""
echo "Verify with: pct exec ${CTID} -- ls -la ${LXC_MP}"
