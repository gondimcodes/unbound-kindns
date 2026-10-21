# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.1.3] - 2026-10-21

### Added
- **Persistent Engine Environment Variables**: The `CONTAINER_ENGINE` and `CTR_BIN` environment variables are now explicitly injected and persisted in `/etc/environment` during host deployment (`setup_host_environment`).
- **Global Host Integration**: Helper scripts and telemetry tools source `/etc/environment` at startup with intelligent fallbacks, ensuring deterministic Docker or Podman engine detection across all host routines.

### Changed
- `unboundSend.sh`: Sources `/etc/environment` and adopts `CTR_BIN` directly, making Zabbix metrics collection resilient against socket variations in daemonless container setups.
- `teste_dns.sh`: Sources `/etc/environment` and prioritizes `CTR_BIN` for container command execution.

---

## [1.1.2] - 2026-10-21

### Added
- **Multi-Protocol Anycast Gating**: Automated discovery and atomic route gating for OSPFv2 (`ospfd`), OSPFv3 (`ospf6d`), and BGP (`bgpd` with auto-detected ASN) to withdrawal Anycast loopback prefixes when upstream/root recursive resolution fails.
- **State Machine Alert Gating**: State management tracked in `/run/teste_dns.state`, guaranteeing that Telegram notifications and FRR router writes occur exclusively upon actual state transitions (`UP -> DOWN` or `DOWN -> UP`).
- **Unbound Self-Healing**: Automatic container restart upon detecting 100% resolution failure to flush stuck sockets and unfreeze the `infra-cache` following prolonged upstream network blackouts.

### Fixed
- **Atomic vtysh Execution**: Commands are dispatched using native structured `-c` arguments (`vtysh -c "conf t" -c "interface lo" ... -c "write memory"`), eliminating buffer flushes and broken stdin pipe issues in Podman containers.
- **FRR Interface Parser**: Replaced deprecated sub-commands with precise `interface lo` block extraction via `awk '/^interface lo$/,/^exit$/'` against `show running-config`.

---

## [1.1.1] - 2026-10-21

### Added
- **Native Host-Network Builds in Podman**: Chrony and Unbound image compilation now executes directly via the native CLI with `--network host --dns 1.1.1.1 --dns 8.8.8.8`, bypassing Netavark DNS resolution timeouts behind firewalls with default `DROP` policies.
- **Zero-Downtime Decoupled Builds**: Container images are pre-compiled in `build_images()` before stopping old services, eliminating deploy downtime.
- **Mandatory DNS Standardization**: Public fallback DNS entries are injected into `/etc/resolv.conf` during deploy to guarantee uninterrupted package downloads.

### Changed
- Configured canonical registry search domains in `/etc/containers/registries.conf` (`docker.io`, `quay.io`).
- Configured the default OCI runtime as `crun` in `/etc/containers/containers.conf`.
- Dynamic AppArmor management: security profile `unconfined` is applied only when `APPARMOR="0"`.

### Fixed
- Container engine detection in watchdogs now inspects stopped containers (`podman ps -a`), enabling auto-healing if the Unbound container crashes completely.

---

## [1.1.0] - 2026-10-20

### Added
- **Agnostic Container Engine Support**: Full native support for Podman in daemonless mode with feature parity with Docker CE.
- **Persistent Auto-Restart Configuration**: Automatic enablement of `podman-restart.service` ensuring containers restart across system reboots.
- **Zabbix Agent 2 Integration**: Direct mounting of the native engine socket (`podman.sock` or `docker.sock`) into the Zabbix Agent container.
- **CI/CD Pipeline**: End-to-end automated deployment testing workflow (`test-installer.yml`) covering Docker and Podman under Debian.

---

## [1.0.4] - 2026-07-17

### Fixed
- Adjusted Zabbix Agent 2 volume mounts and `tmpfs` paths (`/run/zabbix`, `/var/run/zabbix`) to prevent PID and buffer write errors.

---

## [1.0.3] - 2026-07-07

### Added
- Added `create 0640 unbound unbound` directive to logrotate configuration (`/etc/logrotate.d/unbound`), ensuring proper file ownership (UID/GID 88:88).

### Changed
- Updated directory tree documentation in `README.md` to reflect Named Volumes separated from `/usr/local/src`.

---

## [1.0.1] - 2026-07-05

### Fixed
- Corrected column alignment, spacing, and host system information in the installer banner (`draw_banner`).

---

## [1.0.0] - 2026-07-05

### Added
- Initial release of the **unbound-kindns** automated deployment system for Debian 12/13.
- Containerized micro-services architecture via Compose: Unbound (custom compiled on Alpine), FRR (Anycast OSPF routing), and Chrony (NTP stratum synchronization).
- Kernel and network sysctl performance optimizations engineered for ISP high-load recursive DNS.
- Zabbix Agent 2 integration with native `unbound-control` telemetry.
