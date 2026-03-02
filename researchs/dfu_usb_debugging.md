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

**UNKNOWN:** Whether any serial output appears after "VM started in DFU mode" line. The PL011 serial port is attached to stdout — if AVPBooter/iBSS is running, boot chain text should print here. If silent, the ROM may not be executing properly.

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

### 7. csrutil status verification

```
csrutil status
System Integrity Protection status: disabled.
```

**Finding:** SIP is fully disabled (more permissive than just `allow-research-guests`). This should not be a blocker.

## Not Yet Tried

- [ ] Check serial output in Terminal 1 — is there ANY text after "VM started in DFU mode"? This determines if AVPBooter ROM is actually executing.
- [ ] Broader process-level logs: `log show --last 60s --predicate 'process == "vphone-cli"' --info --debug`
- [ ] Confirm VM process is alive: `ps aux | grep vphone`
- [ ] Check if macOS 26 changed Virtualization.framework subsystem name for logs
- [ ] Test on macOS 15 (Sequoia) to rule out macOS 26-specific regression
- [ ] Check if `_setForceDFU` private API behavior changed on macOS 26
- [ ] Check if VM needs `VZUSBControllerConfiguration` or similar for USB device exposure on macOS 26
- [ ] Dump Virtualization.framework private headers on macOS 26 vs 15 to diff USB/DFU-related APIs
- [ ] Try `make boot` (non-DFU) to see if the VM boots normally at all — would confirm ROM/framework works
- [ ] Check if AMFI is also disabled (may be needed separately from SIP on macOS 26)
- [ ] Run `system_profiler SPUSBDataType` during DFU boot to check USB bus

## Analysis

### Root Cause Hypotheses (ordered by likelihood)

1. **macOS 26 Virtualization.framework API change** — The tool targets macOS 14+. macOS 26 is two major versions ahead. Apple may have changed how PV=3 DFU guests expose virtual USB to the host. The complete absence of framework logs supports this — it suggests the framework behavior is fundamentally different. Private API `_setForceDFU` may still exist but behave differently.

2. **AVPBooter ROM not executing** — The VM starts (Swift-level `start()` returns successfully) but the actual boot ROM may crash or hang before reaching DFU USB enumeration. Evidence: no serial output confirmation, zero framework logs. If the ROM from Virtualization.framework on macOS 26 is a different version than expected, it may not work with the existing firmware.

3. **Missing USB device configuration** — macOS 26 may require explicit USB controller configuration in `VZVirtualMachineConfiguration` for DFU mode to expose a device. On earlier macOS versions, this may have been implicit for PV=3 guests. The current `VPhoneVM.swift` does not configure any USB controller — only keyboard, touch, serial, storage, network, and SEP.

4. **Private API signature change** — `_setForceDFU`, `_VZPL011SerialPortConfiguration`, or other Dynamic-called private APIs may have changed signatures on macOS 26. The Dynamic library won't crash on missing methods — it silently returns nil/false. The VM "starts" but without actual DFU mode active.

5. **Entitlement changes** — macOS 26 may require additional entitlements beyond the current 5 in `vphone.entitlements` for PV=3 DFU USB device exposure.

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

## Recommended Next Steps for Engineering Team

1. **Immediate:** Check Terminal 1 serial output — determines if ROM is executing at all.
2. **Quick test:** Run `make boot` (non-DFU, GUI mode) — confirms whether the VM boots at all on macOS 26.
3. **Compare frameworks:** Dump Virtualization.framework private class/method list on macOS 26 vs macOS 15 — check for `_setForceDFU`, `_VZPL011SerialPortConfiguration`, any new USB-related configurations.
4. **Test on macOS 15:** If available, test the same VM directory on a macOS 15 machine to confirm the tool works there.
5. **Framework instrumentation:** Add error checking around all Dynamic private API calls in VPhoneVM.swift — log return values to verify they're not silently failing.
6. **Check USB controller APIs:** On macOS 26, check if `VZUSBControllerConfiguration` or similar new API exists that's required for DFU USB device exposure.
