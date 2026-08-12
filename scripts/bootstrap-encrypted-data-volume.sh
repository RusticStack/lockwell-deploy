#!/usr/bin/env bash
# Destructively bootstrap one blank Linux block device for Lockwell data storage.
set -euo pipefail

readonly expected_mount_path=/var/lib/lockwell
readonly mapper_prefix=/dev/mapper/

usage() {
  cat >&2 <<'EOF'
usage: bootstrap-encrypted-data-volume.sh --execute \
  --device /absolute/block-device --mapper /dev/mapper/lockwell-data \
  --mount /var/lib/lockwell --key-file /absolute/root-only-key-file \
  --evidence-report /absolute/root-only-report.json \
  --confirm-device /resolved/device/path:major:minor

The confirmation must exactly match the resolved device identity printed by:
  device=/absolute/block-device
  printf '%s:%s\n' "$(readlink -f -- "$device")" "$(lsblk -dnro MAJ:MIN "$device")"
EOF
  exit 64
}

fail() {
  echo "encrypted volume bootstrap failed: $*" >&2
  exit 65
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

require_absolute_non_symlink() {
  local path=$1 label=$2
  [[ $path == /* ]] || fail "$label must be an absolute path"
  [[ ! -L $path ]] || fail "$label must not be a symbolic link"
}

require_real_directory() {
  local directory=$1 label=$2
  require_absolute_non_symlink "$directory" "$label"
  [[ -d $directory ]] || fail "$label must be an existing directory"
  [[ $(readlink -f -- "$directory") == "$directory" ]] || fail "$label must not traverse a symbolic link"
}

single_value() {
  local description=$1
  shift
  local value
  value=$("$@") || fail "could not determine ${description}"
  value=$(printf '%s\n' "$value" | awk 'NF { print }')
  [[ $(printf '%s\n' "$value" | awk 'NF { count++ } END { print count + 0 }') == 1 ]] || fail "${description} is ambiguous"
  printf '%s\n' "$value"
}

has_nonempty_output() {
  local output
  output=$("$@" 2>/dev/null || true)
  printf '%s\n' "$output" | awk 'NF { found=1 } END { exit !found }'
}

file_has_active_field() {
  local file=$1 field_index=$2 expected=$3
  [[ -e $file ]] || return 1
  awk -v field_index="$field_index" -v expected="$expected" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    $field_index == expected { found=1 }
    END { exit !found }
  ' "$file"
}

assert_config_target_safe() {
  local file=$1 label=$2
  local parent
  parent=$(dirname -- "$file")
  require_real_directory "$parent" "${label} parent directory"
  if [[ -e $file ]]; then
    [[ -f $file && ! -L $file ]] || fail "$label must be a regular file when it exists"
    [[ $(stat -c '%u:%g' -- "$file") == '0:0' ]] || fail "$label must be root-owned"
  fi
}

assert_evidence_target_safe() {
  local parent owner mode group_digit other_digit
  parent=$(dirname -- "$evidence_report")
  require_real_directory "$parent" 'evidence report parent directory'
  owner=$(stat -c '%u' -- "$parent")
  mode=$(stat -c '%a' -- "$parent")
  [[ $owner == 0 ]] || fail 'evidence report parent directory must be root-owned'
  [[ $mode =~ ^[0-7]{3,4}$ ]] || fail 'evidence report parent directory mode is invalid'
  group_digit=${mode: -2:1}
  other_digit=${mode: -1}
  [[ $group_digit != [2367] && $other_digit != [2367] ]] || fail 'evidence report parent directory must not be group- or other-writable'
  if [[ -e $evidence_report ]]; then
    [[ -f $evidence_report && ! -L $evidence_report ]] || fail 'evidence report target must be a regular non-symlink file'
    [[ $(stat -c '%u:%g' -- "$evidence_report") == '0:0' ]] || fail 'existing evidence report must be root-owned'
  fi
}

stage_config_file() {
  local target=$1 line=$2 temp
  temp=$(mktemp "$(dirname -- "$target")/.${target##*/}.lockwell.XXXXXX") || fail "could not stage ${target}"
  if [[ -e $target ]]; then
    cat -- "$target" >"$temp"
    [[ -s $temp ]] && [[ $(tail -c 1 -- "$temp" | wc -l) -eq 0 ]] && printf '\n' >>"$temp"
  fi
  printf '%s\n' "$line" >>"$temp"
  chown root:root "$temp"
  chmod 0644 "$temp"
  printf '%s\n' "$temp"
}

write_evidence_report() {
  umask 077
  evidence_report_temp=$(mktemp "$(dirname -- "$evidence_report")/.${evidence_report##*/}.XXXXXX") || fail "could not stage evidence report"
  cat >"$evidence_report_temp" <<EOF
{"status":"created","created_at_utc":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","device_identity_sha256":"$(printf '%s' "$device_identity" | sha256sum | awk '{print $1}')","luks_uuid_sha256":"$(printf '%s' "$luks_uuid" | sha256sum | awk '{print $1}')","filesystem_uuid_sha256":"$(printf '%s' "$filesystem_uuid" | sha256sum | awk '{print $1}')","mapper_path_sha256":"$(printf '%s' "$mapper_path" | sha256sum | awk '{print $1}')","mount_path_sha256":"$(printf '%s' "$mount_path" | sha256sum | awk '{print $1}')"}
EOF
  chown root:root "$evidence_report_temp"
  chmod 0600 "$evidence_report_temp"
  mv -f -- "$evidence_report_temp" "$evidence_report"
  evidence_report_temp=''
}

backup_config_file() {
  local target=$1 backup_var=$2 existed_var=$3 metadata_var=$4 backup
  if [[ -e $target ]]; then
    backup=$(mktemp "$(dirname -- "$target")/.${target##*/}.lockwell-backup.XXXXXX") || fail "could not back up ${target}"
    cat -- "$target" >"$backup"
    chown root:root "$backup"
    chmod 0600 "$backup"
    printf -v "$backup_var" '%s' "$backup"
    printf -v "$existed_var" '%s' 1
    printf -v "$metadata_var" '%s' "$(stat -c '%u:%g:%a' -- "$target")"
  fi
}

restore_config_file() {
  local target=$1 backup=$2 existed=$3 metadata=$4 restore_temp owner_group mode
  [[ $existed == 1 ]] || { rm -f -- "$target"; return; }
  [[ -n $backup && -f $backup ]] || fail "cannot restore missing backup for ${target}"
  owner_group=${metadata%:*}
  mode=${metadata##*:}
  restore_temp=$(mktemp "$(dirname -- "$target")/.${target##*/}.lockwell-restore.XXXXXX") || fail "could not stage restore for ${target}"
  cat -- "$backup" >"$restore_temp"
  chown "$owner_group" "$restore_temp"
  chmod "$mode" "$restore_temp"
  mv -f -- "$restore_temp" "$target"
}

[[ $# -eq 13 ]] || usage
declare execute=0 device='' mapper_path='' mount_path='' key_file='' evidence_report='' confirmation=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --execute) execute=1; shift ;;
    --device|--mapper|--mount|--key-file|--evidence-report|--confirm-device)
      [[ $# -ge 2 ]] || usage
      case "$1" in
        --device) device=$2 ;;
        --mapper) mapper_path=$2 ;;
        --mount) mount_path=$2 ;;
        --key-file) key_file=$2 ;;
        --evidence-report) evidence_report=$2 ;;
        --confirm-device) confirmation=$2 ;;
      esac
      shift 2
      ;;
    *) usage ;;
  esac
done

[[ $execute == 1 ]] || fail "destructive execution requires --execute"
[[ $(id -u) -eq 0 ]] || fail "must run as root"

test_root=''
if [[ ${LOCKWELL_VOLUME_BOOTSTRAP_TESTING:-} == 1 ]]; then
  test_root=${LOCKWELL_VOLUME_BOOTSTRAP_TEST_ROOT:-}
  require_real_directory "$test_root" "test root"
elif [[ -n ${LOCKWELL_VOLUME_BOOTSTRAP_TESTING:-} || -n ${LOCKWELL_VOLUME_BOOTSTRAP_TEST_ROOT:-} ]]; then
  fail "test overrides require LOCKWELL_VOLUME_BOOTSTRAP_TESTING=1"
fi
[[ -n $test_root || ${OSTYPE:-} == linux* ]] || fail "this bootstrap is Linux-only"

for command_name in awk blkid cat chmod chown cp cryptsetup date dirname findmnt fuser grep lsblk mkfs.ext4 mktemp mount mountpoint mv readlink rm sha256sum stat tail umount wc wipefs; do
  require_command "$command_name"
done

require_absolute_non_symlink "$device" 'block device'
require_absolute_non_symlink "$mapper_path" 'mapper path'
require_absolute_non_symlink "$mount_path" 'mount path'
require_absolute_non_symlink "$key_file" 'key file'
require_absolute_non_symlink "$evidence_report" 'evidence report'
expected_mapper_parent="${test_root}${mapper_prefix%/}"
[[ $(dirname -- "$mapper_path") == "$expected_mapper_parent" ]] || fail "mapper path must be directly under ${expected_mapper_parent}"
require_real_directory "$expected_mapper_parent" 'mapper parent directory'
mapper_name=${mapper_path##*/}
[[ $mapper_name =~ ^[A-Za-z0-9_.+-]{1,64}$ ]] || fail "mapper name is invalid"
[[ $mount_path == "${test_root}${expected_mount_path}" ]] || fail "mount path must be exactly ${test_root}${expected_mount_path}"
require_real_directory "$mount_path" 'mount path'

canonical_device=$(readlink -f -- "$device") || fail 'could not resolve block device'
[[ $canonical_device == "$device" ]] || fail 'block device must already be its resolved non-symlink path'
if [[ -n $test_root ]]; then
  [[ -f $device && ! -L $device ]] || fail 'test block device must be a regular non-symlink file'
else
  [[ -b $device ]] || fail 'block device must be a block special file'
fi
device_type=$(single_value 'block device type' lsblk --noheadings --raw --output TYPE "$device")
[[ $device_type == disk ]] || fail 'block device must be a whole disk, not a partition or mapped device'
device_major_minor=$(single_value 'block device major:minor' lsblk --noheadings --raw --output MAJ:MIN "$device")
[[ $device_major_minor =~ ^[0-9]+:[0-9]+$ ]] || fail 'block device major:minor is invalid'
device_identity="${canonical_device}:${device_major_minor}"
[[ $confirmation == "$device_identity" ]] || fail 'confirmation does not exactly match the resolved device identity'

[[ -f $key_file && ! -L $key_file ]] || fail 'key file must be a regular non-symlink file'
[[ $(stat -c '%u:%g:%a' -- "$key_file") == '0:0:600' ]] || fail 'key file must be root-owned with mode 0600'
[[ -r $key_file ]] || fail 'key file is not readable by root'
[[ ! -e $mapper_path ]] || fail 'mapper path already exists'
mountpoint --quiet "$mount_path" && fail 'mount path is already mounted'
has_nonempty_output lsblk --noheadings --raw --list --output MOUNTPOINTS "$device" && fail 'block device or a descendant is mounted'
fuser -s -- "$device" >/dev/null 2>&1 && fail 'block device is in use by a process'
[[ -z $(lsblk --noheadings --raw --output PTTYPE "$device") ]] || fail 'block device has a partition table'
[[ -z $(blkid -p -o value -s TYPE "$device" 2>/dev/null || true) ]] || fail 'block device has a filesystem or recognized signature'
has_nonempty_output wipefs --noheadings --output TYPE "$device" && fail 'block device has a recognized signature'

for protected_mount in / /boot /boot/efi; do
  protected_source=$(findmnt --noheadings --raw --output SOURCE --target "$protected_mount" 2>/dev/null || true)
  [[ $protected_source == /dev/* ]] || continue
  protected_ancestry=$(lsblk --paths --noheadings --list --inverse --output NAME "$protected_source" 2>/dev/null || true)
  while IFS= read -r ancestor; do
    [[ -n $ancestor ]] || continue
    [[ $(readlink -f -- "$ancestor" 2>/dev/null || true) != "$device" ]] || fail "block device backs protected mount ${protected_mount}"
  done <<<"$protected_ancestry"
done

crypttab_file="${test_root}/etc/crypttab"
fstab_file="${test_root}/etc/fstab"
assert_config_target_safe "$crypttab_file" crypttab
assert_config_target_safe "$fstab_file" fstab
file_has_active_field "$crypttab_file" 1 "$mapper_name" && fail 'crypttab already has an entry for this mapper'
file_has_active_field "$fstab_file" 2 "$mount_path" && fail 'fstab already has an entry for this mount path'
assert_evidence_target_safe

mapper_open=0
volume_mounted=0
completed=0
crypttab_existed=0
fstab_existed=0
crypttab_backup=''
fstab_backup=''
crypttab_metadata=''
fstab_metadata=''
crypttab_installed=0
fstab_installed=0
crypttab_temp=''
fstab_temp=''
evidence_report_temp=''
cleanup() {
  local status=$?
  if [[ $completed != 1 ]]; then
    rm -f -- "$crypttab_temp" "$fstab_temp" "$evidence_report_temp" || true
    [[ $fstab_installed != 1 ]] || restore_config_file "$fstab_file" "$fstab_backup" "$fstab_existed" "$fstab_metadata" || true
    [[ $crypttab_installed != 1 ]] || restore_config_file "$crypttab_file" "$crypttab_backup" "$crypttab_existed" "$crypttab_metadata" || true
    [[ $volume_mounted != 1 ]] || umount -- "$mount_path" >/dev/null 2>&1 || true
    [[ $mapper_open != 1 ]] || cryptsetup close "$mapper_name" >/dev/null 2>&1 || true
  fi
  rm -f -- "$crypttab_temp" "$fstab_temp" "$evidence_report_temp" "$crypttab_backup" "$fstab_backup" || true
  exit "$status"
}
trap cleanup EXIT

# Every rejection above runs before this irreversible operation.
cryptsetup luksFormat --type luks2 --batch-mode --key-file "$key_file" "$device" || fail 'LUKS2 format failed'
luks_uuid=$(single_value 'LUKS UUID' cryptsetup luksUUID "$device")
[[ $luks_uuid =~ ^[0-9a-fA-F-]{36}$ ]] || fail 'LUKS UUID is invalid'
cryptsetup open --key-file "$key_file" "$device" "$mapper_name" || fail 'could not open the new LUKS mapping'
mapper_open=1
[[ -e $mapper_path && ! -L $mapper_path ]] || fail 'new mapper path was not created as expected'
crypt_status=$(cryptsetup status "$mapper_name" 2>/dev/null || true)
printf '%s\n' "$crypt_status" | grep -Eq 'type:[[:space:]]+LUKS2' || fail 'new mapper is not reported as LUKS2'

# mkfs is deliberately reachable only after this invocation created the mapper.
mkfs.ext4 -F "$mapper_path" || fail 'filesystem creation failed'
filesystem_uuid=$(single_value 'filesystem UUID' blkid -o value -s UUID "$mapper_path")
[[ $filesystem_uuid =~ ^[0-9a-fA-F-]{36}$ ]] || fail 'filesystem UUID is invalid'
mount -o nodev,nosuid,noexec "UUID=${filesystem_uuid}" "$mount_path" || fail 'could not mount filesystem by UUID with hardened options'
volume_mounted=1
mountpoint --quiet "$mount_path" || fail 'mount path is not a separate mounted filesystem'
mounted_source=$(single_value 'mounted source' findmnt --noheadings --raw --output SOURCE --target "$mount_path")
lsblk --inverse --noheadings --output TYPE "$mounted_source" | grep -Fxq crypt || fail 'mounted filesystem ancestry does not contain crypt'

backup_config_file "$crypttab_file" crypttab_backup crypttab_existed crypttab_metadata
backup_config_file "$fstab_file" fstab_backup fstab_existed fstab_metadata
crypttab_temp=$(stage_config_file "$crypttab_file" "${mapper_name} UUID=${luks_uuid} ${key_file} luks")
fstab_temp=$(stage_config_file "$fstab_file" "UUID=${filesystem_uuid} ${mount_path} ext4 defaults,nodev,nosuid,noexec 0 2")
mv -f -- "$crypttab_temp" "$crypttab_file"
crypttab_temp=''
crypttab_installed=1
mv -f -- "$fstab_temp" "$fstab_file"
fstab_temp=''
fstab_installed=1
write_evidence_report

completed=1
rm -f -- "$crypttab_backup" "$fstab_backup"
crypttab_backup=''
fstab_backup=''
echo 'encrypted Lockwell data volume bootstrap passed; evidence report was written with digests only'
