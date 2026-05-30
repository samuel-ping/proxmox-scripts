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

```
./setup-lxc-dataset.sh -c CTID -n DATASET -a APP [OPTIONS]
```

| Flag | Description | Default |
|------|-------------|---------|
| `-c, --ctid` | LXC container ID | required |
| `-n, --dataset` | Dataset name under pool (e.g. `docs` → `motherpool/docs`) | required |
| `-a, --app` | App name — creates `APP-user` / `APP-users` in the LXC | required |
| `-p, --pool` | ZFS pool name | `motherpool` |
| `-m, --mountpoint` | Mount point inside LXC | `/mnt/<dataset>` |
| `--uid` | UID for the new LXC user | `1000` |
| `--gid` | GID for the new LXC group | `1000` |
| `--dirs` | Comma-separated subdirs to create under the mountpoint | |
| `--docker` | Add user to docker group in LXC | |
| `--no-backup` | Disable backup for this mount point | |
| `--dry-run` | Print all actions without executing them | |

### Example

```bash
./setup-lxc-dataset.sh -c 101 -n docs -a paperless \
  --dirs conf,data,media,database \
  --docker
```

This creates `motherpool/docs`, mounts it at `/mnt/docs` in container 101, creates `paperless-user` / `paperless-users` (uid/gid 1000), makes the four subdirectories, and adds `paperless-user` to the docker group.

### Notes

- If `lxc.idmap` lines are already present in the container config, idmap setup is skipped. This is fine if you're adding a second dataset to the same LXC using the same UID — the existing mapping already covers it.
- If you need a different UID for a second dataset on the same LXC, you'll need to add an additional idmap hole manually.
- Use `--dry-run` to preview all changes before committing.
