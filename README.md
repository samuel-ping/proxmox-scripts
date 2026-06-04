# proxmox-scripts

Utility scripts for menial Proxmox tasks that I do frequently.

---

## setup-lxc-dataset.sh

Automates the setup required to mount a ZFS dataset into an unprivileged LXC container with correct ownership. Run on the Proxmox host as root.

**What it does:**
1. Creates a ZFS dataset under your pool
2. Adds a mountpoint entry to the LXC config
3. Adds `lxc.idmap` lines to pass a UID/GID through to the host (so the LXC user can own the dataset)
4. Updates `/etc/subuid` and `/etc/subgid`
5. Sets ownership of the dataset directory on the host
6. Starts the LXC and creates the user/group inside it
7. Creates any requested subdirectories (as the new user)
8. Optionally adds the user to the docker group

### Usage

**Interactive (curl):** run the script and answer the prompts:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/samuel-ping/proxmox-scripts/main/setup-lxc-dataset.sh)
```

**Non-interactive (curl):** pass flags directly:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/samuel-ping/proxmox-scripts/main/setup-lxc-dataset.sh) \
  -c 101 -n docs -a paperless --dirs conf,data,media,database --docker
```

**Direct:**

```bash
./setup-lxc-dataset.sh -c 101 -n docs -a paperless --dirs conf,data,media,database --docker
```

> **Note:** Use `bash <(curl ...)` (process substitution), not `bash -c "$(curl ...)"`. The latter disconnects stdin, causing interactive prompts to hang.

If any required flag is omitted, the script prompts for it. Each step also asks for confirmation before executing.

| Flag | Description | Default |
|------|-------------|---------|
| `-c, --ctid` | LXC container ID | prompted |
| `-n, --dataset` | Dataset name under pool (e.g. `docs` → `motherpool/docs`; nested like `sping/docs` → `motherpool/sping/docs`) | prompted |
| `-a, --app` | App name — creates `APP-user` / `APP-users` in the LXC | prompted |
| `-p, --pool` | ZFS pool name | `motherpool` |
| `-m, --mountpoint` | Mount point inside LXC | `/mnt/<dataset>` |
| `--uid` | UID for the new LXC user | `1000` |
| `--gid` | GID for the new LXC group | `1000` |
| `--dirs` | Comma-separated subdirs to create under the mountpoint | |
| `--docker` | Add user to docker group in LXC | |
| `--no-backup` | Disable backup for this mount point | |
| `--dry-run` | Print all actions without executing them | |

### Notes

- If `lxc.idmap` lines are already present in the container config, idmap setup is skipped. This is fine if you're adding a second dataset to the same LXC using the same UID — the existing mapping already covers it.
- If you need a different UID for a second dataset on the same LXC, you'll need to add an additional idmap hole manually.
- Use `--dry-run` to preview all changes before committing.
