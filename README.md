# LinuxImage

**Encrypted Ubuntu golden images** — LUKS2 `/home` + TPM auto-unlock + mandatory first-boot password wizard.

> **Site:** [https://phurd-nl.github.io/LinuxImage/](https://phurd-nl.github.io/LinuxImage/)

Shell scripts do the disk work; `webgui/` drives unattended setup on golden images. Read [`RUNBOOK.md`](RUNBOOK.md) before touching disks.

## What it does

1. Leaves ≥50 GB free at the end of the boot disk on the image  
2. On first boot, user enters their **Ubuntu login password** in a fullscreen wizard  
3. Creates a partition, LUKS2-encrypts it, migrates `/home`, seals a key to the **TPM (PCR 7)**  
4. After reboot + verify: hardens self-heal, **purges** the plaintext shadow on root  

At logout, `/home` is closed again (encrypted at rest).

## Layout

| Path | Role |
|------|------|
| `RUNBOOK.md` | Hardware facts, order of operations, recovery (incl. live USB) |
| `webgui/` | First-boot wizard (password UI + root API) |
| `scripts/NN-*.sh` | Numbered = strict order (`01` → `02` → reboot → `04` … `08`) |
| `scripts/prepare-ubuntu-image.sh` | Bake wizard into a golden image |
| `imaging/` | Autoinstall seed + late-install hook |
| `docs/` | GitHub Pages site for **LinuxImage** |

## Build & deploy

**Do not run encryption on your dev machine.**

```bash
bash scripts/build.sh                              # validate + tarball (safe)
sudo bash scripts/deploy.sh                        # install to /opt on a target VM
sudo bash scripts/prepare-ubuntu-image.sh          # template VM only, before capture
sudo bash scripts/mark-wizard-complete.sh          # skip wizard on already-done machines
```

Configure the target in `scripts/config.sh` (`DISK`, `PARTNUM`, `USERNAME`, `MAPPER`), then:

```bash
bash scripts/test-config.sh
```

## Script order (do not reorder)

`01` create partition → `02` encrypt+migrate+seal+PAM → reboot/test → `04` purge plaintext `/home` → recovery path: `05` / `06` / `07` → `08` PCR 7 + self-heal.

(`03` was removed; it assumed the wrong mountpoint.)

Wizard path runs this pipeline via `orchestrate-firstboot.sh`.

## Safety

- Machine values are centralized in `scripts/config.sh`. Wrong `DISK` = wrong drive reformatted.  
- `04-purge-shadowed-plaintext-home.sh` is **irreversible**. Only after login proves `/home` is `/dev/mapper/home_crypt`.  
- After purge, unlock failure is **fail-closed** (login denied). Recovery passphrase is the offline floor.  
- Recovery (wizard): `/var/lib/linux-encryption-setup/recovery-passphrase` (root-only) — collect offline, then `shred -u`.  

## Keyslots

| Slot | Secret |
|------|--------|
| 0 | Login password (PAM-synced) |
| 1 | Recovery passphrase |
| 2+ | TPM-sealed random key (`/etc/luks-keyfile.jwe`) |

## License / use

Internal fleet tooling. Destructive. Backup first. Verify unlock before purge.
