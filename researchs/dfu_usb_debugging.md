# DFU USB Device Detection — Debugging Session

**Date:** 2026-03-02
**Platform:** macOS 26.3 (Build 25D125), MacBook Pro (J704AP)
**Goal:** Boot VM in DFU mode and connect with irecovery/idevicerestore for restore flow

---

## Problem

The VM starts in DFU mode successfully (vphone-cli reports "VM started in DFU mode — connect with irecovery"), but **irecovery and idevicerestore cannot detect the device**. The restore pipeline is completely blocked at this step.

## Environment

| Item | Value |
|------|-------|
| macOS | 26.3 (25D125) |
| Platform | J704AP (MacBook Pro) |
| SIP | Fully disabled (`csrutil status` → "disabled") |
| csrutil allow-research-guests | Enabled (done from Recovery OS) |
| vphone-cli | Built from source, signed with entitlements |
| irecovery | `.limd/bin/irecovery` — patched libirecovery (vresearch101ap registered) |
| idevicerestore | `.limd/bin/idevicerestore` 1.0.0-git-405fcd1 (libirecovery 1.3.1-dirty, libtatsu 1.0.5) |

## VM Boot Output (Terminal 1)

```
=== vphone-cli ===
ROM   : ./AVPBooter.vresearch1.bin
Disk  : ./Disk.img
NVRAM : ./nvram.bin
MachID: ./machineIdentifier.bin
CPU   : 8
Memory: 8192 MB
Screen: 1290x2796 @ 460 PPI (scale 3.0x)
SEP   : enabled
  storage: ./SEPStorage
  rom    : ./AVPSEPBooter.vresearch1.bin

[vphone] PV=3 hardware model: isSupported = true
[vphone] Loaded machineIdentifier (ECID stable)
[vphone] NVRAM boot-args: serial=3 debug=0x104c04
[vphone] PL011 serial port attached (interactive)
[vphone] Configuration validated
[vphone] Starting DFU...
[vphone] VM started in DFU mode — connect with irecovery
```

**CONFIRMED: NO serial output after this line.** Terminal 1 stays on this line with a blinking cursor — no AVPBooter, iBSS, or any boot chain text. The PL011 serial port is attached to stdout but the ROM is completely silent. This means AVPBooter is NOT executing or is crashing before producing any output.

## What We Tried

### 1. irecovery direct connection

```
.limd/bin/irecovery -q
ERROR: Unable to connect to device
```

**Finding:** irecovery cannot find any DFU device at all.

### 2. idevicerestore SHSH fetch + restore

```
make restore_get_shsh
# → idevicerestore -e -y ./iPhone*_Restore -t
# → "Unable to discover device mode. Please make sure a device is attached."

make restore
# → idevicerestore -e -y ./iPhone*_Restore
# → "Unable to discover device mode. Please make sure a device is attached."
```

**Finding:** idevicerestore also cannot detect the device. Same root cause as irecovery.

### 3. usbmuxd device enumeration

```
.limd/bin/idevice_id -l
(empty output — no devices)
```

**Finding:** usbmuxd sees zero devices. The VM is not registering on the host's USB/device bus at all.

### 4. IOKit/ioreg search for VM USB device

```
ioreg -p IOService -l | grep -i -A5 "vresearch\|DFU\|AppleUSBVMHost"
```

**Finding:** No matches for `vresearch`, `DFU` (as a device), or `AppleUSBVMHost` in the IOService plane. The only DFU-related string found was `sstate,button_dfu_recover` which is the physical Mac's PMU fault name — unrelated to the VM.

### 5. Virtualization.framework system logs

```
log show --last 60s --predicate 'subsystem == "com.apple.Virtualization"' --info --debug --style compact
```

**Finding:** ZERO log entries. Even with `--info --debug`, Virtualization.framework produced no logs at all during the VM's DFU boot. This is abnormal — the framework should log something during VM lifecycle.

### 6. usbmuxd HUP signal + re-enumerate

```
sudo killall -HUP usbmuxd 2>/dev/null; .limd/bin/idevice_id -l
(empty output)
```

**Finding:** Even after signaling usbmuxd to re-scan, no devices appear.

### 7. AMFI boot-args verification

```
nvram boot-args
boot-args	amfi_get_out_of_my_way=1 -v
```

**Finding:** AMFI is disabled via boot-args. Both SIP and AMFI are off.

### 8. system_profiler USB bus scan

```
system_profiler SPUSBDataType | grep -iE 'dfu|vresearch|appleusb|vmhost|virtualization'
(empty output — no matches)
```

**Finding:** No DFU, vresearch, or VM-related USB devices on any bus.

### 9. ioreg IOUSB plane search

```
ioreg -p IOUSB -l | grep -iE 'dfu|vresearch|vendor|product|appleusbvmhost'
(only IOKitDiagnostics dump — no actual DFU/VM USB device entries)
```

**Finding:** The IOUSB registry plane has no VM-related USB devices. Only the physical Mac's USB controllers and their diagnostics.

### 10. Live log stream (Virtualization + vphone process)

```
log stream --predicate '(subsystem CONTAINS "Virtualization" OR process CONTAINS "vphone")' \
  --info --debug --style compact | head -30
```

**Finding:** Ran for 60+ seconds while VM was in DFU mode. **ZERO Virtualization.framework logs.** The only vphone-cli logs were `com.apple.launchservices` noise from the NSApplication run loop (app name change notifications for unrelated apps like Grammarly, AutoFill). No framework-level VM lifecycle, DFU, or USB-related messages at all.

The vphone-cli process IS alive (PID 1974) and has been running for ~5 minutes. The NSApplication run loop is active. But the Virtualization.framework is completely silent.

### 11. csrutil status verification

```
csrutil status
System Integrity Protection status: disabled.
```

**Finding:** SIP is fully disabled (more permissive than just `allow-research-guests`). This should not be a blocker.

### 12. git pull conflict on VPhoneVM.swift

```
git pull
# → error: Your local changes to the following files would be overwritten by merge:
#     sources/vphone-cli/VPhoneVM.swift
# → Aborting
```

**Finding:** There are uncommitted local changes to `VPhoneVM.swift`. The user built with their LOCAL version, not the latest from `main`. The upstream `main` has been updated (592c3e1..4768822). This could mean the user is running an older or modified VM configuration that doesn't match the latest tested code.

---

## Completed Checks

- [x] Serial output in Terminal 1 — **CONFIRMED SILENT.** No text after "VM started in DFU mode". ROM is not executing.
- [x] AMFI disabled — confirmed via `nvram boot-args`
- [x] VM process alive — PID 1974, running 5+ minutes, NSApplication run loop active
- [x] system_profiler USB — no VM USB devices
- [x] ioreg IOUSB plane — no VM USB devices
- [x] Live Virtualization.framework logs — ZERO entries (only LaunchServices noise)
- [x] SIP disabled — confirmed

## Not Yet Tried

- [ ] **Resolve git pull conflict** — `VPhoneVM.swift` has local changes. Need to stash/commit, pull latest `main`, rebuild, and test again. **This is the #1 priority** since the README confirms Mac16,12 + macOS 26.3 is a tested config.
- [ ] Try `make boot` (non-DFU, GUI mode) — confirms whether the VM boots at all
- [ ] `git diff sources/vphone-cli/VPhoneVM.swift` — see what local changes exist
- [ ] Check if macOS 26 changed Virtualization.framework subsystem name for logs
- [ ] Test on macOS 15 (Sequoia) to rule out macOS 26-specific regression
- [ ] Check if `_setForceDFU` private API behavior changed on macOS 26
- [ ] Check if VM needs `VZUSBControllerConfiguration` or similar for USB device exposure
- [ ] Dump Virtualization.framework private headers on macOS 26 vs 15 to diff USB/DFU-related APIs
- [ ] Framework instrumentation: add return value logging around Dynamic private API calls

## Analysis

### Key Evidence Summary

| Check | Result | Implication |
|-------|--------|-------------|
| Serial output (Terminal 1) | **Silent** — no text after "VM started" | AVPBooter ROM is NOT executing |
| USB bus (system_profiler) | Empty | No virtual USB device created |
| IOUSB plane (ioreg) | Empty | No virtual USB device in IOKit |
| Virtualization.framework logs | **ZERO entries** | Framework may not be actively managing the VM |
| vphone-cli process | Alive (PID 1974, 5+ min) | Swift-level start() succeeded but guest isn't running |
| LaunchServices logs | Active (app run loop working) | NSApplication event loop is fine |
| SIP + AMFI | Both disabled | Not a permissions issue |
| VPhoneVM.swift | **Has local uncommitted changes** | May be running modified/broken config |
| git pull | Blocked by local changes | Not on latest tested code |

### Root Cause Hypotheses (revised, ordered by likelihood)

1. **Local VPhoneVM.swift changes broke the configuration** — The user has uncommitted local changes to `VPhoneVM.swift` and `git pull` fails because of them. The README confirms Mac16,12 + macOS 26.3 is a tested environment, so the latest `main` should work. The local changes may have broken a critical private API call (e.g., `_setForceDFU`, hardware model setup, or VM configuration). **This is the most likely cause** and the easiest to test — just stash changes, pull, rebuild, and retry.

2. **AVPBooter ROM is wrong version or missing** — The `vm/AVPBooter.vresearch1.bin` file may be from a different macOS version than 26.3. The ROM is copied from `/System/Library/Frameworks/Virtualization.framework/` during `make vm_new`. If the VM directory was created on an older macOS version, the ROM may be incompatible with the current framework. Fix: re-run `make vm_new` to get fresh ROMs.

3. **Private API `_setForceDFU` silently failing** — Dynamic library returns nil/false on method mismatch instead of crashing. The VM "starts" but without DFU mode active, and without DFU mode the guest doesn't enter the USB DFU state. The silent serial output supports this — if DFU isn't set, AVPBooter may try a normal boot and fail because there's no OS on disk.

4. **Virtualization.framework subsystem changed on macOS 26** — The zero framework logs could mean the subsystem name changed from `com.apple.Virtualization` to something else. Less likely to be root cause but would explain the missing diagnostic data.

5. **macOS 26 requires new VM configuration for DFU USB** — New API required that the current code doesn't use. Least likely since README says 26.3 is tested.

### Key Architectural Context

The VM → irecovery connection path:

```
VM (DFU mode via _setForceDFU)
  → AVPBooter ROM executes iBSS in DFU state
    → Device identifies on virtual USB as (BoardID=0x90, ChipID=0xFE01)
      → Host macOS kernel sees virtual USB DFU device
        → usbmuxd/libusbmuxd enumerates it
          → libirecovery (patched) recognizes vresearch101ap
            → irecovery/idevicerestore can communicate
```

**The break is between step 1 and 2** — the VM process starts but the host never sees any USB device. Either the ROM isn't running, or the virtual USB channel isn't being created.

### libirecovery Patch (confirmed applied)

The patch adds PCC VM device recognition:
```c
{ "iPhone99,11", "vresearch101ap", 0x90, 0xFE01, "iPhone 99,11" },
```

This is applied during `make setup_libimobiledevice` and the binary at `.limd/bin/irecovery` is the patched version. This is NOT the issue — the device isn't even reaching the point where libirecovery would need to identify it.

## Recommended Next Steps (Priority Order)

### Step 1: Get on latest code (5 min)

The local `VPhoneVM.swift` changes are the most likely culprit. The README says Mac16,12 + macOS 26.3 is tested.

```bash
cd ~/vphone-cli
git diff sources/vphone-cli/VPhoneVM.swift   # check what changed
git stash                                     # save local changes
git pull                                      # get latest main
make clean && make build                      # rebuild
make boot_dfu                                 # test again
```

If `irecovery -q` works after this, the local changes were the problem. Recover them with `git stash pop` and diff to find the breaking change.

### Step 2: Try GUI boot (2 min)

If Step 1 doesn't fix it, test whether the VM boots at ALL:

```bash
make boot    # GUI mode, no DFU
```

- If you see serial output and/or a window → ROM works, DFU-specific issue
- If still silent → ROM/framework issue regardless of DFU

### Step 3: Recreate VM directory (2 min)

The ROMs are copied from Virtualization.framework during `make vm_new`. If the VM dir was created on an older macOS, the ROMs may be stale:

```bash
mv vm vm.bak
make vm_new
# copy back firmware files from vm.bak if needed
make boot_dfu
```

### Step 4: Instrument private API calls

Add logging around every Dynamic call in VPhoneVM.swift to verify none are silently returning nil:

```swift
let result = Dynamic(config)._setForceDFU(true)
print("[vphone] _setForceDFU result: \(result)")
```

### Step 5: Framework header diff

If all above fail, dump private headers:

```bash
class-dump /System/Library/Frameworks/Virtualization.framework/Virtualization > vz_26.3.h
# compare with headers from macOS 15 if available
grep -i 'dfu\|forceDFU\|usb' vz_26.3.h
```
