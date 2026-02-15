# VMM - Bare Metal MicroVM Manager

## A walkthrough of the application, its design decisions, and how key parts operate

---

## What is VMM?

VMM is a Go CLI tool that manages **Firecracker microVMs** on bare-metal Linux hosts. It targets development environments where you want something lighter than full VMs but more isolated than containers.

**The pitch**: Spin up lightweight VMs as easily as Docker containers, but with real kernel-level isolation. Each VM boots in under a second, uses minimal resources, and gets its own network stack.

**Target use case**: 10-50 concurrent development VMs on a single host, for tasks where Docker's isolation model isn't sufficient or where you need lower-level OS access.

---

## Why Firecracker?

Firecracker is Amazon's microVM engine (the same technology behind AWS Lambda and Fargate). VMM chose Firecracker over alternatives for several reasons:

| Property | Firecracker | QEMU/KVM | Docker |
|----------|-------------|----------|--------|
| Boot time | ~125ms | Seconds | N/A |
| Memory overhead | ~5MB per VM | ~130MB+ | Shared kernel |
| Isolation | Full VM (KVM) | Full VM (KVM) | Namespace only |
| Attack surface | Minimal device model | Large device model | Kernel shared |

The trade-off: Firecracker intentionally omits features like GPU passthrough, live migration, and USB support. VMM accepts these limitations in exchange for speed and simplicity.

---

## Architecture Overview

```
                    ┌───────────────────────────┐
                    │        vmm CLI (Cobra)     │
                    │  create│start│stop│ssh│...  │
                    └────────────┬──────────────┘
                                 │
              ┌──────────────────┼──────────────────┐
              │                  │                   │
    ┌─────────▼──────┐  ┌───────▼───────┐  ┌───────▼───────┐
    │  Config Store   │  │ Image Manager │  │Network Manager│
    │  (JSON files)   │  │ (kernel/rootfs│  │(bridge, TAP,  │
    │                 │  │  Docker import)│  │ iptables NAT) │
    └────────────────┘  └───────────────┘  └───────────────┘
              │                  │                   │
              └──────────────────┼──────────────────┘
                                 │
                    ┌────────────▼──────────────┐
                    │   Firecracker Client       │
                    │   (Go SDK, Unix socket)    │
                    └────────────┬──────────────┘
                                 │
                    ┌────────────▼──────────────┐
                    │  Firecracker VMM Process   │
                    │  (one per running microVM) │
                    └───────────────────────────┘
```

VMM is structured as a thin orchestration layer. It doesn't implement virtualisation itself — it coordinates Linux networking primitives, filesystem operations, and the Firecracker SDK to present a simple CLI interface.

---

## Design Decision: Monolithic `main.go`

All CLI commands live in a single file: `cmd/vmm/main.go`. This is a deliberate choice:

- Every command follows the same pattern: load config, resolve paths, load VM state, perform action, save state
- There are no complex command hierarchies that would benefit from separate files
- Having everything in one place makes it easy to see the full CLI surface at a glance
- Cobra subcommands (like `image import`, `kernel build`, `mount list`) are defined inline as nested commands

The internal packages handle all the actual logic — `main.go` is purely glue code.

---

## The VM Lifecycle

A VM goes through a clear state machine:

```
     create              start               stop              delete
  ┌──────────┐      ┌───────────┐      ┌───────────┐      ┌──────────┐
  │          │      │           │      │           │      │          │
  │ (nothing)├─────►│  created  ├─────►│  running  ├─────►│  stopped ├──► (removed)
  │          │      │           │      │           │      │          │
  └──────────┘      └───────────┘      └───────────┘      └──────────┘
```

**Create** stores a JSON config in `/var/lib/vmm/vms/<name>.json` — no resources are allocated yet. This is intentional: you can create VM definitions ahead of time, template them, or configure defaults.

**Start** is where the real work happens:
1. Copy the rootfs image to create a per-VM disk
2. Resize the disk to the requested size (`truncate` + `resize2fs`)
3. Mount the rootfs and inject SSH keys, DNS config, and fstab entries
4. Allocate an IP address from the 172.16.0.0/16 pool
5. Create a TAP device and attach it to the bridge
6. Set up iptables NAT rules
7. Launch the Firecracker process with the VM configuration

**Stop** kills the Firecracker process, cleans up the TAP device, and updates the VM state.

**Delete** removes the VM config file and its rootfs copy.

---

## Design Decision: IP via Kernel Parameters

A key early problem: how do VMs get their network configuration? The default rootfs doesn't include a DHCP client, and running a DHCP server adds complexity.

**Solution**: VMM passes the IP address directly via the Linux kernel's `ip=` boot parameter:

```
ip=172.16.0.2::172.16.0.1:255.255.0.0::eth0:off
```

This means VMs have network connectivity the instant the kernel boots — no waiting for DHCP, no additional services needed. The format is:
```
ip=<client-ip>::<gateway>:<netmask>::<device>:off
```

The trade-off is that IP changes require a reboot, but for development VMs this is acceptable.

---

## Networking in Detail

VMM creates a bridge network that connects all VMs:

```
  Internet
     │
     ▼
┌─────────────┐
│ Host NIC    │  (e.g. wlp3s0, auto-detected from default route)
│ (physical)  │
└──────┬──────┘
       │  iptables MASQUERADE (NAT)
       │  iptables DNAT (port forwarding)
       ▼
┌─────────────┐
│  vmm-br0    │  172.16.0.1/16 (Linux bridge)
└──┬──┬──┬────┘
   │  │  │
   ▼  ▼  ▼
 vmm-aa  vmm-bb  vmm-cc     (TAP devices, one per VM)
   │     │     │
   ▼     ▼     ▼
 VM 1  VM 2  VM 3           (172.16.0.2, .3, .4 ...)
```

Key networking decisions:

- **Auto-detection of host interface**: VMM reads `/proc/net/route` to find the default route interface. This avoids hardcoding `eth0` which fails on systems with names like `wlp3s0` or `ens33`.
- **Sequential IP allocation**: IPs are allocated from .2 upward by scanning existing VMs. Simple and predictable.
- **Bridge created on first VM start**: The bridge and NAT rules are set up lazily, so installing VMM doesn't modify your network until you actually run a VM.
- **TAP cleanup on stop**: Each TAP device is deleted when its VM stops, preventing "resource busy" errors on restart.

---

## Image Management: The Download Chain

VMM needs two images to boot a VM: a Linux kernel and a root filesystem. These are sourced through a fallback chain:

```
  GitHub Releases (primary)
         │
         │  Query api.github.com for latest kernel-* or rootfs-* release
         │
         ▼
  ┌─ Found? ──► Download from GitHub release asset
  │
  └─ Not found ──► Fall back to Firecracker S3 URLs (legacy)
```

This pattern appears in three places, all following the same logic:
1. **Go code** (`image.go`): `findLatestKernelURL()` and `findLatestRootfsURL()`
2. **Install script** (`install.sh`): Shell equivalent using `curl`/`wget` + `jq`
3. **CI workflows**: Build and publish to GitHub Releases with conventional tags

**Tag conventions**:
- `v*` — binary releases (GoReleaser)
- `kernel-*` — kernel releases (e.g. `kernel-6.1.162`)
- `rootfs-24.04-YYYYMMDD` — rootfs releases

---

## Design Decision: Docker Image Import

One of VMM's most useful features is turning Docker images into VM root filesystems. This bridges the Docker ecosystem with VM-level isolation.

The process:

```
Docker Image ──► docker create ──► docker export ──► tar extract
                                                         │
                                                         ▼
                                              Temp directory with
                                              flat filesystem
                                                         │
                                              ┌──────────▼──────────┐
                                              │  Chroot operations:  │
                                              │  • Install systemd   │
                                              │  • Install openssh   │
                                              │  • Configure init    │
                                              │  • Enable serial     │
                                              │  • Set up networking │
                                              └──────────┬──────────┘
                                                         │
                                                         ▼
                                              Create ext4 image
                                              (truncate + mkfs.ext4
                                               + loop mount + copy)
```

**Why `docker create` + `docker export`?** Docker's `save` command outputs layered tarballs, which are complex to reconstruct. `export` gives a flat filesystem that's ready to use.

**Why chroot?** The exported image won't have systemd, SSH, or serial console support — things that Firecracker needs. VMM enters a chroot, bind-mounts `/dev`, `/proc`, `/sys`, and runs `apt-get install` to add the required packages.

**Why ext4 images?** Firecracker uses block devices, not filesystem passthroughs. `truncate -s` creates a sparse file (no disk space wasted), `mkfs.ext4 -F` formats it, and the contents are copied in via a loop mount.

---

## Host Directory Mounts

Since Firecracker doesn't support virtio-fs (shared filesystem), VMM uses a block device approach:

```
Host directory ──► Create ext4 image ──► Attach as /dev/vdb ──► Mount at /mnt/<tag>
(/home/user/code)    from contents        in Firecracker          via fstab injection
```

**How it works**:
1. At `vmm start`, each mount's host directory is packaged into an ext4 image
2. Fstab entries are injected into the VM's rootfs (e.g. `/dev/vdb /mnt/code ext4 defaults 0 0`)
3. The images are attached as additional Firecracker block devices
4. The VM boots with mounts already available

**Limitations**: Mounts are snapshots — changes inside the VM don't propagate back to the host. To update, you stop the VM, run `vmm mount sync`, and restart. This is a pragmatic compromise given Firecracker's constraints.

---

## Configuration System

VMM uses a three-tier configuration model:

```
  CLI flags (highest priority)
       │
       ▼
  Config file defaults (~/.config/vmm/config.json → vm_defaults section)
       │
       ▼
  Built-in defaults (lowest priority)
```

Example resolution for `--cpus`:
- `vmm create myvm --cpus 4` → uses 4 (CLI flag)
- `vmm create myvm` with `"cpus": 2` in config → uses 2 (config default)
- `vmm create myvm` with no config default → uses 1 (built-in)

**Sudo awareness**: When running `sudo vmm start`, VMM detects `SUDO_USER` and reads the original user's config from their home directory, not from `/root`. This same logic applies to SSH key resolution in `vmm ssh`.

---

## CI/CD Pipeline

Three GitHub Actions workflows handle different release types:

```
  ┌──────────────────┐    ┌───────────────────┐    ┌───────────────────┐
  │  release.yaml    │    │ build-kernel.yml   │    │ build-rootfs.yml  │
  │                  │    │                    │    │                   │
  │ Trigger: v* tag  │    │ Trigger: weekly,   │    │ Trigger: weekly,  │
  │                  │    │ manual, or push to │    │ manual, or push   │
  │ GoReleaser builds│    │ build-kernel.sh    │    │ to build-rootfs.sh│
  │ binaries for     │    │                    │    │                   │
  │ linux/amd64+arm64│    │ Resolves latest    │    │ Builds Ubuntu     │
  │                  │    │ patch from         │    │ 24.04 rootfs via  │
  │ Creates GitHub   │    │ kernel.org, builds │    │ Docker + chroot   │
  │ release with     │    │ if no release      │    │                   │
  │ attached binaries│    │ exists for that    │    │ Tags as rootfs-   │
  │                  │    │ version            │    │ 24.04-YYYYMMDD    │
  └──────────────────┘    └───────────────────┘    └───────────────────┘
         │                        │                        │
         ▼                        ▼                        ▼
      v0.4.0                kernel-6.1.162        rootfs-24.04-20260210
```

The kernel and rootfs workflows are **idempotent**: they check if a release already exists for the resolved version/date before building. This means the weekly schedule only produces new releases when upstream changes.

---

## Storage Layout

All VMM data lives under `/var/lib/vmm`:

```
/var/lib/vmm/
├── vms/                  # VM configs (JSON, one per VM)
│   ├── myvm.json         #   Name, ID, state, IPs, settings
│   └── test1.json
├── images/
│   ├── kernels/          # Kernel binaries
│   │   └── vmlinux.bin   #   Default kernel (from GitHub releases)
│   └── rootfs/           # Base rootfs images
│       └── rootfs.ext4   #   Default rootfs (Ubuntu 24.04)
├── mounts/               # Mount images (ext4, per VM per mount)
│   └── myvm-code.ext4
├── sockets/              # Firecracker API sockets (Unix domain)
├── logs/                 # Per-VM log files
└── state/                # Runtime state files
```

**Why JSON for VM state?** It's human-readable, debuggable, and sufficient for the scale VMM targets. No database needed for 10-50 VMs.

**Why per-VM rootfs copies?** Each VM gets its own copy of the base rootfs, allowing independent disk state. The copy is created at `vmm start` time with SSH keys and DNS already injected.

---

## Key Code Patterns

### Error handling
All errors bubble up with context wrapping:
```go
return fmt.Errorf("failed to create rootfs for %s: %w", vmName, err)
```

### Process detection across privilege boundaries
A non-root user running `vmm list` needs to detect whether a root-owned Firecracker process is running. The `IsRunning()` function handles this:
```go
err := process.Signal(syscall.Signal(0))
if err == nil {
    return true      // Process exists, we can signal it
}
if errors.Is(err, syscall.EPERM) {
    return true      // Process exists, but we lack permission (non-root checking root process)
}
return false          // Process doesn't exist
```

### Sudo-aware path resolution
```go
func ConfigPath() string {
    if sudoUser := os.Getenv("SUDO_USER"); sudoUser != "" {
        // Use the original user's home, not /root
        home := lookupUserHome(sudoUser)
        return filepath.Join(home, ".config", "vmm", "config.json")
    }
    // Normal path resolution
}
```

---

## What VMM Doesn't Do (By Design)

- **No daemon**: VMM is a stateless CLI. Firecracker processes run independently. There's no long-running VMM service to crash or manage.
- **No database**: VM state is plain JSON files. You can inspect, edit, or back them up with standard tools.
- **No custom networking stack**: VMM uses standard Linux bridge + iptables. Nothing proprietary.
- **No container runtime**: VMM doesn't try to be Docker. It operates at the VM level with full kernel isolation.
- **No cluster support**: VMM manages VMs on a single host. Multi-host orchestration is out of scope.

---

## Summary

VMM is a focused tool that combines well-understood Linux primitives (bridges, TAP devices, iptables, ext4, loop mounts) with Firecracker's fast microVM engine to provide a Docker-like experience with VM-level isolation.

The key design philosophy is **simplicity over features**: JSON instead of databases, shell scripts for image building, sequential IP allocation, stateless CLI, and a flat code structure. This makes the system easy to understand, debug, and extend.
