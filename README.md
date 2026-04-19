# Axelera Metis driver for Grinn Genio700 SBC

Working driver + install package for the **Axelera Metis M.2 AI accelerator
card (PCI `1f9d:1100`)** running on the **Grinn Genio700 SBC** with the
**MediaTek Genio BSP 5.15.47 kernel** (Yocto kirkstone image,
`uname -r` = `5.15.47-mtk+gd011e19cfc68`).

This is the [Axelera v1.6 open-source driver](https://github.com/axelera-ai-hub/axelera-driver)
(single `metis.ko`) cross-compiled against the exact MediaTek BSP kernel
sources and config, with one small upstream patch so that the DMA_BUF
symbol namespace is imported on kernel 5.15 (which backports the namespace
split normally only present from 5.16 upstream).

## What's in here

| Path                                  | Purpose |
| ------------------------------------- | ------- |
| `deploy/metis.ko`                     | Pre-built kernel module (ready to install) |
| `deploy/board_install.sh`             | One-shot installer — copies `metis.ko`, udev rules, loads module |
| `deploy/72-axelera.rules`             | udev rules (device nodes under `/dev/metis*`, `axelera` group) |
| `build/build.sh`                      | Reproducible build script (fetches MTK kernel + driver, applies patch, compiles) |
| `build/board-full.config`             | `/proc/config.gz` from the running board (used for cross-build) |
| `build/patches/0001-*.patch`          | The one-line patch to `axl-aipu-core.c` (DMA_BUF NS threshold) |
| `docs/TROUBLESHOOTING.md`             | Post-mortem of the debugging: every crash, the root cause, and the fix |

## Quick start — install on the board

From any machine with SSH access to the Grinn board (default user `root`):

```bash
scp -r deploy/ root@<BOARD_IP>:/tmp/axelera-install
ssh root@<BOARD_IP> 'sh /tmp/axelera-install/board_install.sh'
```

Expected output (tail):

```
Axelera AIPU PCIe Driver, version 1.4.16, init OK
axl 0000:01:00.0: Register directory metis-0000:01:00.0
```

and `/dev/metis-0:1:0` should appear. Full log at `/tmp/axelera-install.log`.

> **Be patient:** the first `insmod` takes **5 – 10 seconds** on this kernel
> because of BTF processing + ftrace patching of ~110 function entries.
> The installer uses `timeout 30`; do not shorten it.

## Quick start — rebuild `metis.ko` from sources

On an Ubuntu 22.04 build host (or WSL):

```bash
sudo apt install -y build-essential bc bison flex libssl-dev \
                    libelf-dev cpio rsync kmod dwarves \
                    gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu git
./build/build.sh
# -> deploy/metis.ko
```

The script:

1. Clones the MTK kernel at commit `d011e19cfc68` (the exact Yocto SRCREV).
2. Clones `axelera-driver` at `release/v1.6`.
3. Applies the DMA_BUF namespace patch.
4. Runs `olddefconfig` + `modules_prepare` using `board-full.config`
   (which has `CONFIG_DEBUG_INFO_BTF_MODULES=y` — crucial, see below).
5. Pins `UTS_RELEASE` to `5.15.47-mtk+gd011e19cfc68` (avoids the trailing
   `+` that `setlocalversion` would otherwise add).
6. Builds and verifies vermagic + `import_ns=DMA_BUF`.

## The two bugs that made this hard

### 1. `CONFIG_DEBUG_INFO_BTF_MODULES=y` changes `struct module` layout

The board kernel is built with `CONFIG_DEBUG_INFO_BTF_MODULES=y`, which
inserts two extra fields into `struct module`:

```c
#ifdef CONFIG_DEBUG_INFO_BTF_MODULES
    void        *btf_data;
    unsigned int btf_data_size;
#endif
```

If the out-of-tree module is built with that config **off**, `__this_module`
has a shorter layout than the kernel expects. When the kernel reads
`mod->btf_data`, it reads garbage from the wrong offset and eventually
dereferences it, causing a kernel Oops deep inside `load_module`:

```
Unable to handle kernel paging request at virtual address 000e4294b000011c
pc : load_module+0x23a0/0x2b10
```

`make olddefconfig` silently drops `CONFIG_DEBUG_INFO_BTF_MODULES=y` if
`pahole` is not installed. **Install `dwarves` (provides `pahole`) before
running `olddefconfig`** or the config will be downgraded and you'll hit
this exact crash.

### 2. DMA_BUF symbol namespace is backported to MTK 5.15

Upstream Linux moved several `dma_buf_*` symbols into the `DMA_BUF`
namespace in 5.16. The MediaTek BSP kernel backported that change to 5.15,
so modules on this kernel must declare `MODULE_IMPORT_NS(DMA_BUF)` even
though `LINUX_VERSION_CODE` says 5.15.47.

Upstream `axl-aipu-core.c` guards the import with `>= 5.16.0`; our patch
lowers the guard to `>= 5.15.0`. Without it you get:

```
metis: module uses symbol (dma_buf_attach) from namespace DMA_BUF,
       but does not import it.
metis: Unknown symbol dma_buf_attach (err -22)
```

See `docs/TROUBLESHOOTING.md` for the full story (including two earlier
dead-ends: `.altinstructions` relocations and the trailing-`+` vermagic
mismatch).

## Hardware / kernel versions this matches

| Item                      | Value |
| ------------------------- | ----- |
| Board                     | Grinn Genio SBC-700 (MediaTek Genio 700 / MT8395) |
| BSP                       | `meta-grinn-genio` kirkstone_5.15_v24.1.1 |
| Kernel source             | `gitlab.com/mediatek/aiot/bsp/linux.git` @ `d011e19cfc68` |
| `uname -r`                | `5.15.47-mtk+gd011e19cfc68` |
| Metis card                | PCI `1f9d:1100` (Axelera AI) |
| Driver                    | `axelera-ai-hub/axelera-driver` @ `release/v1.6` (v1.4.16) |

## License

GPL-2.0 — matching the Axelera driver upstream.
