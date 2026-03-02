# Repository Technical Breakdown

Comprehensive analysis of the vphone-cli codebase: a virtual iPhone boot tool for iOS security research using Apple's Virtualization.framework with PCC (Private Cloud Compute) research VMs.

---

## 1. Repository Statistics

| Metric | Count |
|--------|-------|
| Total source files | 30 |
| Total lines of code | ~9,363 |
| Swift source files | 10 (1,015 lines) |
| Python source files | 11 (6,931 lines) |
| Shell scripts | 6 (1,193 lines) |
| Build files | 2 (208 lines) |
| Entitlements | 1 (16 lines) |
| Research docs | 7 markdown files |
| Resource archives | 3 (`.tar.zst`) |

### Lines of Code by File

**Swift (sources/vphone-cli/)**

| File | Lines | Purpose |
|------|-------|---------|
| `main.swift` | 11 | Entry point |
| `VPhoneAppDelegate.swift` | 103 | App lifecycle, SIGINT, VM start |
| `VPhoneCLI.swift` | 67 | ArgumentParser CLI options |
| `VPhoneVM.swift` | 180 | VM configuration and lifecycle |
| `VPhoneHardwareModel.swift` | 32 | PV=3 hardware model creation |
| `VPhoneKeyHelper.swift` | 273 | Keyboard input / ASCII typing |
| `VPhoneMenuController.swift` | 141 | macOS menu bar |
| `VPhoneVMView.swift` | 146 | Touch input translation |
| `VPhoneWindowController.swift` | 38 | NSWindow management |
| `VPhoneError.swift` | 24 | Error types |

**Python — Patchers (scripts/patchers/)**

| File | Lines | Purpose |
|------|-------|---------|
| `__init__.py` | 5 | Module exports |
| `kernel.py` | 1,421 | Dynamic kernel patcher (25 patches) |
| `kernel_jb.py` | 2,172 | JB kernel patcher (~160 patches) |
| `iboot.py` | 470 | iBoot dynamic patcher (iBSS/iBEC/LLB) |
| `iboot_jb.py` | 105 | JB iBoot extension (nonce skip) |
| `txm.py` | 185 | TXM patcher (trustcache bypass) |
| `txm_jb.py` | 335 | JB TXM patcher (~13 patches) |
| `cfw.py` | 1,108 | CFW binary patcher (userland) |

**Python — Pipeline Scripts (scripts/)**

| File | Lines | Purpose |
|------|-------|---------|
| `fw_manifest.py` | 222 | Hybrid BuildManifest generator |
| `fw_patch.py` | 314 | Boot chain patcher (6 components) |
| `fw_patch_jb.py` | 105 | JB extension patch runner |
| `ramdisk_build.py` | 489 | SSH ramdisk builder |

**Shell Scripts (scripts/)**

| File | Lines | Purpose |
|------|-------|---------|
| `fw_prepare.sh` | 100 | IPSW download/merge |
| `vm_create.sh` | 137 | VM directory creation |
| `ramdisk_send.sh` | 67 | DFU ramdisk loader |
| `cfw_install.sh` | 378 | CFW installation (7 phases) |
| `cfw_install_jb.sh` | 214 | JB CFW extensions (3 phases) |
| `setup_venv.sh` | 84 | Python venv setup (macOS) |
| `setup_venv_linux.sh` | 58 | Python venv setup (Linux) |
| `setup_libimobiledevice.sh` | 155 | Build libimobiledevice toolchain |

---

## 2. Architecture Overview

### 2.1 System Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                           Makefile                                  │
│                    (single entry point)                             │
└──────┬───────────┬──────────┬────────────┬──────────┬──────────────┘
       │           │          │            │          │
  ┌────▼────┐ ┌────▼────┐ ┌──▼──────┐ ┌───▼───┐ ┌───▼──────┐
  │  Build  │ │   VM    │ │Firmware │ │Ramdisk│ │   CFW    │
  │  Swift  │ │ Manage  │ │Pipeline │ │ Build │ │ Install  │
  └────┬────┘ └────┬────┘ └──┬──────┘ └───┬───┘ └───┬──────┘
       │           │         │            │          │
       ▼           ▼         ▼            ▼          ▼
  vphone-cli   vm_create  fw_prepare  ramdisk_    cfw_install
  (Swift bin)  (zsh)      (bash)      build.py    (zsh+SSH)
                           │          (Python)
                           ▼
                       fw_patch.py ──► patchers/
                       (Python)       kernel.py
                                      iboot.py
                                      txm.py
                                      cfw.py
```

### 2.2 Language Distribution

```
Python:  6,931 lines  (74.0%)  ← firmware patching engine
Shell:   1,193 lines  (12.7%)  ← pipeline orchestration
Swift:   1,015 lines  (10.8%)  ← VM boot tool
Build:     208 lines  ( 2.2%)  ← Makefile + Package.swift
Other:      16 lines  ( 0.2%)  ← entitlements plist
```

Python dominates because the project's core contribution is **dynamic firmware patching** — disassembling ARM64 binaries, finding patch targets by pattern, and assembling replacement instructions.

---

## 3. Swift Application (`sources/vphone-cli/`)

### 3.1 Execution Flow

```
main.swift:6      VPhoneCLI.parseOrExit()
main.swift:8-11   NSApplication.shared → VPhoneAppDelegate → app.run()
                          │
AppDelegate:17            ▼ applicationDidFinishLaunching
AppDelegate:20-27         Install SIGINT handler
AppDelegate:29-36         Task { try await startVM() }
                          │
AppDelegate:40            ▼ startVM()
AppDelegate:65-78         Build VPhoneVM.Options from CLI args
AppDelegate:80            VPhoneVM(options:) → configure VM
                          │
VPhoneVM:25               ▼ init(options:)
VPhoneVM:27               Create PV=3 hardware model
VPhoneVM:31-52            Configure platform (machineID, NVRAM, boot-args)
VPhoneVM:64-65            Set custom ROM (AVPBooter) via Dynamic
VPhoneVM:68-141           Configure all VM subsystems
                          │
AppDelegate:83            ▼ vm.start(forceDFU: cli.dfu)
VPhoneVM:147-158          VZMacOSVirtualMachineStartOptions + forceDFU
                          │
AppDelegate:85-97         ▼ (if GUI mode)
                          Create VPhoneKeyHelper, window, menu
```

### 3.2 VM Configuration Subsystems

`VPhoneVM.swift` configures 11 subsystems in a single `init`:

| Subsystem | API | Line | Notes |
|-----------|-----|------|-------|
| Hardware model | `_VZMacHardwareModelDescriptor` | 27 | PV=3, boardID=0x90, ISA=2 |
| Platform | `VZMacPlatformConfiguration` | 31-52 | Persistent ECID, NVRAM boot-args |
| Boot loader | `VZMacOSBootLoader` + `_setROMURL` | 64-65 | Custom AVPBooter ROM |
| CPU | `VZVirtualMachineConfiguration.cpuCount` | 71 | Default 8 cores |
| Memory | `VZVirtualMachineConfiguration.memorySize` | 72 | Default 8 GB |
| Graphics | `VZMacGraphicsDeviceConfiguration` | 75-82 | 1290x2796 @ 460 PPI |
| Audio | `VZVirtioSoundDeviceConfiguration` | 85-91 | Host input + output |
| Storage | `VZVirtioBlockDeviceConfiguration` | 94-98 | Disk image attachment |
| Network | `VZVirtioNetworkDeviceConfiguration` | 101-103 | NAT |
| Serial | `_VZPL011SerialPortConfiguration` | 106-113 | stdin/stdout interactive |
| Multi-touch | `_VZUSBTouchScreenConfiguration` | 116-119 | USB touch screen |
| Keyboard | `VZUSBKeyboardConfiguration` | 121 | Standard USB |
| GDB stub | `_VZGDBDebugStubConfiguration` | 124 | System-assigned port |
| SEP | `_VZSEPCoprocessorConfiguration` | 127-133 | Storage + ROM + debug |

**Private APIs used (via Dynamic library):**
- `_VZMacHardwareModelDescriptor` — create PV=3 hardware model
- `_setROMURL` — load custom AVPBooter
- `_setDataValue:forNVRAMVariableNamed:` — set NVRAM boot-args
- `_VZPL011SerialPortConfiguration` — PL011 UART serial
- `_VZUSBTouchScreenConfiguration` — USB multi-touch
- `_setMultiTouchDevices` — attach touch devices
- `_VZGDBDebugStubConfiguration` — GDB debug stub
- `_VZSEPCoprocessorConfiguration` — SEP coprocessor
- `_setForceDFU` — force DFU boot mode
- `_setStopInIBootStage1/2` — iBoot breakpoints

### 3.3 Input Pipeline

**Touch input** (`VPhoneVMView.swift`):
```
NSEvent (mouseDown/mouseDragged/mouseUp)
  → normalizeCoordinate() — convert to 0-1 range
  → hitTestEdge() — detect swipe aim (32px threshold)
  → _VZTouch(view:index:phase:location:swipeAim:timestamp:)
  → _VZMultiTouchEvent(touches:)
  → device.sendMultiTouchEvents()
```

Edge codes: Top=1 (Notification Center), Bottom=2 (Home bar), Right=4, Left=8.
Right-click sends Home screen command (`Cmd+H`).

**Keyboard input** (`VPhoneKeyHelper.swift`):

Three pipelines for different key types:

| Pipeline | Method | Use Case |
|----------|--------|----------|
| `_VZKeyEvent` | `sendKeyPress(keyCode:)` | Standard keys (Return, Space, arrows, letters) |
| Modifier combo | `sendVKCombo(modifierVK:keyVK:)` | Cmd+H (Home), Cmd+Space (Spotlight) |
| Vector injection | `sendRawKeyPress(index:)` | Keys with no VK code (Power button = index 0x72) |

The vector injection pipeline (`VPhoneKeyHelper.swift:78-102`) bypasses `_VZKeyEvent` entirely by calling `sendKeyboardEvents:keyboardID:` with a crafted `std::vector<uint64_t>`. Each entry is packed as `(intermediate_index << 32) | is_key_down`.

**ASCII typing** (`VPhoneKeyHelper.swift:184-214`): Types clipboard text character-by-character at 20ms intervals using `asciiToVK()` lookup table (US layout, 95 characters mapped).

### 3.4 Window Management

`VPhoneWindowController.swift` — 38 lines:
- Window size = screen dimensions / scale factor (default: 1290/3 x 2796/3 = 430x932)
- Content aspect ratio locked to prevent distortion
- `VPhoneVMView` set as content view with `capturesSystemKeys = true`

### 3.5 Error Handling

`VPhoneError.swift` — 3 error cases:
- `hardwareModelNotSupported` — PV=3 requirements not met (macOS 15, entitlements, SIP/AMFI)
- `romNotFound(String)` — AVPBooter ROM missing
- `diskNotFound(String)` — disk image missing

### 3.6 Dependencies

| Dependency | Version | Purpose |
|------------|---------|---------|
| `swift-argument-parser` | 1.3.1+ | CLI option parsing |
| `Dynamic` | 1.2.0+ | Runtime dispatch for private APIs |
| `Virtualization.framework` | Linked | Apple VM framework |
| `AppKit.framework` | Linked | GUI (window, menu, events) |

---

## 4. Firmware Patching Engine (`scripts/patchers/`)

This is the technical core of the project: 5,796 lines of Python that dynamically patch ARM64 binaries without hardcoded offsets.

### 4.1 Shared Techniques

All patchers use:
- **Capstone** — ARM64 disassembly for pattern matching
- **Keystone** — ARM64 assembly for generating replacement instructions
- **pyimg4** — IM4P container handling (extract/repackage)

**Pattern finding strategies:**

| Strategy | Description | Used By |
|----------|-------------|---------|
| String anchors | Find string in `__cstring`, trace ADRP+ADD xrefs to find calling code | All patchers |
| Instruction patterns | Match sequences like `cbz`→`mov x0`→`bl` near a string ref | iboot, kernel |
| Unique constants | Find `mov wN, #0xNNNN` with a unique immediate value | txm (0x2446) |
| BL frequency analysis | Count callers of each BL target; identify functions by caller count | kernel (_panic: highest caller count) |
| ADRP index | Pre-built dict mapping ADRP page addresses to all ADRP instruction offsets | kernel (O(1) string ref lookup) |
| BL callers dict | Pre-built dict mapping BL target offsets to all caller offsets | kernel (O(1) function identification) |
| Symbol table | LC_SYMTAB parsing for fileset kext entries | kernel_jb |
| ObjC metadata chain | Follow metaclass refs through `__objc_classrefs` → class → methods | cfw (mobileactivationd) |
| PAC discriminator | Match `movk x17, #disc, lsl #48` to identify vtable entries | kernel_jb (NVRAM) |
| Code cave finder | Scan for UDF (0x00000000) runs to inject shellcode | txm_jb, kernel_jb |

### 4.2 IBootPatcher (`iboot.py` — 470 lines)

Patches iBoot-family binaries: iBSS, iBEC, and LLB. Each mode applies progressively more patches.

**Patch methods:**

| Method | Patches | Anchor | Technique |
|--------|---------|--------|-----------|
| `patch_serial_labels()` | 1 | `"===="` (16+ char run) | Replace serial banner padding |
| `patch_image4_callback()` | 1 | Error code `0x3C2` (iBSS) or `0x3B7` (iBEC/LLB) | NOP `b.ne` + `mov x0` after pattern |
| `patch_boot_args()` | 1 | `"rd=md0"` string | Redirect ADRP+ADD to custom boot-args string |
| `patch_rootfs_bypass()` | 6 | Error codes `0x110`, `0x328` + patterns | NOP/redirect 6 branch sequences |
| `patch_panic_bypass()` | 1 | `"double fault"` string | NOP `cbnz` after string ref pattern |

**Mode-to-patch mapping:**

| Mode | Patches Applied | Total |
|------|----------------|-------|
| `ibss` | serial_labels + image4_callback | 2 |
| `ibec` | serial_labels + image4_callback + boot_args | 3 |
| `llb` | serial_labels + image4_callback + boot_args + rootfs + panic | 6 |

### 4.3 TXMPatcher (`txm.py` — 185 lines)

Single patch: trustcache hash lookup bypass.

**Discovery chain:**
```
Find unique marker: mov w19, #0x2446
  → Scan forward for pattern:
      mov w2, #0x14
      bl  <hash_cmp>
      cbz w0, ...
      tbnz w0, #0x1f, ...
  → Replace BL with: mov x0, #0
```

This forces the trustcache lookup to always return "found", bypassing code signature checks for trust cache entries.

### 4.4 KernelPatcher (`kernel.py` — 1,421 lines)

The largest base patcher. Applies 25 dynamic patches to the PCC vphone600 kernelcache.

**Initialization pipeline:**
1. Parse Mach-O header → extract BASE_VA, segment offsets, section ranges
2. Parse `__PRELINK_INFO` plist → build kext name-to-range mapping
3. Build ADRP page index → `dict[page_addr] = [offset1, offset2, ...]`
4. Build BL callers dict → `dict[target_offset] = [caller1, caller2, ...]`
5. Find `_panic` function → highest BL caller count + `"panic"` string ref validation

**25 Base Patches (grouped by subsystem):**

| # | Method | Subsystem | Target | Technique |
|---|--------|-----------|--------|-----------|
| 1 | `patch_apfs_root_seal` | APFS | Sealed volume check | NOP `tbnz w8, #5` |
| 2 | `patch_apfs_seal_broken` | APFS | Seal broken panic | Redirect conditional branch |
| 3 | `patch_rootvp_auth` | APFS | Root VP auth panic | Redirect conditional branch |
| 4-5 | `patch_amfi_launch_constraints` | AMFI | `proc_check_launch_constraints` | `mov w0, #0; ret` (2 functions) |
| 6-7 | `patch_debugger` | Debug | `PE_i_can_has_debugger` | `mov x0, #1; ret` (symbol or pattern) |
| 8 | `patch_txm_post_validation` | TXM | Post-validation tbnz | NOP `tbnz` |
| 9 | `patch_post_validation_cs` | Code signing | CS validation | `cmp w0, w0` (always equal) |
| 10-11 | `patch_dyld_policy` | dyld | Two policy BL calls | `mov w0, #1` (override return) |
| 12 | `patch_apfs_graft_hash` | APFS | Root hash validation | NOP BL |
| 13 | `patch_apfs_vfsop_mount` | APFS | `current_thread` check | `cmp x0, x0` |
| 14 | `patch_apfs_mount_upgrade` | APFS | Upgrade checks | NOP `tbnz` |
| 15 | `patch_fsioc_graft` | APFS | Graft validation | NOP BL |
| 16-25 | `patch_sandbox_hooks` | Sandbox | 10 MACF hook functions | `mov w0, #0; ret` via mac_policy_ops table |

**Sandbox hook discovery:**
```
"Sandbox" string → mac_policy_conf struct → ops table pointer
  → Iterate 114 ops slots → each non-null slot is a hook function
  → For each target hook: resolve → patch with mov w0, #0; ret
```

10 specific ops-table indices are patched (out of 114 possible).

### 4.5 CFW Patcher (`cfw.py` — 1,108 lines)

CLI-based patcher for iPhone userland binaries. 7 commands:

| Command | Target Binary | Technique | Purpose |
|---------|--------------|-----------|---------|
| `cryptex-paths` | BuildManifest.plist | Plist parsing | Extract SystemOS/AppOS DMG paths |
| `patch-seputil` | seputil | String replacement | `/%s.gl` → `/AA.gl` (gigalocker UUID) |
| `patch-launchd-cache-loader` | launchd_cache_loader | NOP branch | Bypass cache validation |
| `patch-mobileactivationd` | mobileactivationd | Return override | `should_hactivate` → always true |
| `patch-launchd-jetsam` | launchd | Branch redirect | Skip jetsam panic guard |
| `inject-daemons` | launchd.plist | Plist injection | Add bash/dropbear/trollvnc daemons |
| `inject-dylib` | Any Mach-O | LC_LOAD_DYLIB injection | Insert load command (optool replacement) |

**mobileactivationd patching** is notable for its ObjC metadata chain traversal:
```
Find "should_hactivate" string
  → Trace through __objc_methnames → __objc_selrefs → __objc_methtype
  → Find method in __objc_const method list
  → Extract IMP address from method descriptor
  → Patch function body: mov w0, #1; ret
```

### 4.6 JB Extension Patchers

Three files extend the base patchers for jailbreak functionality:

**IBootJBPatcher** (`iboot_jb.py` — 105 lines):
- 1 additional patch: `patch_skip_generate_nonce()` — bypass nonce generation in iBSS
- Anchored on `"boot-nonce"` string, matches `tbz`→`bl`→`mov`→`bl` pattern

**TXMJBPatcher** (`txm_jb.py` — 335 lines):
- ~13 additional patches across 6 methods:
  - `selector24_hashcmp` — BL → `mov x0, #0` for hash comparison calls
  - `selector24_a1_path` — NOP `b.lo` + `cbz` branches
  - `get_task_allow` — Force entitlement to true
  - `selector42_29` — Shellcode injection via code cave + branch redirect
  - `debugger_entitlement` — Force debugger entitlement true
  - `developer_mode` — NOP `tbz`/`tbnz` checks
- Uses UDF cave finder for shellcode injection

**KernelJBPatcher** (`kernel_jb.py` — 2,172 lines):
- ~160 additional patches from 22 methods
- 3 patch groups:
  - **Group A** (complex): AMFI trustcache, execve hooks, task conversion, sandbox hook redirect
  - **Group B** (string-anchored): 19 methods with simple NOP/return patches
  - **Group C** (shellcode): 4 methods requiring code cave allocation and branch encoding
- 19 of 22 methods passing; 3 remaining failures documented in `researchs/kernel_jb_remaining_patches.md`

---

## 5. Pipeline Scripts

### 5.1 Firmware Preparation (`fw_prepare.sh` — 100 lines)

Downloads and merges two IPSWs into a hybrid firmware directory:

```
Input:
  iPhone17,3_26.1_23B85_Restore.ipsw (iPhone)
  PCC vresearch101ap IPSW (cloudOS)

Steps:
  1. Download/copy both IPSWs to VM_DIR
  2. Extract iPhone IPSW → iPhone*_Restore/
  3. Extract cloudOS IPSW → CloudOS_Restore/
  4. Copy cloudOS components into iPhone dir:
     - kernelcache.*
     - Firmware/{agx,all_flash,ane,dfu,pmp}/*
     - *.dmg, trustcache files
  5. Preserve BuildManifest-iPhone.plist for Cryptex paths
  6. Run fw_manifest.py → generate hybrid BuildManifest.plist + Restore.plist
  7. Delete CloudOS_Restore/

Output:
  VM_DIR/iPhone17,3_26.1_23B85_Restore/ (hybrid)
```

### 5.2 Firmware Manifest (`fw_manifest.py` — 222 lines)

Generates a hybrid BuildManifest.plist + Restore.plist for the vphone600 virtual device.

**Identity merging logic:**
```
Source identities:
  PROD  = vresearch101ap release    → boot chain (LLB, iBSS, iBEC), SPTM, ramdisk
  RES   = vresearch101ap research   → iBoot, TXM
  VP    = vphone600ap release       → DeviceTree, SEP, RestoreKernelCache, RecoveryMode
  VPR   = vphone600ap research      → KernelCache (patched)
  I_ERASE = iPhone erase            → OS, SystemVolume, StaticTrustCache, metadata

Output: Single identity — "Darwin Cloud Customer Erase Install (IPSW)"
  - 20-21 manifest components drawn from 5 source identities
  - BoardID=0x90, ChipID=0xFE01, DeviceClass=vresearch101ap
```

### 5.3 Firmware Patching (`fw_patch.py` — 314 lines)

Orchestrates patching of 6 boot chain components:

| # | Component | Patcher | Format | Patches |
|---|-----------|---------|--------|---------|
| 1 | AVPBooter | Inline (4 bytes) | Raw binary | 1 — DGST `mov x0, #0` |
| 2 | iBSS | `IBootPatcher('ibss')` | IM4P | 2 |
| 3 | iBEC | `IBootPatcher('ibec')` | IM4P | 3 |
| 4 | LLB | `IBootPatcher('llb')` | IM4P | 6 |
| 5 | TXM | `TXMPatcher()` | IM4P | 1 |
| 6 | KernelCache | `KernelPatcher()` | Raw (Mach-O) | 25 |

**IM4P handling:** Automatically detects IM4P containers, extracts payload (handling LZFSE/LZSS compression via PAYP metadata), patches the raw binary, then repackages. PAYP (compression metadata) is preserved for components that need it.

### 5.4 JB Patch Extension (`fw_patch_jb.py` — 105 lines)

Runs `fw_patch.py` first (all 6 base components), then applies JB-specific patches:
- TXM: `TXMJBPatcher` (~13 additional patches)
- Kernelcache: `KernelJBPatcher` (~160 additional patches)

### 5.5 Ramdisk Builder (`ramdisk_build.py` — 489 lines)

Builds a signed SSH ramdisk for DFU restore:

```
Steps:
  1. Extract IM4M from SHSH blob (previously fetched via idevicerestore -t)
  2. For each of 8 components (iBSS, iBEC, SPTM, DeviceTree, SEP, TXM, kernel, ramdisk):
     - Extract from IM4P container
     - Sign with IM4M manifest → IMG4
  3. For ramdisk specifically:
     - Extract base DMG from IM4P
     - Create 254 MB APFS volume
     - Mount → inject SSH tools from resources/ramdisk_input.tar.zst
     - Re-sign all injected Mach-Os with ldid + signcert.p12
     - Build trustcache from signed binaries
     - Package ramdisk + trustcache as IMG4

Output: Ramdisk/ directory with 8 signed IMG4 files
```

### 5.6 Ramdisk Sender (`ramdisk_send.sh` — 67 lines)

8-step DFU boot sequence via irecovery:

```
1. iBSS          → (auto-boot)
2. iBEC          → go
3. SPTM          → firmware
4. TXM           → firmware
5. trustcache    → firmware
6. ramdisk       → ramdisk (+ 2s sleep)
7. DeviceTree    → devicetree
8. SEP + kernel  → firmware, bootx
```

### 5.7 CFW Installer (`cfw_install.sh` — 378 lines)

7-phase custom firmware installation over SSH to the ramdisk:

| Phase | Action | Tool |
|-------|--------|------|
| 1 | Decrypt + mount Cryptex SystemOS and AppOS DMGs | `ipsw`/`aea` |
| 2 | Patch seputil (gigalocker UUID) | `cfw.py patch-seputil` |
| 3 | Install GPU driver (AppleParavirtGPUMetalIOGPUFamily) | `scp` |
| 4 | Install iosbinpack64 (jailbreak tools) | `tar` over SSH |
| 5 | Patch launchd_cache_loader | `cfw.py patch-launchd-cache-loader` |
| 6 | Patch mobileactivationd | `cfw.py patch-mobileactivationd` |
| 7 | Install LaunchDaemons (bash, dropbear SSH, trollvnc) | `cfw.py inject-daemons` |

All phases are idempotent — patches from `.bak` backups.

### 5.8 JB CFW Installer (`cfw_install_jb.sh` — 214 lines)

Runs base CFW installer with `CFW_SKIP_HALT=1`, then adds 3 JB phases:

| Phase | Action |
|-------|--------|
| JB-1 | Patch launchd: jetsam guard bypass + inject `launchdhook.dylib` via `LC_LOAD_DYLIB` |
| JB-2 | Extract procursus bootstrap to `/mnt5/<hash>/jb-vphone/` |
| JB-3 | Deploy BaseBin hooks (`systemhook.dylib`, `launchdhook.dylib`, `libellekit.dylib`) to `/mnt1/cores/` |

---

## 6. VM Creation & Boot

### 6.1 VM Directory Structure (`vm_create.sh` — 137 lines)

```
VM_DIR/
├── AVPBooter.vresearch1.bin       # ROM (from Virtualization.framework)
├── AVPSEPBooter.vresearch1.bin    # SEP ROM (from Virtualization.framework)
├── Disk.img                       # Sparse disk image (default 64 GB)
├── SEPStorage                     # SEP storage (512 KB flat file)
├── nvram.bin                      # NVRAM (created/overwritten each boot)
├── machineIdentifier.bin          # Persistent ECID (created on first boot)
└── iPhone17,3_26.1_23B85_Restore/ # Hybrid firmware (after fw_prepare)
    ├── BuildManifest.plist        # Generated hybrid manifest
    ├── Restore.plist              # Generated device map
    ├── kernelcache.release.vphone600
    ├── kernelcache.research.vphone600
    ├── Firmware/
    │   ├── all_flash/             # LLB, DeviceTree, SEP, SPTM, etc.
    │   ├── dfu/                   # iBSS, iBEC
    │   ├── agx/                   # GPU firmware
    │   ├── ane/                   # ANE firmware
    │   └── pmp/                   # PMP firmware
    └── Ramdisk/                   # (after ramdisk_build)
        ├── ibss.img4
        ├── ibec.img4
        ├── sptm.img4
        ├── txm.img4
        ├── devicetree.img4
        ├── sep.img4
        ├── kernelcache.img4
        ├── ramdisk.img4
        └── trustcache.img4
```

### 6.2 Boot Modes

**GUI boot** (`make boot`):
- Full window with VZVirtualMachineView
- Touch input via mouse, keyboard via USB HID
- Menu bar with key shortcuts
- Serial output on stdout

**DFU boot** (`make boot_dfu`):
- Headless (`--no-graphics --dfu`)
- VM enters DFU mode, waits for irecovery
- Used for firmware restore workflow

### 6.3 NVRAM Configuration

Set at `VPhoneVM.swift:55-61`:
```
boot-args = "serial=3 debug=0x104c04"
```
- `serial=3` — enable serial output on all ports
- `debug=0x104c04` — debug flags for kernel debugging

---

## 7. Build System

### 7.1 Makefile Targets (180 lines)

```
Setup:              setup_venv, setup_libimobiledevice
Build:              build, install, clean
VM management:      vm_new, boot, boot_dfu
Firmware pipeline:  fw_prepare, fw_patch, fw_patch_jb
Restore:            restore_get_shsh, restore
Ramdisk:            ramdisk_build, ramdisk_send
CFW:                cfw_install, cfw_install_jb
```

**Build process** (`Makefile:82-90`):
```
swift build -c release
codesign --force --sign - --entitlements sources/vphone.entitlements <binary>
```

The binary **must** be signed with 5 private entitlements to use PV=3 virtualization. `swift build` alone produces an unsigned binary that will fail at runtime with `hardwareModelNotSupported`.

**Environment** (`Makefile:24`):
```
PATH := .limd/bin : .venv/bin : .build/release : $PATH
```
Project-local binaries take precedence over system ones.

### 7.2 Dependencies

| Tool | Source | Purpose |
|------|--------|---------|
| Swift 6.0 + SwiftPM | Xcode / system | Build vphone-cli binary |
| codesign | macOS | Entitlement signing |
| Python 3 + venv | System | Firmware patching |
| capstone | pip | ARM64 disassembly |
| keystone-engine | pip + manual dylib | ARM64 assembly |
| pyimg4 | pip | IM4P container handling |
| idevicerestore | Built from source | SHSH blob fetch + restore |
| irecovery | Built from source | DFU communication |
| ipsw | External | Cryptex DMG decryption |
| aea | External | Apple Encrypted Archive extraction |
| ldid | External | Code signing (ramdisk) |

### 7.3 libimobiledevice Build (`setup_libimobiledevice.sh` — 155 lines)

Builds the entire libimobiledevice toolchain from source, statically linked:

```
Build order:
  1. OpenSSL (latest tag)
  2. libplist
  3. libimobiledevice-glue
  4. libusbmuxd
  5. libtatsu
  6. libimobiledevice
  7. libirecovery (with PCC VM device registration patch)
  8. libzip (CMake)
  9. idevicerestore

Output: .limd/bin/{idevicerestore, irecovery, ...}
```

Notable: libirecovery is patched to register `iPhone99,11 / vresearch101ap` as a known device (PR #150 upstream).

---

## 8. Firmware Hybrid Architecture

### 8.1 Component Origin Map

The firmware merges three Apple sources:

```
PCC vresearch101ap (boot chain)     PCC vphone600ap (runtime)     iPhone 17,3 (OS)
├── AVPBooter [patched]             ├── DeviceTree                ├── OS image
├── LLB [patched]                   ├── SEP firmware              ├── SystemVolume
├── iBSS [patched]                  ├── KernelCache [patched]     ├── StaticTrustCache
├── iBEC [patched]                  ├── RestoreKernelCache        └── Metadata
├── SPTM                            └── RecoveryMode
├── TXM [patched]
└── Ramdisk + TrustCache
```

**Why the split?**
- **vresearch101ap** boot chain — matches DFU hardware identity (boardID=0x90, chipID=0xFE01)
- **vphone600ap** runtime — its DeviceTree sets `dt=1`, enabling boot without system keybag
- **iPhone OS** — provides the actual iOS userland

### 8.2 Boot Chain (Base)

```
AVPBooter (ROM, patched: DGST bypass)
  → LLB (patched: serial + image4 + boot-args + rootfs + panic — 6 patches)
    → iBSS (patched: serial + image4 — 2 patches)
      → iBEC (patched: serial + image4 + boot-args — 3 patches)
        → SPTM (unpatched) + TXM (patched: trustcache bypass — 1 patch)
          → KernelCache (patched: 25 patches — APFS, AMFI, sandbox, debug)
            → Ramdisk (SSH-injected)
              → iOS userland (CFW: seputil, launchd_cache_loader, mobileactivationd, daemons)
```

### 8.3 Boot Chain (Jailbreak)

```
AVPBooter (ROM, patched: DGST bypass)
  → LLB (patched: 6 base)
    → iBSS (patched: 2 base + 1 JB nonce skip)
      → iBEC (patched: 3 base)
        → SPTM + TXM (patched: 1 base + ~13 JB — CS bypass, entitlements, dev mode)
          → KernelCache (patched: 25 base + ~160 JB — trustcache, sandbox, task/VM, kcall)
            → Ramdisk (SSH-injected)
              → iOS userland (CFW + jetsam fix + procursus bootstrap + BaseBin hooks)
```

### 8.4 Patch Count Summary

| Component | Base Patches | JB Patches | Total |
|-----------|-------------|------------|-------|
| AVPBooter | 1 | 0 | 1 |
| iBSS | 2 | +1 | 3 |
| iBEC | 3 | 0 | 3 |
| LLB | 6 | 0 | 6 |
| TXM | 1 | +13 | 14 |
| KernelCache | 25 | +~160 | ~185 |
| CFW (userland) | 4 | +1 | 5 |
| **Total** | **42** | **+~175** | **~217** |

---

## 9. End-to-End Workflow

Complete sequence from zero to running virtual iPhone:

```
# One-time setup
make setup_venv                    # Python env with capstone/keystone/pyimg4
make setup_libimobiledevice        # Build idevicerestore/irecovery from source

# Build Swift binary
make build                         # swift build + codesign with entitlements

# Create VM directory
make vm_new                        # Sparse disk, SEP storage, copy ROMs

# Firmware assembly
make fw_prepare                    # Download + merge iPhone + cloudOS IPSWs
make fw_patch                      # Patch 6 boot chain components (42 patches)
  # OR: make fw_patch_jb           # Base patches + JB extensions (~217 patches)

# DFU restore
make boot_dfu                      # Boot VM in DFU mode
make restore_get_shsh              # Fetch SHSH blob from virtual device
make restore                       # idevicerestore (writes OS to disk)

# Ramdisk (post-restore)
make boot_dfu                      # Reboot into DFU
make ramdisk_build                 # Build signed SSH ramdisk
make ramdisk_send                  # Load 8 components via irecovery → boot

# CFW installation (over SSH to ramdisk)
make cfw_install                   # 7 phases: Cryptex mount, patches, daemons
  # OR: make cfw_install_jb        # Base + JB phases (jetsam, procursus, BaseBin)

# Normal boot
make boot                          # Boot with GUI — virtual iPhone running
```

---

## 10. Research Documents

7 research documents in `researchs/`:

| Document | Lines | Content |
|----------|-------|---------|
| `binary_patches_kernelcache.md` | 122 | Verification that dynamic patcher produces byte-identical output to legacy hardcoded patches |
| `build_manifest.md` | 179 | BuildManifest.plist structure research — multi-source component comparison, TSS requirements |
| `erase_install_component_origins.md` | 180 | Component source tracing — which IPSW provides each firmware component and why |
| `jailbreak_patches.md` | 204 | Base vs JB patch comparison tables with implementation status |
| `kernel_fairplay_kexts.md` | 74 | FairPlay IOKit extensions analysis — AvpFairPlayDriver + FairPlayIOKit in PCC kernel |
| `kernel_jb_remaining_patches.md` | 443 | Detailed analysis of 3 failing JB kernel patches with proposed resolution strategies |
| `keyboard_event_pipeline.md` | 252 | Reverse engineering of Virtualization.framework keyboard event pipeline (macOS 26.2) |

---

## 11. Security & Research Context

### 11.1 What This Tool Does

vphone-cli boots Apple's Private Cloud Compute (PCC) research VMs as virtual iPhones for security research. PCC VMs are Apple's official mechanism for security researchers to audit the hardware and software that powers Apple Intelligence cloud processing.

### 11.2 Private API Usage

The tool uses 14+ private Virtualization.framework APIs accessed via the Dynamic library's runtime dispatch (no ObjC bridging headers needed):

| API | Purpose | Source File |
|-----|---------|-------------|
| `_VZMacHardwareModelDescriptor` | Create PV=3 hardware model | `VPhoneHardwareModel.swift:18` |
| `_hardwareModelWithDescriptor` | Instantiate hardware model | `VPhoneHardwareModel.swift:23-24` |
| `_setROMURL` | Load custom AVPBooter | `VPhoneVM.swift:65` |
| `_setDataValue:forNVRAMVariableNamed:` | Set NVRAM boot-args | `VPhoneVM.swift:57-58` |
| `_VZPL011SerialPortConfiguration` | PL011 UART serial | `VPhoneVM.swift:106` |
| `_VZUSBTouchScreenConfiguration` | USB touch screen | `VPhoneVM.swift:116` |
| `_setMultiTouchDevices` | Attach touch to config | `VPhoneVM.swift:117` |
| `_VZGDBDebugStubConfiguration` | GDB debug stub | `VPhoneVM.swift:124` |
| `_setDebugStub` | Attach GDB to config | `VPhoneVM.swift:124` |
| `_VZSEPCoprocessorConfiguration` | SEP coprocessor | `VPhoneVM.swift:127` |
| `_setCoprocessors` | Attach SEP to config | `VPhoneVM.swift:131` |
| `_setForceDFU` | Force DFU boot | `VPhoneVM.swift:149` |
| `_multiTouchDevices` | Access touch devices | `VPhoneVMView.swift:16` |
| `_VZTouch` | Create touch event | `VPhoneVMView.swift:73` |
| `_VZMultiTouchEvent` | Create multi-touch event | `VPhoneVMView.swift:87` |
| `_VZKeyEvent` | Create keyboard event | `VPhoneKeyHelper.swift:42-43` |
| `_keyboards` | Access keyboard array | `VPhoneKeyHelper.swift:14` |
| `sendKeyboardEvents:keyboardID:` | Raw vector injection | `VPhoneKeyHelper.swift:100` |

### 11.3 Required Entitlements

5 entitlements in `sources/vphone.entitlements`:
1. `com.apple.security.virtualization` — basic VM access
2. `com.apple.private.virtualization` — private APIs (bit 1)
3. `com.apple.private.virtualization.security-research` — PV=3 support (bit 4)
4. `com.apple.vm.networking` — VM NAT networking
5. `com.apple.security.get-task-allow` — debugger attachment

The framework checks `(entitlements & 0x12) != 0` for PV=3 validity (`VPhoneHardwareModel.swift:8-11`).

### 11.4 Host Requirements

- macOS 15+ (Sequoia) — minimum for PV=3 hardware model
- SIP disabled — required for private entitlements
- AMFI disabled — required for ad-hoc signed binary with private entitlements
- Apple Silicon (arm64) — Virtualization.framework requirement
