# Ubuntu 26.04 Dell first boot: handoff

Written 9 Nov 2026 so another session can continue without repeating the dead ends. The laptop on the bench still does not reach a sign-in screen. The install itself completes.

## Root cause, from the laptop's own journal (9 Nov 2026 20:18 UTC boot)

GDM never tried the sign-in screen. Because `nextadmin` is hidden (`SystemAccount=true`) and no Entra users exist yet, GDM starts GNOME Initial Setup as the greeter. `ubuntu_desktop.py` masks `gnome-initial-setup.service`, so every attempt logs `Unit gnome-initial-setup.service is masked`. After six failures GDM logs `maximum number of display failures reached. Giving up.` and leaves the panel blank. Graphics, i915 and Wayland are fine.

Fixes published to the imaging host:
- `scripts/ubuntu_desktop.py` `skip_new_laptop_questions()` writes `InitialSetupEnable=false` to `/etc/gdm3/custom.conf` (test in `scripts/test-ubuntu-desktop.py`).
- `scripts/setup-entra-authd.sh` UUID regex used `a-Fa-f`, which bash rejects, so Entra login install failed every boot. Now `a-fA-F`.

Temporary diagnostics still in place: `late-install-linux-encryption.sh` installs `nextlink-boot-log.timer`, which posts `journalctl -b` to `laptop-log-drop.service` on the imaging host (port 5514, files in `/var/log/laptop-boot/`). Remove both once this is confirmed.

## Earlier change, 19:45 UTC (needed but not the cause)

`WaylandEnable=false` was the blank screen. Ubuntu 26.04 ships GNOME Shell 50, and it has no X11 mode (`gnome-shell --help` lists only `--wayland` / `--no-x11`, and there is no `/usr/share/xsessions`). With Wayland off, GDM cannot start the sign-in screen, so the panel goes blank exactly when `gdm.service` starts. The earlier frozen cursor under Wayland was the `Before=gdm` ordering, which is already fixed.

Published to the imaging host (the old copies are saved as `*.bak.<timestamp>`):
- `late-install-linux-encryption.sh` no longer writes `WaylandEnable=false` and no longer adds `i915.modeset=0`. `i915.enable_psr=0` stays.
- The kiosk kernel line no longer has `i915.modeset=0`.

Do not bring back `WaylandEnable=false` or `i915.modeset=0` on 26.04. The sections below are the earlier history.

## Machine

- Dell laptop with a detachable keyboard. Iris Xe class. Serial `D3SFJR3`.
- USB ethernet `enx58ef68e409ba` (MAC `58:ef:68:e4:09:ba`). Wi-Fi `wlp0s20f3` was also seen in the installer.
- Disk: SK hynix BC711 NVMe, 256 GB. Installer layout is 1 GB EFI plus a 40 GB ext4 root. The rest of the disk is left free for encrypted `/home` on first boot.
- Imaging address while the installer is running: `192.168.26.34`.

## How imaging works

- Kiosk boot line is built in `fog/opsi/imaging-kiosk/kiosk.py`. The live service is `/opt/imaging-kiosk/kiosk.py` on the imaging host (`ssh opsi`, user `netbootnik`).
- The installer root is NFS: `192.168.26.106:/srv/nfs/ubuntu-26.04.1`. Kernel and initrd are fetched over HTTP from `192.168.26.106:8090`.
- Autoinstall seed is inside `initrd.auto`, not fetched by URL. Source file: `LinuxEncryption/imaging/ubuntu-26.04-desktop-autoinstall.yaml`.
- Customization runs at the end of the install from `http://192.168.26.106:8090/nocloud/extras/late-install-linux-encryption.sh`. That script is what writes the first-boot systemd units and the GRUB snippet.
- Installed kernels seen in GRUB on this disk: `7.0.0-43-generic` (default) and `7.0.0-30-generic`. GRUB 2.14.
- Root filesystem id recorded in that GRUB config: `UUID=515b4e0e-f8b0-4ee0-addd-bef0e29f0e8e`.

## What the boot actually does

A 21 second video posted in Teams (chat with self, 1:32 PM, message id `1794252746497`) shows one boot after the install that fetched `late-install` at 19:25 UTC.

| Time in video | What is on the panel |
| --- | --- |
| 0:01 to 0:04 | Panel is lit and blank. Room reflection only. No login UI. |
| 0:08 | Kernel log is readable. `simpledrm` / `simple-framebuffer` is the console. EFI framebuffer is registered. Secure Boot certificate lines are scrolling. |
| 0:14 | systemd is up. `gdm.service` (GNOME Display Manager) is starting. Intel backlight service runs. NetworkManager is up. |
| 0:19 | Boot text is still updating. `ip` output on screen shows `192.168.26.34`. |
| 0:20 | The text is gone. The panel is lit and blank. |

So the disk is found, userspace is running, and the network is up. The panel goes blank at the moment the graphical login starts. The backlight is not off. Patrick can see the glass and, on other boots, a top-left text cursor that stops blinking. Ctrl+Alt+F3 did not show a different screen. That fits a modeset that stops refreshing the panel: the VT can change underneath a frozen scanout.

GRUB itself is always visible. The firmware framebuffer works. The failure is after the kernel hands the console to the graphics driver and GDM.

## Fixes that are real, and fixes that were wrong

Real, and already in the image that completed today:

- The installer must not apply a `network:` autoinstall section. On an NFS root, Subiquity runs `netplan apply`, stops NetworkManager, and the installer loses its disk. The autoinstall file has no `network:` key. Ethernet DHCP for the installed system is written later to `/etc/netplan/90-nextlink-ethernet.yaml`. This install got past that and finished.
- First-boot encryption and Entra install must not be ordered `Before=gdm`. That left the panel on a text cursor for the whole job, and the encryption unit had `TimeoutStartSec=0`. Current `late-install-linux-encryption.sh` starts those units from `multi-user.target` and does not hold `gdm.service`. The 19:25 UTC install downloaded that version.

Wrong, or not sufficient:

- `i915.enable_psr=0` is already on the installed `linux` line. The panel still blanks. Panel self-refresh is not this bug.
- `i915.enable_dpcd_backlight=0` was aimed at a kernel 7.0.0-28 Tiger Lake bug that turns the backlight off. Patrick checked the panel. The backlight is on. That parameter was removed from the kiosk line. Do not bring it back on the strength of the photos.
- Hand-typed `root=UUID=515b4e0e-...` from a blurry GRUB photo made dracut wait forever for a filesystem id the disk does not have. The disk and the EFI volume (`ECA4-5678`) were visible. A normal GRUB boot finds the root filesystem. Do not boot this machine with a typed UUID.
- `normal` at the `grub>` or `grub rescue>` prompt fails until `prefix` points at the partition that holds `/boot/grub`. That is the rescue shell, not a broken disk.

## What is on the imaging host now, and what this disk does not have

Published after the 19:25 install, so this laptop's disk does not have it yet:

- `i915.modeset=0` on the kiosk kernel line (`/opt/imaging-kiosk/kiosk.py`, service restarted).
- The same flag, plus `i915.enable_psr=0`, in `/etc/default/grub.d/99-nextlink-panel.cfg`, written by `late-install-linux-encryption.sh`, then `update-grub`.
- `WaylandEnable=false` in `/etc/gdm3/custom.conf`, also written by that script. The 19:25 install did include this. The video still goes blank when GDM starts, so Xorg-vs-Wayland was not enough on this boot.

`i915.modeset=0` is the untested next step. It keeps the firmware framebuffer that the video shows working at 0:08 and 0:19. It is not proven. A boot with that flag on the existing `linux` line, without changing `root=`, is the check. If the sign-in screen appears, the flag is the fix. If the panel still blanks, the flag is another miss and the next place to look is GDM's own log after the modeset (`journalctl -b -u gdm`) and whether `simpledrm` is being replaced by `i915` even with `modeset=0`.

## One boot to test, without reimaging

Power off. Tap Esc to the GRUB menu. Press `e` on Ubuntu. At the end of the `linux` line add:

```
i915.modeset=0
```

Do not edit `root=`. Ctrl+X.

The sign-in screen either stays up or the panel blanks again. That single result decides whether the flag already published for the next image is the right one.

## Files

- `LinuxEncryption/imaging/ubuntu-26.04-desktop-autoinstall.yaml`
- `LinuxEncryption/imaging/late-install-linux-encryption.sh`
- `fog/opsi/imaging-kiosk/kiosk.py`
- Host copies: `/opt/linuximage/nocloud/extras/late-install-linux-encryption.sh` and `/opt/imaging-kiosk/kiosk.py`
- HTTP log of this laptop: `journalctl -u linuximage-http.service` on the imaging host, client `192.168.26.34`
