# DevSecOps : Netflix Clone CI-CD with Monitoring | Email

## Step 1: Prepare the Infrastructure

Part of the Netflix DevSecOps pipeline project, adapted from AWS to a Proxmox homelab.

### Goal

Replace "launch a T2.large EC2 instance" with right-sized, isolated LXC containers on a resource-constrained Proxmox node, with a restore point before anything is installed.

### Environment

| Item | Value |
|---|---|
| Node | `pve1`, Proxmox VE 9.2.11 |
| CPU | Intel i3-2375M, 4 threads at 1.5 GHz |
| RAM | ~7.6 GiB total |
| Disk | ~82 GiB (about 15 GiB used at start) |

### Design

One container per role instead of one large instance:

| CT | Role | RAM | Cores | Notes |
|---|---|---|---|---|
| 302 `jenkins-master` | Jenkins controller | 1 GB | 1 | Orchestrates only; executors will be set to 0 |
| 303 `jenkins-agent` | Docker, Trivy, Node.js, builds | 2 GB | 2 | Needs `nesting` + `keyctl` for Docker |
| 304 `sonarqube` | SonarQube | 2.5 GB | 1 | Embedded Elasticsearch needs the memory; can be stopped when not scanning |

Total is about 5.5 GB, so the full pipeline plus the k3d cluster cannot run at once. The k3d cluster is started only for the deploy stage.

### Key concepts

- **LXC vs VM:** a container shares the host kernel, so overhead is far lower than a VM. The trade-off is that kernel-level settings belong to the host.
- **Unprivileged containers:** root inside maps to a high, harmless UID on the host. A container escape does not yield root on Proxmox. All three containers stay unprivileged.
- **Docker inside LXC:** requires `nesting` (to create its own namespaces/cgroups) and `keyctl` (runc uses keyring syscalls that unprivileged LXC blocks by default).
- **Least privilege:** only the container that runs Docker gets nesting/keyctl.
- **Snapshots:** taken before installing anything so each container can be rolled back to a clean state.

### Steps taken (Proxmox web UI)

1. Reviewed node summary: RAM, CPU, disk headroom.
2. Checked CT 302 and CT 303 Options: both unprivileged, `nesting=1`.
3. Enabled `keyctl` on CT 303 (Options > Features).
4. Created CT 304 `sonarqube` with 2.5 GB RAM and 1 core.
5. Took a snapshot of each container as a clean baseline.

### Challenges and solutions

| Challenge | Solution |
|---|---|
| Only ~5.5 GB of RAM available for the whole pipeline | Split by role with hard memory limits; stop SonarQube and the k3d cluster when not needed |
| Docker fails in unprivileged LXC with permission errors | Enable `nesting` and `keyctl` on the Docker host container only |
| Slow, dual-core CPU | Avoid running scans, builds and backups at the same time |
| A running backup competes for disk I/O | Wait for backups to finish before heavy installs |

### Known requirement for Step 2

SonarQube's Elasticsearch needs `vm.max_map_count >= 262144`. This is a host kernel setting, so it must be set on the Proxmox host, not inside CT 304.

### Verification checklist before moving on

- [ ] CT 303 Features shows `nesting=1,keyctl=1`
- [ ] CT 304 is unprivileged and has the features it needs (depends on how SonarQube is installed)
- [ ] CT 302/303/304 each have a clean baseline snapshot
- [ ] All three containers can reach the internet (`apt update` works)
