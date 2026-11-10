# config.sh — machine- and user-specific settings for the LinuxEncryption scripts.
# EDIT THIS FIRST when setting up a new machine/user. Sourced by every NN-*.sh and
# by the diagnostics; not meant to be run on its own.
#
# Only these four values identify the target. Everything else (install paths, PCR
# policy) is a design constant baked into the scripts. Values can also be
# overridden per-invocation via the environment, e.g.:
#     DISK=/dev/sda PARTNUM=3 USERNAME=bob sudo -E bash scripts/02-setup-encryption.sh

DISK=${DISK:-/dev/nvme0n1}        # whole disk that gets partition PARTNUM (script 01)
PARTNUM=${PARTNUM:-3}             # partition number to create / encrypt
                                  # (3 = install with /(p1) + /boot/efi(p2), no separate /boot;
                                  #  was 4 on the original box which had a separate /boot p3)
USERNAME=${USERNAME:-phurd}       # login user whose /home is encrypted + auto-unlocked (auto-detected by wizard)
MAPPER=${MAPPER:-home_crypt}      # /dev/mapper name for the opened LUKS volume

JWE=${JWE:-/etc/luks-keyfile.jwe} # install path of the TPM-sealed key (constant; rarely change)

# Passphrase slots use Argon2id. A stolen disk then costs memory, not just GPU time.
# 512 MiB fits an 8 GB laptop. Login uses the TPM key, so this cost is paid only
# when a person types a passphrase (recovery, or the TPM will not unseal).
LUKS_KDF=(--pbkdf argon2id --pbkdf-memory 524288 --iter-time 3000)

# Derive the partition node. nvme/mmcblk devices insert a 'p' before the number
# (nvme0n1 -> nvme0n1p4); sd/vd devices do not (sda -> sda4).
if [[ "$DISK" =~ [0-9]$ ]]; then
  LUKS_DEV="${DISK}p${PARTNUM}"
else
  LUKS_DEV="${DISK}${PARTNUM}"
fi

# ---- validation: the safety floor for a parameterized destructive installer ----
# A wrong DISK here is how you reformat the wrong drive, so fail loud and early.
# (test-config.sh sets CONFIG_SKIP_VALIDATE to exercise the derivation off-target.)
if [ -z "${CONFIG_SKIP_VALIDATE:-}" ]; then
  [ -n "$DISK" ] && [ -n "$PARTNUM" ] && [ -n "$USERNAME" ] && [ -n "$MAPPER" ] \
    || { echo "config.sh: DISK, PARTNUM, USERNAME and MAPPER must all be set"; exit 1; }
  [ -b "$DISK" ] \
    || { echo "config.sh: DISK '$DISK' is not a block device on this machine — fix scripts/config.sh"; exit 1; }
  case "$MAPPER" in
    */*|*" "*) echo "config.sh: MAPPER '$MAPPER' must be a bare name, not a path"; exit 1;;
  esac
fi
