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


# Step 2: Install Jenkins, Docker, Trivy and SonarQube

Part of the Netflix DevSecOps pipeline project, adapted from AWS to a Proxmox homelab.

## Goal

Install the CI/CD and security tooling across the three LXC containers from Step 1, using vendor-supported methods and pinned versions.

## Result

| CT | Role | Installed |
|---|---|---|
| 302 `jenkins-master` | Controller | Jenkins LTS (OpenJDK 21), heap capped at 512 MB |
| 303 `jenkins-agent` | Build agent | Docker CE + Compose plugin, Trivy (pinned and held) |
| 304 `sonarqube` | Code quality | Docker CE, SonarQube Community Build + PostgreSQL 17 via Compose |

## What was done

1. **Host kernel setting.** SonarQube's Elasticsearch needs a high `vm.max_map_count`. This is a host-level setting shared by all LXC containers. The Proxmox host already reported 1048576, so no change was needed.
2. **Docker in CT 304 and CT 303** from Docker's official apt repository (signed key, `.sources` format). Both containers are unprivileged with `nesting` and `keyctl` enabled.
3. **SonarQube** from `docker-compose.yml`: PostgreSQL with a healthcheck, SonarQube waiting on it, named volumes, explicit JVM heap sizes, generated DB password kept in a `chmod 600` `.env` file. Version `26.11.0.134175-community` is the version to pin instead of the moving `community` tag.
4. **Jenkins LTS** from the official apt repository using the current 2026 signing key, with Java installed first. Heap capped via a systemd drop-in (`-Xmx512m`).
5. **Trivy** installed on the agent, version pinned and held with `apt-mark hold`. Verified with a scan of `alpine:3.20`.

## Concepts learned

- **LXC shares the host kernel.** Kernel tunables like `vm.max_map_count` belong to the host; Docker needs `nesting` and `keyctl` to work inside an unprivileged container.
- **Least privilege:** only the container that runs Docker gets those features. All containers stay unprivileged.
- **Pin and verify.** Floating tags (`latest`, `community`) and unpinned packages mean upgrades happen when you didn't choose them.
- **Controller vs agent.** The controller schedules and stores credentials; builds run elsewhere (executors on the built-in node set to 0).
- **Reading a Trivy report.** Each row gives the package, CVE, severity, installed version and fixed version. A fixed version means the remedy is to update the package or rebuild on a newer base image.

## Challenges and solutions

| Challenge | Cause | Solution |
|---|---|---|
| SonarQube native ZIP install was my first suggestion | SonarSource has deprecated ZIP installs; Docker or Helm are the supported routes | Switched to Docker Compose |
| 2.5 GB RAM is below SonarQube's recommended minimum | Three JVMs (web, compute engine, Elasticsearch) plus PostgreSQL | Explicit heap limits; raising CT 304 to 3 GB with swap recommended; keep the k3d cluster stopped while SonarQube runs |
| Embedded database unsuitable | SonarQube's default H2 database is for testing only | PostgreSQL in the same Compose project |
| `cd /opt/sonarqube` failed | Files were created as a non-root user in a different folder | `docker compose ls` shows the real project path |
| Old Jenkins tutorials fail on `apt update` | The 2023 signing key expired in March 2026 | Use `jenkins.io-2026.key` |
| Trivy supply-chain incident (March 2026, CVE-2026-33634) | Release v0.69.4 and Docker images 0.69.5/0.69.6 were malicious | Install a post-incident version, pin it, `apt-mark hold`; never use floating tags for security tools |
| `gpg: no valid OpenPGP data found` | `aquasecurity.github.io` refused connections from the container (likely IPv6/Pages blocking on the hotspot network), and `wget -q` hid the error | Diagnosed with `curl -sS` and exit codes; installed the `.deb` from GitHub Releases or forced IPv4 |
| Trivy DB download failed at 59% | ~139 MB at ~280 KiB/s exceeds the default 5-minute timeout | `trivy image --download-db-only --timeout 30m` in the background, then `--skip-db-update` for scans |

## Debugging habits worth keeping

- Don't use silent flags while diagnosing: `curl -sS`, and print `$?`.
- Use `-f` with curl so a 404 fails instead of saving an error page.
- Prefer checking the real state (`docker compose ls`, `systemctl status`, `trivy --version`) over assuming.

## First scan finding (alpine:3.20)

Trivy reported a HIGH vulnerability in `musl` (installed 1.2.5-r3, fixed in 1.2.5-r4). It is the intended DevSecOps loop: scan, see a fixed version exists, rebuild on an updated base image. A pipeline gate would use `--severity HIGH,CRITICAL --ignore-unfixed --exit-code 1`.

## Verification checklist

- [ ] SonarQube compose file pinned to `26.11.0.134175-community` and recreated
- [ ] CT 304 memory raised to 3 GB (+512 MB swap) or heaps lowered
- [ ] Jenkins built-in node set to 0 executors
- [ ] `docker run --rm hello-world` works on CT 303 and CT 304
- [ ] `apt-mark showhold` lists `trivy` on CT 303
- [ ] Trivy DB cached for the user that will run builds (`du -sh ~/.cache/trivy`)

## Next

Connect CT 303 to Jenkins as an agent, then install the Jenkins plugins and wire up SonarQube.
