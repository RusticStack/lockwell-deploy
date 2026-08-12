#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
script="$repo_root/scripts/bootstrap-encrypted-data-volume.sh"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
fake_bin="$tmp_dir/bin"
test_root="$tmp_dir/root"
device="$tmp_dir/blank-device"
mapper="$test_root/dev/mapper/lockwell-data"
mount_path="$test_root/var/lib/lockwell"
key_file="$tmp_dir/volume.key"
report="$test_root/var/lib/lockwell/bootstrap-evidence.json"
log_file="$tmp_dir/commands.log"
mount_state="$tmp_dir/mounted"
mkdir -p "$fake_bin" "$(dirname -- "$mapper")" "$mount_path" "$test_root/etc"
touch "$device" "$key_file"
chmod 0600 "$key_file"

cat >"$fake_bin/chown" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$fake_bin/id" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == -u ]] && printf '0\n'
EOF
cat >"$fake_bin/stat" <<'EOF'
#!/usr/bin/env bash
if [[ ${OSTYPE:-} == linux* ]]; then
  exec /usr/bin/stat "$@"
fi
if [[ $* == *'%u:%g:%a'* ]]; then
  [[ ${EXPECT_UNSAFE_KEY:-0} == 1 ]] && printf '0:0:644\n' || printf '0:0:600\n'
elif [[ $* == *'%u:%g'* ]]; then
  printf '0:0\n'
elif [[ $* == *'%u'* ]]; then
  printf '0\n'
elif [[ $* == *'%a'* ]]; then
  printf '700\n'
else
  /usr/bin/stat "$@"
fi
EOF

cat >"$fake_bin/readlink" <<'EOF'
#!/usr/bin/env bash
while [[ ${1:-} == -f || ${1:-} == -- ]]; do shift; done
printf '%s\n' "$1"
EOF
cat >"$fake_bin/lsblk" <<'EOF'
#!/usr/bin/env bash
arguments="$*"
case "$arguments" in
  *' MAJ:MIN '*) printf '8:16\n' ;;
  *' PTTYPE '*) [[ ${SCENARIO:-success} == partition-table ]] && printf 'gpt\n' ;;
  *' MOUNTPOINTS '*) [[ ${SCENARIO:-success} == mounted ]] && printf '/mnt/in-use\n' ;;
  *' TYPE '*) [[ $arguments == *--inverse* ]] && printf 'crypt\n' || printf 'disk\n' ;;
  *' NAME '*) [[ ${SCENARIO:-success} == root-device ]] && printf '%s\n' "$DEVICE_PATH" ;;
  *) echo "unexpected lsblk arguments: $arguments" >&2; exit 1 ;;
esac
EOF
cat >"$fake_bin/blkid" <<'EOF'
#!/usr/bin/env bash
if [[ $* == *' -s TYPE '* ]]; then
  [[ ${SCENARIO:-success} == filesystem ]] && printf 'ext4\n'
elif [[ $* == *' -s UUID '* ]]; then
  printf '11111111-2222-4333-8444-555555555555\n'
fi
EOF
cat >"$fake_bin/wipefs" <<'EOF'
#!/usr/bin/env bash
[[ ${SCENARIO:-success} == signature ]] && printf 'ext4\n'
EOF
cat >"$fake_bin/findmnt" <<'EOF'
#!/usr/bin/env bash
if [[ $* == *"$MOUNT_PATH"* ]]; then
  printf '%s\n' "$MAPPER_PATH"
elif [[ ${SCENARIO:-success} == root-device ]]; then
  printf '/dev/root\n'
else
  printf 'overlay\n'
fi
EOF
cat >"$fake_bin/mountpoint" <<'EOF'
#!/usr/bin/env bash
[[ ${SCENARIO:-success} == already-mounted || -f $MOUNT_STATE ]]
EOF
cat >"$fake_bin/fuser" <<'EOF'
#!/usr/bin/env bash
[[ ${SCENARIO:-success} == in-use ]]
EOF
cat >"$fake_bin/cryptsetup" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$COMMAND_LOG"
case "$1" in
  luksFormat) [[ ${SCENARIO:-success} != format-fails ]] ;;
  luksUUID) printf 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee\n' ;;
  open) touch "$MAPPER_PATH" ;;
  status) printf '  type:    LUKS2\n' ;;
  close) rm -f "$MAPPER_PATH" ;;
esac
EOF
cat >"$fake_bin/mkfs.ext4" <<'EOF'
#!/usr/bin/env bash
printf 'mkfs %s\n' "$*" >>"$COMMAND_LOG"
EOF
cat >"$fake_bin/mount" <<'EOF'
#!/usr/bin/env bash
printf 'mount %s\n' "$*" >>"$COMMAND_LOG"
touch "$MOUNT_STATE"
EOF
cat >"$fake_bin/umount" <<'EOF'
#!/usr/bin/env bash
printf 'umount %s\n' "$*" >>"$COMMAND_LOG"
rm -f "$MOUNT_STATE"
EOF
cat >"$fake_bin/mv" <<'EOF'
#!/usr/bin/env bash
source=${@: -2:1}
destination=${@: -1}
if [[ ${SCENARIO:-success} == fail-fstab-mv && $destination == "$FSTAB_PATH" && $source == *'.fstab.lockwell.'* ]]; then
  exit 1
fi
if [[ ${SCENARIO:-success} == fail-evidence-mv && $destination == "$REPORT_PATH" && $source == *'.bootstrap-evidence.json.'* ]]; then
  exit 1
fi
/usr/bin/mv "$@"
EOF
chmod +x "$fake_bin"/*

run_bootstrap() {
  : >"$log_file"
  PATH="$fake_bin:$PATH" COMMAND_LOG="$log_file" MAPPER_PATH="$mapper" MOUNT_PATH="$mount_path" MOUNT_STATE="$mount_state" DEVICE_PATH="$device" FSTAB_PATH="$test_root/etc/fstab" REPORT_PATH="$report" \
    LOCKWELL_VOLUME_BOOTSTRAP_TESTING=1 LOCKWELL_VOLUME_BOOTSTRAP_TEST_ROOT="$test_root" \
    "$script" --execute --device "$device" --mapper "$mapper" --mount "$mount_path" \
      --key-file "$key_file" --evidence-report "$report" --confirm-device "${device}:8:16"
}

run_bootstrap
grep -Fxq "luksFormat --type luks2 --batch-mode --key-file $key_file $device" "$log_file"
grep -Fxq "open --key-file $key_file $device lockwell-data" "$log_file"
grep -Fxq "mkfs -F $mapper" "$log_file"
grep -Fxq "mount -o nodev,nosuid,noexec UUID=11111111-2222-4333-8444-555555555555 $mount_path" "$log_file"
grep -Fxq "lockwell-data UUID=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee $key_file luks" "$test_root/etc/crypttab"
grep -Fxq "UUID=11111111-2222-4333-8444-555555555555 $mount_path ext4 defaults,nodev,nosuid,noexec 0 2" "$test_root/etc/fstab"
[[ $("$fake_bin/stat" -c '%u:%g:%a' "$report") == '0:0:600' ]]
grep -Eq '"device_identity_sha256":"[0-9a-f]{64}"' "$report"
! grep -Fq "$device" "$report"
! grep -Fq "$key_file" "$report"

assert_denied_before_format() {
  local scenario=$1 message=$2
  rm -f "$mapper" "$mount_state" "$report" "$test_root/etc/fstab"
  [[ $scenario == crypttab-conflict ]] || rm -f "$test_root/etc/crypttab"
  if SCENARIO="$scenario" run_bootstrap >/dev/null 2>&1; then
    echo "expected ${message} to fail" >&2
    exit 1
  fi
  ! grep -q '^luksFormat ' "$log_file" || { echo "${message} reached formatting" >&2; exit 1; }
}

assert_denied_before_format mounted 'mounted device'
assert_denied_before_format in-use 'in-use device'
assert_denied_before_format already-mounted 'pre-mounted target'
assert_denied_before_format partition-table 'partition table'
assert_denied_before_format filesystem 'filesystem signature'
assert_denied_before_format signature 'wipefs signature'
assert_denied_before_format root-device 'root device ancestry'

rm -f "$mapper" "$report" "$test_root/etc/crypttab" "$test_root/etc/fstab"
if PATH="$fake_bin:$PATH" COMMAND_LOG="$log_file" MAPPER_PATH="$mapper" MOUNT_PATH="$mount_path" MOUNT_STATE="$mount_state" DEVICE_PATH="$device" \
  LOCKWELL_VOLUME_BOOTSTRAP_TESTING=1 LOCKWELL_VOLUME_BOOTSTRAP_TEST_ROOT="$test_root" \
  "$script" --execute --device "$device" --mapper "$mapper" --mount "$mount_path" \
    --key-file "$key_file" --evidence-report "$report" --confirm-device "${device}:0:0" >/dev/null 2>&1; then
  echo 'expected incorrect confirmation to fail' >&2
  exit 1
fi
! grep -q '^luksFormat ' "$log_file" || { echo 'bad confirmation reached formatting' >&2; exit 1; }

chmod 0644 "$key_file"
EXPECT_UNSAFE_KEY=1; export EXPECT_UNSAFE_KEY
assert_denied_before_format success 'unsafe key permissions'
unset EXPECT_UNSAFE_KEY
chmod 0600 "$key_file"

assert_rollback_after_mutation_failure() {
  local scenario=$1 message=$2
  rm -f "$mapper" "$mount_state" "$report" "$test_root/etc/crypttab" "$test_root/etc/fstab"
  printf '# original crypttab\noldcrypt UUID=old /root/old.key luks\n' >"$test_root/etc/crypttab"
  printf '# original fstab\nUUID=old /old ext4 defaults 0 2\n' >"$test_root/etc/fstab"
  if SCENARIO="$scenario" run_bootstrap >/dev/null 2>&1; then
    echo "expected ${message} to fail" >&2
    exit 1
  fi
  [[ $(cat "$test_root/etc/crypttab") == $'# original crypttab\noldcrypt UUID=old /root/old.key luks' ]] || { echo "${message} did not restore crypttab" >&2; exit 1; }
  [[ $(cat "$test_root/etc/fstab") == $'# original fstab\nUUID=old /old ext4 defaults 0 2' ]] || { echo "${message} did not restore fstab" >&2; exit 1; }
  [[ ! -e $mapper && ! -e $mount_state ]] || { echo "${message} did not clean up mapper or mount" >&2; exit 1; }
  grep -q '^umount ' "$log_file" || { echo "${message} did not unmount" >&2; exit 1; }
  grep -q '^close lockwell-data$' "$log_file" || { echo "${message} did not close mapper" >&2; exit 1; }
}

assert_rollback_after_mutation_failure fail-fstab-mv 'fstab replacement failure'
assert_rollback_after_mutation_failure fail-evidence-mv 'evidence replacement failure'

rm -f "$mapper" "$report" "$test_root/etc/crypttab" "$test_root/etc/fstab"
printf 'lockwell-data UUID=deadbeef %s luks\n' "$key_file" >"$test_root/etc/crypttab"
assert_denied_before_format crypttab-conflict 'crypttab mapper conflict'
rm -f "$test_root/etc/crypttab"

ln -s "$device" "$tmp_dir/device-link"
if [[ -L $tmp_dir/device-link ]]; then
  if PATH="$fake_bin:$PATH" COMMAND_LOG="$log_file" MAPPER_PATH="$mapper" MOUNT_PATH="$mount_path" MOUNT_STATE="$mount_state" DEVICE_PATH="$device" FSTAB_PATH="$test_root/etc/fstab" REPORT_PATH="$report" \
    LOCKWELL_VOLUME_BOOTSTRAP_TESTING=1 LOCKWELL_VOLUME_BOOTSTRAP_TEST_ROOT="$test_root" \
    "$script" --execute --device "$tmp_dir/device-link" --mapper "$mapper" --mount "$mount_path" \
      --key-file "$key_file" --evidence-report "$report" --confirm-device "${device}:8:16" >/dev/null 2>&1; then
    echo 'expected symbolic-link device to fail' >&2
    exit 1
  fi
else
  echo 'SKIP: filesystem cannot create symbolic links; run this denial check on Linux' >&2
fi
