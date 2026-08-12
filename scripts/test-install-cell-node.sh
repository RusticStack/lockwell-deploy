#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
script="$repo_root/scripts/install-cell-node.sh"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
fake_bin="$tmp_dir/bin"
install_root="$tmp_dir/root"
data_mount="$install_root/var/lib/lockwell"
mkdir -p "$fake_bin" "$data_mount"

for name in getent groupadd id useradd; do
  cat >"$fake_bin/$name" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$fake_bin/$name"
done
cat >"$fake_bin/mountpoint" <<'EOF'
#!/usr/bin/env bash
[[ ${MOUNT_SCENARIO:-encrypted} != unmounted ]]
EOF
cat >"$fake_bin/findmnt" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' /dev/mapper/lockwell-data
EOF
cat >"$fake_bin/lsblk" <<'EOF'
#!/usr/bin/env bash
[[ ${MOUNT_SCENARIO:-encrypted} == encrypted ]] && printf '%s\n' crypt || printf '%s\n' disk
EOF
cat >"$fake_bin/install" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'install %s\n' "$*" >>"$INSTALL_LOG"
directory_mode=0
positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) directory_mode=1; shift ;;
    -o|-g|-m) shift 2 ;;
    *) positional+=("$1"); shift ;;
  esac
done
if [[ $directory_mode == 1 ]]; then
  mkdir -p "${positional[@]}"
else
  [[ ${#positional[@]} -eq 2 ]]
  mkdir -p "$(dirname -- "${positional[1]}")"
  cp "${positional[0]}" "${positional[1]}"
  chmod +x "${positional[1]}" 2>/dev/null || true
fi
EOF
cat >"$fake_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$INSTALL_LOG"
[[ ${SYSTEMCTL_SCENARIO:-active} == active ]]
EOF
chmod +x "$fake_bin"/*

source_dir="$tmp_dir/source"
mkdir -p "$source_dir"
cat >"$source_dir/lockwell" <<'EOF'
#!/usr/bin/env bash
printf 'validate %s\n' "$*" >>"$INSTALL_LOG"
[[ ${VALIDATE_SCENARIO:-valid} == valid ]]
EOF
cp "$source_dir/lockwell" "$source_dir/lockwelld"
chmod +x "$source_dir/lockwell" "$source_dir/lockwelld"
for file in lockwell.toml lockwelld.env tls.crt tls.key; do printf 'test\n' >"$source_dir/$file"; done
lockwell_sha=$(sha256sum "$source_dir/lockwell" | awk '{print $1}')
lockwelld_sha=$(sha256sum "$source_dir/lockwelld" | awk '{print $1}')
install_log="$tmp_dir/install.log"

run_installer() {
  : >"$install_log"
  PATH="$fake_bin:$PATH" INSTALL_LOG="$install_log" LOCKWELL_INSTALL_TESTING=1 LOCKWELL_INSTALL_TEST_ROOT="$install_root" "$script" \
    --lockwelld-bin "$source_dir/lockwelld" --lockwelld-sha256 "$lockwelld_sha" \
    --lockwell-bin "$source_dir/lockwell" --lockwell-sha256 "$lockwell_sha" \
    --config "$source_dir/lockwell.toml" --env-file "$source_dir/lockwelld.env" \
    --tls-cert "$source_dir/tls.crt" --tls-key "$source_dir/tls.key" \
    --data-mount "$data_mount" --unit-template "$repo_root/operations/systemd/lockwelld.service"
}

run_installer
grep -Fxq "validate config validate -c ${install_root}/etc/lockwell/lockwell.toml" "$install_log"
grep -Fxq 'systemctl daemon-reload' "$install_log"
grep -Fxq 'systemctl enable --now lockwelld.service' "$install_log"
grep -Fxq 'systemctl is-active --quiet lockwelld.service' "$install_log"
validate_line=$(grep -n '^validate ' "$install_log" | cut -d: -f1)
enable_line=$(grep -n '^systemctl enable ' "$install_log" | cut -d: -f1)
[[ $validate_line -lt $enable_line ]]

MOUNT_SCENARIO=unencrypted; export MOUNT_SCENARIO
if run_installer 2>/dev/null; then echo 'expected unencrypted mount to fail' >&2; exit 1; fi
! grep -q '^systemctl enable ' "$install_log"
unset MOUNT_SCENARIO

VALIDATE_SCENARIO=invalid; export VALIDATE_SCENARIO
if run_installer 2>/dev/null; then echo 'expected invalid config to fail' >&2; exit 1; fi
! grep -q '^systemctl enable ' "$install_log"
unset VALIDATE_SCENARIO

bad_sha=$lockwell_sha
lockwell_sha=$(printf '%064d' 0)
if run_installer 2>/dev/null; then echo 'expected checksum mismatch to fail' >&2; exit 1; fi
! grep -q '^systemctl enable ' "$install_log"
lockwell_sha=$bad_sha

ln -s "$source_dir/tls.key" "$source_dir/tls-link.key"
tls_key="$source_dir/tls.key"
mv "$source_dir/tls.key" "$source_dir/tls-real.key"
ln -s "$source_dir/tls-real.key" "$source_dir/tls.key"
if [[ -L $source_dir/tls.key ]]; then
  if run_installer 2>/dev/null; then echo 'expected symbolic-link input to fail' >&2; exit 1; fi
  ! grep -q '^systemctl enable ' "$install_log"
else
  echo 'SKIP: filesystem cannot create symbolic links; run this denial check on Linux' >&2
fi
