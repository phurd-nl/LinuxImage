# LUKS + TPM Login-Time Encryption — Runbook (this machine)

Tailored to the actual hardware found on 2026-06-23. Supersedes the device
names and the broken keyfile mechanism in `linux-encryption-proposal-1.html`.

## This machine (verified, read-only)

| Item | Value |
|------|-------|
| OS | Ubuntu 26.04 LTS (resolute), kernel 7.0.0-22-generic |
| Disk | `/dev/nvme0n1`, 931.5 GB, GPT |
| `nvme0n1p1` | 47.7 GB ext4 → `/` (contains `/home`, 6.2 GB used) |
| `nvme0n1p2` | 1 GB vfat → `/boot/efi` |
| `nvme0n1p3` | 977 MB ext4 → `/boot` |
| Free space | ~882 GB, contiguous, after p3 → becomes **`nvme0n1p4`** |
| User | `phurd` (uid 1000) |
| TPM | 2.0 present (`/dev/tpm0`, `/dev/tpmrm0`) |
| Secure Boot | **DISABLED, Setup Mode** — must be enabled first |
| GPU | NVIDIA RTX 5070 Mobile + AMD iGPU (NVIDIA driver not yet installed) |
| Crypto pkgs | cryptsetup / clevis / libpam-mount / aide NOT installed |

## Corrections vs. the HTML proposal

1. **Target device.** Proposal hard-codes `/dev/nvme0n1p4` (and mentions
   `/dev/sda*`). Neither exists. We **create** `nvme0n1p4` in free space first.
2. **`/home` is not a separate partition.** It lives inside `/`. After
   migrating it into the encrypted volume, the original copy stays *plaintext*
   on `nvme0n1p1` until we explicitly wipe it — and we only wipe **after**
   verifying login-unlock works across a reboot.
3. **Key must not sit plaintext on disk.** Instead of leaving
   `/etc/luks-keyfile.bin`, we seal the key with `clevis encrypt tpm2` and store
   only the encrypted JWE blob (`/etc/luks-keyfile.jwe`). The TPM releases the
   plaintext to tmpfs (`/run`) at boot only if PCRs 0,2,4,7 match.
4. **Unlock mechanism.** `pam_mount` has no `keyfile=` option. We use a small
   PAM session hook that opens the LUKS volume with the TPM-released keyfile at
   login and closes + wipes it at logout. Recovery passphrase (**keyslot 1**) is
   the offline fallback; keyslot 0 = login password; keyslot 2 = TPM-sealed key.
5. **Secure Boot first.** PCR 7 = Secure Boot state. We enable SB and enroll
   keys BEFORE sealing, so the seal is stable (avoids an immediate re-seal).
6. **Package list.** Dropped the brittle version-pinned `libtss2-*-0t64`
   names; `clevis-tpm2` + `tpm2-tools` pull the correct deps on 26.04.

## Order of operations (do NOT skip ahead)

- [ ] **0. Backup.** Copy `/home/phurd` (6.2 GB) to an external drive or
      network location. The original stays in place until step 7, but a real
      off-machine backup is the safety net for the partition-table edit.
- [ ] **0b. Configure the target.** Edit `scripts/config.sh` — set `DISK`,
      `PARTNUM`, `USERNAME`, `MAPPER` for THIS machine (defaults are phurd's box:
      `/dev/nvme0n1` p4, user `phurd`, mapper `home_crypt`). Every script sources
      it; `LUKS_DEV` is derived. Sanity-check the derivation with
      `bash scripts/test-config.sh`. A wrong `DISK` here is how you reformat the
      wrong drive — config validation refuses a non-block-device, but confirm the
      value against `lsblk` yourself.
- [ ] **1. Enable Secure Boot.** Reboot → UEFI firmware → enroll/restore
      default Secure Boot keys (platform is in Setup Mode) → enable Secure Boot
      → save & exit. Back in Ubuntu, confirm: `mokutil --sb-state` says enabled.
- [ ] **2. Create `nvme0n1p4`** in free space — `scripts/01-create-partition.sh`
      (guarded: refuses if p4 exists; only touches free space).
- [ ] **3. Encrypt + migrate + seal + PAM** — `scripts/02-setup-encryption.sh`
      (guarded: refuses unless SB enabled, TPM present, p4 empty & unmounted).
      Uses your **login password** for the recovery-grade keyslot prompt and a
      separate **recovery passphrase** you store OFFLINE.
- [ ] **4. Reboot and TEST.** Log in. Confirm `/home` is the encrypted
      volume (`findmnt /home` shows `/dev/mapper/home_crypt`). Log out /
      back in. Verify the keyfile is wiped when logged out.
- [ ] **5. Tamper test (optional but recommended).** Temporarily change a PCR
      input (e.g. boot a different kernel) and confirm the TPM withholds the key.
- [ ] **6. NVIDIA + MOK** (only if/when you install the NVIDIA driver under SB).
- [ ] **7. Wipe the old plaintext `/home`** — `scripts/04-purge-shadowed-plaintext-home.sh`
      — ONLY after steps 4–5 pass. Irreversible. (Replaces the removed
      `03-finalize-wipe-old-home.sh`, which assumed the wrong mountpoint.)

## Fail-closed behaviour (post-purge)

| Stage | PAM open | Unlock fails → |
|-------|----------|----------------|
| After `02`, before `04` | `session optional` | Login still works; `/home` may be the **plaintext** shadow on root. Verify auto-unlock before purge. |
| After `04` (`purge_done`) | `session required` | Login **denied**. No plaintext fallback. Recover offline (below), then `sudo clevis-reheal`. |

Self-heal (script `08`, also run at end of `06`): on PCR-7 drift, auth stashes the login password in root-only tmpfs for ≤60s; session open reseals and shreds. Stash is never reused if stale.

## TODO (optional ops checks)

- [ ] **Test reseal:** `sudo /usr/local/sbin/clevis-reseal` then confirm unseal still works.
- [ ] **Collect recovery passphrase offline** (wizard: `/var/lib/linux-encryption-setup/recovery-passphrase`) then `shred -u` that file.
- [ ] **Tamper test:** change Secure Boot state / boot unsigned and confirm TPM withholds the key.

## Recovery (keep offline, printed)

- Recovery passphrase (**keyslot 1**) — offline floor if TPM cleared, board swapped, or PCR 7 drifts and self-heal cannot run.
  Login password = **keyslot 0**; TPM random key = **keyslot 2+**.
- After first-boot wizard: `sudo cat /var/lib/linux-encryption-setup/recovery-passphrase`
  → store offline → `sudo shred -u /var/lib/linux-encryption-setup/recovery-passphrase`.
- Re-seal after a Secure Boot policy change (if self-heal did not fire):
  `sudo clevis-reseal` or `sudo clevis-reheal` (PCR 7 only).

### Live-USB / recovery-mode unlock

Use when GDM login fails after purge (fail-closed) or hooks are broken.

1. Boot Ubuntu **live USB** (or recovery root shell). Do **not** rely on the installed system's PAM hooks.
2. Install tools if needed: `sudo apt-get update && sudo apt-get install -y cryptsetup`.
3. Identify the LUKS partition (`lsblk -f` — look for `crypto_LUKS`, often `nvme0n1p3` or `p4` per `config.sh`).
4. Unlock with recovery passphrase (or login password = keyslot 0):

```bash
sudo cryptsetup open /dev/nvme0n1pX home_crypt   # type recovery passphrase
sudo mkdir -p /mnt/home
sudo mount /dev/mapper/home_crypt /mnt/home
# your data is under /mnt/home/<user>
```

5. If the installed root is still accessible, chroot and reheal TPM auto-unlock:

```bash
# mount installed root + EFI/boot as needed, then:
sudo cryptsetup open /dev/nvme0n1pX home_crypt
sudo mount /dev/mapper/home_crypt /mnt/install/home   # if repairing in place
# From a root shell ON the installed system (after unlock + mount /home):
sudo clevis-reheal    # prompts for login or recovery passphrase; reseals JWE to PCR 7
```

6. Confirm: reboot, log in, `findmnt /home` → `/dev/mapper/home_crypt`, `journalctl -t home-crypt -b`.
7. Optional: `sudo bash /opt/linux-encryption-setup/scripts/07-cleanup-stray-slots.sh` to prune orphaned TPM keyslots after multiple heals.

### If you only have the login password (keyslot 0)

Same as step 4 — `cryptsetup open` accepts any valid passphrase. Then `sudo clevis-reheal` to restore TPM auto-unlock.
