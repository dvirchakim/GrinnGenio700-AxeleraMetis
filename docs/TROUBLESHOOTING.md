# Troubleshooting log — getting `metis.ko` to load on MTK 5.15.47

Post-mortem of every failure mode we hit while bringing up the Axelera
Metis driver on a Grinn Genio700 board, in the order we encountered them.
If you're hitting one of these symptoms on a similar MediaTek / Yocto
kirkstone board, this is the cookbook.

---

## 0. Baseline

- Board: Grinn Genio SBC-700 (MT8395).
- Kernel: `5.15.47-mtk+gd011e19cfc68` (Yocto, `CONFIG_LOCALVERSION="-mtk+gd011e19cfc68"`).
- No kernel headers / no `gcc` on the board — everything must be cross-compiled.
- Card: Axelera Metis, PCI `1f9d:1100`, at `0000:01:00.0`.
- `CONFIG_MODVERSIONS` is **not** set (good — we don't need Module.symvers).
- `CONFIG_STACKTRACE_BUILD_ID` is **not** set (contrary to our initial guess).

## 1. Wrong driver (Voyager SDK 1.5.3 `metis-1.4.4` DKMS package)

The Voyager SDK's pre-built modules are:

- `dmabuf-triton-exporter.ko` / `dmabuf-triton-importer.ko`
- `axl-pcie-reset.ko`
- `metis.ko`

On this kernel they fail in two different ways:

- `axl-pcie-reset.ko` calls `register_ftrace_function()` which deadlocks
  against the MTK kernel's ftrace subsystem → `insmod` hangs forever with
  `mod->state == MODULE_STATE_COMING`. Subsequent `insmod`/`lsmod` block
  on `module_mutex`.
- `dmabuf-triton-exporter.ko` (after patching the version guard) ends up
  triggering a kernel Oops in `load_module`.

**Fix:** use the newer, unified driver that's now open-source at
[`axelera-ai-hub/axelera-driver`](https://github.com/axelera-ai-hub/axelera-driver)
(published with Voyager SDK 1.6.0). It's a single `metis.ko` and has no
ftrace tricks.

## 2. `Unknown symbol dma_buf_attach (err -22)`

Symptom on `insmod`:

```
metis: module uses symbol (dma_buf_attach) from namespace DMA_BUF, but does not import it.
metis: Unknown symbol dma_buf_attach (err -22)
```

Root cause: `axl-aipu-core.c` only emits `MODULE_IMPORT_NS(DMA_BUF)` when
`LINUX_VERSION_CODE >= KERNEL_VERSION(5, 16, 0)`, but MediaTek backported
the DMA_BUF namespace to 5.15.

**Fix:** the one-liner in
[`build/patches/0001-lower-dma-buf-namespace-threshold-to-5.15.patch`](../build/patches/0001-lower-dma-buf-namespace-threshold-to-5.15.patch)
— lower the threshold to `KERNEL_VERSION(5, 15, 0)`.

## 3. Vermagic has a trailing `+`

Symptom: module refuses to load; vermagic shows
`5.15.47-mtk+gd011e19cfc68+` (trailing `+`), but the board wants
`5.15.47-mtk+gd011e19cfc68`.

Why: the board config has **both** `CONFIG_LOCALVERSION_AUTO=y` and a
`CONFIG_LOCALVERSION` that already contains `+gd011e19cfc68`. When you
copy `/proc/config.gz` to your build tree, `scripts/setlocalversion` runs
and either doubles the hash (`+gXXX+gXXX`) or adds a trailing `+` for
an uncommitted tree.

**Fix:** turn off `CONFIG_LOCALVERSION_AUTO` and pin the release string
explicitly after `modules_prepare`:

```bash
sed -i 's/^CONFIG_LOCALVERSION_AUTO=y/# CONFIG_LOCALVERSION_AUTO is not set/' .config
# ... run olddefconfig + modules_prepare ...
echo '5.15.47-mtk+gd011e19cfc68' > include/config/kernel.release
printf '#define UTS_RELEASE "5.15.47-mtk+gd011e19cfc68"\n' \
    > include/generated/utsrelease.h
```

`build/build.sh` does this automatically.

## 4. The Big One: Oops at `load_module+0x23a0`

Symptom (with DMA_BUF fix applied and vermagic correct):

```
Unable to handle kernel paging request at virtual address 000e4294b000011c
Mem abort info:
  ESR = 0x96000004
  FSC = 0x04: level 0 translation fault
Internal error: Oops: 96000004 [#1] PREEMPT SMP
CPU: 4 PID: ... Comm: insmod Tainted: G           O      5.15.47-mtk+gd011e19cfc68
pc : load_module+0x23a0/0x2b10
lr : load_module+0x2388/0x2b10
x0 : 910e4294b0000054     ;  <-- looks like ARM64 ADD+ADRP instruction bytes
```

Misleading patterns we chased and had to rule out:

- `CONFIG_STACKTRACE_BUILD_ID` mismatch — **not set** on this board.
- `.altinstructions` relocation errors — stripping the section does not
  fix the crash; same Oops, same offset. (This was proved by
  `objcopy --remove-section=.altinstructions`.)
- `__patchable_function_entries` corruption — same, stripping doesn't help.
- Missing `.BTF` section — the kernel gracefully handles that.

Real root cause: the **struct module ABI** between the running kernel and
`__this_module` in our `.mod.o`.

The board kernel is compiled with `CONFIG_DEBUG_INFO_BTF_MODULES=y`,
which adds this to `struct module` in `include/linux/module.h`:

```c
#ifdef CONFIG_DEBUG_INFO_BTF_MODULES
    void        *btf_data;
    unsigned int btf_data_size;
#endif
```

Our build host had `dwarves` (pahole) **not installed**, so
`make olddefconfig` silently turned `CONFIG_DEBUG_INFO_BTF_MODULES` off
in our `.config`. That meant our `__this_module` had a shorter `struct
module` than the kernel expected, so every field after `btf_data` was
offset by 16 bytes. When `load_module` read one of those misaligned
pointers, it dereferenced something like the module name bytes (which
happen to spell out valid-looking ADD/ADRP instruction encodings as
seen in `x0` above) → translation fault → Oops.

**Fix:** install `dwarves` **before** configuring the kernel:

```bash
sudo apt install -y dwarves
```

After that, `olddefconfig` keeps `CONFIG_DEBUG_INFO_BTF_MODULES=y` and the
resulting `metis.ko` has the correct struct-module ABI.

### How to tell the difference between "hung" and "slow"

On this kernel the first `insmod` of `metis.ko` takes **5–10 seconds**
because the module has ~110 `__patchable_function_entries` that
`ftrace_module_init` has to process, and BTF module registration runs on
top of that.

Useful debug commands:

```bash
# Is it really stuck or just working?
pid=$(pgrep insmod)
cat /proc/$pid/wchan          # function it's sleeping on
cat /proc/$pid/stack          # full kernel stack
```

If `stack` shows `mutex_lock → load_module+0x748` you're waiting on
`module_mutex` — usually because a previous crashed load left a
`MODULE_STATE_COMING` entry in `/sys/module/metis`; you need to reboot.

If `stack` shows `__ftrace_replace_code` / `ftrace_update_code` etc.,
it's just slow. Wait.

## 5. Recovery when the driver crashes the kernel

Once a module load Oopses, the module is stuck in
`MODULE_STATE_COMING` and `module_mutex` is effectively wedged:

- `/sys/module/metis/` exists
- `lsmod` hangs
- Any new `insmod` hangs in `add_unformed_module → mutex_lock`
- `reboot` itself may hang because shutting down waits on the D-state
  insmod process

**Recovery:** power-cycle the board. A clean `/sbin/reboot` typically
does **not** work in this state.

## 6. What this package actually does

After all the above is resolved, `metis.ko` loads cleanly and you get:

```
axl_aipu: root directory for axl_aipu
axl 0000:01:00.0: Adding to iommu group 0
axl 0000:01:00.0: enabling device (0000 -> 0002)
axl 0000:01:00.0: All AER errors masked
axl 0000:01:00.0: DMA trace buffer: 4096 entries (288 KB)
axl 0000:01:00.0: Data Link Layer Link Active Reporting capability
axl 0000:01:00.0: MSI registered 32 (32)
axl 0000:01:00.0: Initializing Metis MSI (nmsi=32, max_msi=32)
axl 0000:01:00.0: Register directory metis-0000:01:00.0
Axelera AIPU PCIe Driver, version 1.4.16, init OK
```

and `/dev/metis-0:1:0` appears.

From there, the Voyager SDK runtime (or any userspace that opens
`/dev/metis-*`) can use the accelerator. This package doesn't include
the runtime — see Axelera's documentation for that side of things.
