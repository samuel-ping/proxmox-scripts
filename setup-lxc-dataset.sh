#!/usr/bin/env bash
# setup-lxc-dataset.sh
# Automates ZFS dataset creation and LXC container configuration for Docker apps on Proxmox.
# Run as root on the Proxmox host.
#
# What it does:
#   1. Creates a ZFS dataset under your pool
#   2. Adds a mountpoint to the LXC config
#   3. Adds lxc.idmap lines so the LXC user can own the mounted dataset
#   4. Updates /etc/subuid and /etc/subgid on the host
#   5. Sets ownership of the dataset directory
#   6. Starts the LXC and creates the user/group inside it
#   7. Creates any requested subdirectories (as the new user)
#   8. Optionally adds the user to the docker group

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
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
step()  { echo -e "${BLUE}[STEP]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# run: executes a command, or just prints it in --dry-run mode
run() {
    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY]${NC}   $*"
    else
        "$@"
    fi
}

# run_pct: runs a command inside the LXC via pct exec
run_pct() {
    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY]${NC}   pct exec ${CTID} -- $*"
    else
        pct exec "${CTID}" -- "$@"
    fi
}

usage() {
    cat <<EOF
Usage: $(basename "$0") -c CTID -n DATASET -a APP [OPTIONS]

Automates ZFS dataset creation and LXC container configuration for a Docker app.
Must be run as root on the Proxmox host.

Required:
  -c, --ctid CTID        LXC container ID
  -n, --dataset NAME     Dataset name under pool (e.g. "docs" creates POOL/docs)
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

### Validation
[[ -z "${CTID:-}"         ]] && error "Missing required argument: -c/--ctid"
[[ -z "${DATASET_NAME:-}" ]] && error "Missing required argument: -n/--dataset"
[[ -z "${APP_NAME:-}"     ]] && error "Missing required argument: -a/--app"
[[ $EUID -ne 0            ]] && error "This script must be run as root"
[[ ! "$CTID" =~ ^[0-9]+$ ]] && error "CTID must be a number"
[[ "$LXC_UID" -lt 1 || "$LXC_UID" -gt 65534 ]] && error "UID must be between 1 and 65534"
[[ "$LXC_GID" -lt 1 || "$LXC_GID" -gt 65534 ]] && error "GID must be between 1 and 65534"

CONF="/etc/pve/lxc/${CTID}.conf"
[[ ! -f "$CONF" ]] && error "LXC config not found: ${CONF} — does container ${CTID} exist?"

### Derived values
DATASET_PATH="${ZFS_POOL}/${DATASET_NAME}"
HOST_PATH="/${DATASET_PATH}"   # ZFS mounts datasets at /<dataset-path> by default
LXC_MP="${MOUNTPOINT:-/mnt/${DATASET_NAME}}"
USERNAME="${APP_NAME}-user"
GROUPNAME="${APP_NAME}-users"

echo ""
echo "  Container:   ${CTID}  (${CONF})"
echo "  ZFS dataset: ${DATASET_PATH}  →  ${HOST_PATH}"
echo "  LXC mount:   ${LXC_MP}"
echo "  User/Group:  ${USERNAME} / ${GROUPNAME}  (${LXC_UID}:${LXC_GID})"
[[ ${#DIRS[@]} -gt 0 ]] && echo "  Directories: ${DIRS[*]}"
$ADD_DOCKER && echo "  Docker:      yes"
$DRY_RUN    && echo -e "  ${YELLOW}Mode: DRY RUN — no changes will be made${NC}"
echo ""

# ────────────────────────────────────────────────────────────
step "1/7  Creating ZFS dataset"
if zfs list "${DATASET_PATH}" &>/dev/null; then
    warn "Dataset ${DATASET_PATH} already exists — skipping creation"
else
    run zfs create "${DATASET_PATH}"
    info "Created ${DATASET_PATH}"
fi

# ────────────────────────────────────────────────────────────
step "2/7  Stopping LXC ${CTID}"
if pct status "${CTID}" | grep -q "running"; then
    run pct stop "${CTID}"
    info "Stopped"
else
    info "Container is already stopped"
fi

# ────────────────────────────────────────────────────────────
step "3/7  Adding mountpoint to LXC config"
if grep -q "mp=${LXC_MP}" "$CONF"; then
    warn "Mount point ${LXC_MP} already present in config — skipping"
else
    mp_idx=0
    while grep -q "^mp${mp_idx}:" "$CONF"; do ((mp_idx++)); done
    mp_line="mp${mp_idx}: ${HOST_PATH},mp=${LXC_MP},backup=${BACKUP}"
    info "Appending: ${mp_line}"
    run bash -c "echo '${mp_line}' >> '${CONF}'"
fi

# ────────────────────────────────────────────────────────────
step "4/7  Configuring UID/GID idmaps in LXC config"
# We create a "hole" in the unprivileged container's idmap so that
# LXC uid/gid NNNN maps directly to host uid/gid NNNN instead of
# the default 100000+NNNN offset — this lets us chown the ZFS
# dataset to NNNN on the host and have the LXC user own it too.
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

    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY]${NC}   Appending to ${CONF}:${idmap_block}"
    else
        echo -e "${idmap_block}" >> "$CONF"
        info "idmap lines added"
    fi
fi

# ────────────────────────────────────────────────────────────
step "5/7  Updating /etc/subuid and /etc/subgid"
if grep -q "^root:${LXC_UID}:1$" /etc/subuid; then
    info "subuid entry already exists for ${LXC_UID}"
else
    info "Adding root:${LXC_UID}:1 to /etc/subuid"
    run bash -c "echo 'root:${LXC_UID}:1' >> /etc/subuid"
fi

if grep -q "^root:${LXC_GID}:1$" /etc/subgid; then
    info "subgid entry already exists for ${LXC_GID}"
else
    info "Adding root:${LXC_GID}:1 to /etc/subgid"
    run bash -c "echo 'root:${LXC_GID}:1' >> /etc/subgid"
fi

# ────────────────────────────────────────────────────────────
step "6/7  Setting dataset ownership: ${HOST_PATH} → ${LXC_UID}:${LXC_GID}"
run chown "${LXC_UID}:${LXC_GID}" "${HOST_PATH}"

# ────────────────────────────────────────────────────────────
step "7/7  Starting LXC and setting up user/group"
run pct start "${CTID}"

if ! $DRY_RUN; then
    info "Waiting for container to become ready..."
    for i in {1..15}; do
        if pct exec "${CTID}" -- true 2>/dev/null; then
            break
        fi
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

if $ADD_DOCKER; then
    info "Adding ${USERNAME} to docker group"
    if ! $DRY_RUN && ! pct exec "${CTID}" -- getent group docker &>/dev/null; then
        warn "Docker group not found in LXC — is Docker installed? Skipping."
    else
        run_pct usermod -aG docker "${USERNAME}"
    fi
fi

# ────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}Done!${NC}"
echo ""
echo "  ZFS dataset:  ${DATASET_PATH}"
echo "  Host path:    ${HOST_PATH}"
echo "  LXC mount:    ${LXC_MP}"
echo "  User/Group:   ${USERNAME} / ${GROUPNAME} (${LXC_UID}:${LXC_GID})"
[[ ${#DIRS[@]} -gt 0 ]] && echo "  Directories:  ${DIRS[*]}"
echo ""
echo "Verify with: pct exec ${CTID} -- ls -la ${LXC_MP}"
