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
   login and closes + wipes it at logout. Recovery passphrase (keyslot 2) is the
   offline fallback.
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

## TODO (optional hardening — not blocking; core setup complete 2026-06-24)

- [ ] **Test the kernel-update reseal path.** Dry-run `sudo /usr/local/sbin/clevis-reseal`
      and confirm the new JWE still unseals, so it isn't found stale at the next
      `apt upgrade`/kernel bump (PCRs 0,2,4,7 change).
- [ ] **Verify the recovery passphrase (keyslot 1) offline.** Confirm it unlocks
      via `cryptsetup open --test-passphrase`, and store the phrase off-machine.
      This is the only fallback if TPM unseal ever fails.
- [ ] **Document live-USB recovery** here in the runbook: how to unlock the
      volume from a live USB if the login `pam_exec` hook breaks (it is
      `session optional`, so on failure it silently drops to plaintext `/home`).

## Recovery (keep offline, printed)

- Recovery passphrase (keyslot 2) — the only way in if the TPM is cleared,
  the board is swapped, or UEFI firmware is updated (PCR 0 changes).
- Re-seal after a firmware/UEFI change:
  `sudo clevis-reseal` (helper installed by script 02) or manually re-run the
  `clevis encrypt tpm2 ... pcr_ids:0,2,4,7` step.
