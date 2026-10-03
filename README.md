# PipeWire: headset microphone dies after the first HFP use (headset sends `AT+BCC` during eSCO setup)

A fix for Bluetooth headsets whose microphone works **once per connection** on Linux and is dead on every later
switch from the music profile (A2DP) to the voice profile (HSP/HFP) until the headset is reconnected.

Found and verified with a **HUAWEI FreeClip** on an **Intel AX210** (`8087:0032`). The mechanism is the same one
described for the HUAWEI FreeBuds Pro 5 in [bluez/bluez#2562](https://github.com/bluez/bluez/issues/2562); the
PipeWire patch here is the "do not free a transport with a pending SCO connect" fix proposed there.

## Symptoms

- First voice-profile use after connecting the headset works. Every later one: the recording is digital silence or
  has no data, or the card falls straight back to A2DP.
- Kernel log: `Bluetooth: hci0: SCO packet for unknown connection handle 257`, sometimes `corrupted SCO packet`.
- WirePlumber log: `spa.bluez5: Failure in Bluetooth audio transport .../fdNN`,
  `pw.node: (bluez_input...) running -> error`.
- With `spa.bluez5` debug logging: `acquire failed: Invalid argument (-22)`, later `Too many links (-31)`.
- Reconnecting the headset (ACL disconnect/connect) repairs it for exactly one more use.

## Root cause

1. On every audio connection **except the first one after the ACL connect**, the headset itself sends `AT+BCC`
   (HF-initiated codec connection) about 160 ms after PipeWire has started the eSCO connect.
2. PipeWire (`spa/plugins/bluez5/backend-native.c`) answers `OK`, `+BCS: 2`; the headset confirms `AT+BCS=2` - the
   codec that is already in use. The `AT+BCS=` handler nevertheless
   - calls `rfcomm_new_transport()`, which frees the transport and closes its SCO socket, and
   - emits `codec_switched`, which makes `bluez5-device.c` remove and re-create the nodes (releasing the transport
     again).
   Both happen while the eSCO connect is still in progress.
3. The kernel reacts to the closed socket with `Create Connection Cancel`; the controller rejects it with
   `ACL Connection Already Exists (0x0b)` and the kernel drops its `hci_conn`. The controller nevertheless completes
   the link: `Synchronous Connect Complete: Success, handle 257`.
4. The eSCO link is now orphaned in the controller: incoming audio is logged as
   `SCO packet for unknown connection handle 257`, and every later `Enhanced Setup Synchronous Connection` is refused
   with `Synchronous Connection Limit to a Device Exceeded (0x0a)` until the ACL goes down.

`traces/second-open-timeline.txt` shows this sequence from a `btmon` capture:

```
47.515 < HCI Command: Enhanced Setup Synchronous Connection (0x01|0x003d)
47.516 >         Status: Success (0x00)
47.675 > RFCOMM  AT+BCC                       <- sent by the headset, mid-setup
47.676 < RFCOMM  OK
47.676 < RFCOMM  +BCS: 2
47.692 > RFCOMM  AT+BCS=2                     <- same codec as already selected
47.693 < HCI Command: Create Connection Cancel (0x01|0x0008)
47.694 >         Status: ACL Connection Already Exists (0x0b)
47.870 > HCI Event: Synchronous Connect Complete (0x2c), handle 257   Status: Success
...
55.702 < HCI Command: Enhanced Setup Synchronous Connection (0x01|0x003d)
55.702 >         Status: Synchronous Connection Limit to a Device Exceeded (0x0a)
```

So this is neither an adapter-firmware problem nor specific to one kernel version. None of the following helped
here: Intel firmware REL82122 -> REL82200, kernel 7.2.8 -> 6.18 LTS, WirePlumber 0.5.15/0.5.18, `disable_esco`,
USB autosuspend off, CVSD only (`bluez5.codecs` without `msbc`).

## The fix

`patches/0003-bluez5-backend-native-keep-the-transport-when-AT-BCS.patch`: if `AT+BCS=` confirms the codec that is
already in use and a transport exists, reply `OK` and leave the transport and the nodes alone.

```c
if (rfcomm->transport != NULL && rfcomm->codec == selected_codec) {
        spa_log_debug(backend->log, "RFCOMM codec unchanged, keeping transport");
        rfcomm_send_reply(rfcomm, "OK");
        return true;
}
```

The other two patches are unmodified upstream commits that are in PipeWire master but not in 1.6.9; they fix the
related transport error accounting ([pipewire#5467](https://gitlab.freedesktop.org/pipewire/pipewire/-/issues/5467)):

- `0001` = [!3004](https://gitlab.freedesktop.org/pipewire/pipewire/-/merge_requests/3004) "bluez5: deal with asynchronous device and node removal" (Pauli Virtanen)
- `0002` = [!2997](https://gitlab.freedesktop.org/pipewire/pipewire/-/merge_requests/2997) "bluez5: reset the transport error count on a successful acquire" (Caleb White)

### Results

Each round: switch A2DP -> voice profile, record a few seconds from the headset microphone, switch back; no headset
reconnects in between. A round passes only if the recording contains real (non-silent) audio. BlueZ 5.87,
WirePlumber 0.5.18, PipeWire 1.6.9 with the Bluetooth plugin built as listed.

| Bluetooth plugin | passing rounds |
|---|---|
| stock 1.6.9 | 1 of 8 and 1 of 6 (only the first round after connecting); manual profile switches |
| upstream `0001` + `0002` only | unreliable: 2 of 5 and 2 of 4 (one lucky run of 6 of 6); manual profile switches |
| `0003` only | 14 of 16; WirePlumber automatic switching, kernel 7.2.8 |
| `0001` + `0002` + `0003` | 27 of 27 in four runs with WirePlumber automatic switching on kernel 7.2.8; 8 of 8 and 15 of 15 manual profile switches on kernel 6.18 |

With all three patches the microphone delivers audio about 1 s after an application starts recording (0.5 s of that
is WirePlumber's own switch delay).

## Install (per user, no system files changed)

```sh
git clone https://github.com/abrus861/pipewire-hfp-atbcc-fix.git
cd pipewire-hfp-atbcc-fix
./build-and-install.sh
```

The script reads the installed PipeWire version, fetches that source tag, applies the patches (skipping the ones the
version already contains), builds only `libspa-bluez5.so` and installs it to
`~/.local/lib/spa-0.2-patched/bluez5/`. A systemd drop-in for `wireplumber.service` sets `SPA_PLUGIN_DIR` so that
WirePlumber loads the plugin from there. Build requirements are listed at the top of the script. Tested with
PipeWire 1.6.9 on CachyOS (Arch).

After installing, reconnect the headset once. Make sure the headset microphone is the default input and that
WirePlumber's own switching is on (it is by default):

```sh
wpctl settings bluetooth.autoswitch-to-headset-profile     # Value: true
tools/bt-autoswitch-test.py 8                              # 8 record/idle rounds, prints OK/FAILED per round
```

Check that the patched plugin is the one in use:

```sh
grep libspa-bluez5 /proc/$(systemctl --user show wireplumber -p MainPID --value)/maps
```

**After a PipeWire upgrade** remove the drop-in (the plugin was built for one exact version), test, and re-run the
script if the bug is still there:

```sh
rm ~/.config/systemd/user/wireplumber.service.d/spa-bluez5-fix.conf
systemctl --user daemon-reload && systemctl --user restart wireplumber
```

## How to check whether you have the same problem

```sh
sudo btmon -w trace.btsnoop        # in another terminal: switch to the voice profile twice, record each time
btmon -r trace.btsnoop | grep -E 'AT\+BCC|Create Connection Cancel|Limit to a Device Exceeded|Synchronous Connect'
wpctl set-log-level "2,spa.bluez5*:4"; journalctl --user -u wireplumber -f      # back to normal: wpctl set-log-level 2
```

An `AT+BCC` from the headset shortly after `Enhanced Setup Synchronous Connection`, followed by
`Create Connection Cancel`, is this bug.

## Notes for maintainers

- PipeWire: the patch is the minimal change. A more general fix would be to never free or release a transport whose
  SCO connect is pending (defer the codec switch until `sco_ready`), which would also cover a headset that asks for
  a *different* codec at that moment.
- Kernel: closing a SCO socket in `BT_CONNECT` sends `Create Connection Cancel`, which does not cancel an eSCO setup.
  The controller completes the link, the host has no `hci_conn` for it, and nothing ever disconnects it. Disconnecting
  a link that completes after its socket is gone would stop one aborted setup from blocking SCO until the ACL drops.
  See also [bluez/bluez#2562](https://github.com/bluez/bluez/issues/2562) and the linux-bluetooth thread
  "Bluetooth: eSCO re-setup after HFP profile switch" (Intel AX201/AX211, September 2026).

Reported upstream with the patch: [pipewire#5506](https://gitlab.freedesktop.org/pipewire/pipewire/-/issues/5506). `patches-master/` holds the same change rebased on PipeWire master.

## License

Patches are under PipeWire's license (MIT). Scripts in this repository: MIT.
