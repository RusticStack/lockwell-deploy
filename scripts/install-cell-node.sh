#!/usr/bin/env bash
# Install one Lockwell data-plane node after its encrypted data volume and secrets have been staged.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: install-cell-node.sh \
  --lockwelld-bin /absolute/path/lockwelld --lockwelld-sha256 HEX \
  --lockwell-bin /absolute/path/lockwell --lockwell-sha256 HEX \
  --config /absolute/path/lockwell.toml --env-file /absolute/path/lockwelld.env \
  --tls-cert /absolute/path/tls.crt --tls-key /absolute/path/tls.key \
  --data-mount /var/lib/lockwell --unit-template /absolute/path/lockwelld.service
EOF
  exit 64
}

fail() {
  echo "cell node installation failed: $*" >&2
  exit 65
}

[[ $# -eq 20 ]] || usage
declare lockwelld_bin='' lockwelld_sha256='' lockwell_bin='' lockwell_sha256=''
declare config='' env_file='' tls_cert='' tls_key='' data_mount='' unit_template=''
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || usage
  case "$1" in
    --lockwelld-bin) lockwelld_bin=$2 ;;
    --lockwelld-sha256) lockwelld_sha256=$2 ;;
    --lockwell-bin) lockwell_bin=$2 ;;
    --lockwell-sha256) lockwell_sha256=$2 ;;
    --config) config=$2 ;;
    --env-file) env_file=$2 ;;
    --tls-cert) tls_cert=$2 ;;
    --tls-key) tls_key=$2 ;;
    --data-mount) data_mount=$2 ;;
    --unit-template) unit_template=$2 ;;
    *) usage ;;
  esac
  shift 2
done

[[ $(id -u) -eq 0 ]] || fail "must run as root"
install_root=
if [[ ${LOCKWELL_INSTALL_TESTING:-} == 1 ]]; then
  install_root=${LOCKWELL_INSTALL_TEST_ROOT:-}
  [[ $install_root == /* && -d $install_root && ! -L $install_root ]] || fail "test install root must be an existing absolute directory"
elif [[ -n ${LOCKWELL_INSTALL_TEST_ROOT:-} || -n ${LOCKWELL_INSTALL_TESTING:-} ]]; then
  fail "test installation overrides require LOCKWELL_INSTALL_TESTING=1"
fi
for command_name in findmnt getent groupadd id install lsblk mountpoint sha256sum systemctl useradd; do
  command -v "$command_name" >/dev/null 2>&1 || fail "missing required command: ${command_name}"
done

for path in "$lockwelld_bin" "$lockwell_bin" "$config" "$env_file" "$tls_cert" "$tls_key" "$data_mount" "$unit_template"; do
  [[ $path == /* ]] || fail "all input paths must be absolute"
  [[ ! -L $path ]] || fail "symbolic links are not accepted: ${path}"
done
for path in "$lockwelld_bin" "$lockwell_bin" "$config" "$env_file" "$tls_cert" "$tls_key" "$unit_template"; do
  [[ -f $path && -r $path ]] || fail "input must be a readable regular file: ${path}"
done
[[ -d $data_mount ]] || fail "data mount must be an existing directory"
expected_data_mount="${install_root}/var/lib/lockwell"
[[ $data_mount == "$expected_data_mount" ]] || fail "data mount must be exactly ${expected_data_mount}"
[[ $lockwelld_sha256 =~ ^[0-9a-fA-F]{64}$ && $lockwell_sha256 =~ ^[0-9a-fA-F]{64}$ ]] || fail "binary SHA-256 values must be 64 hexadecimal characters"
printf '%s  %s\n' "$lockwelld_sha256" "$lockwelld_bin" | sha256sum --check --strict >/dev/null || fail "lockwelld checksum mismatch"
printf '%s  %s\n' "$lockwell_sha256" "$lockwell_bin" | sha256sum --check --strict >/dev/null || fail "lockwell checksum mismatch"

mountpoint --quiet "$data_mount" || fail "data directory must be a separate mounted filesystem"
data_source=$(findmnt --noheadings --output SOURCE --target "$data_mount" | head -n 1)
[[ -n $data_source ]] || fail "could not resolve data mount source"
lsblk --inverse --noheadings --output TYPE "$data_source" | grep -Fxq crypt || fail "data mount must be backed by a dm-crypt/LUKS device"

getent group lockwell >/dev/null 2>&1 || groupadd --system lockwell
id -u lockwell >/dev/null 2>&1 || useradd --system --gid lockwell --home-dir /var/lib/lockwell --shell /usr/sbin/nologin lockwell

install -d -o root -g lockwell -m 0750 "${install_root}/etc/lockwell"
install -d -o lockwell -g lockwell -m 0700 "$data_mount"
install -d -o root -g root -m 0755 "${install_root}/usr/local/bin" "${install_root}/etc/systemd/system"
install -o root -g root -m 0755 "$lockwelld_bin" "${install_root}/usr/local/bin/lockwelld"
install -o root -g root -m 0755 "$lockwell_bin" "${install_root}/usr/local/bin/lockwell"
install -o root -g lockwell -m 0640 "$config" "${install_root}/etc/lockwell/lockwell.toml"
install -o root -g lockwell -m 0640 "$tls_cert" "${install_root}/etc/lockwell/tls.crt"
install -o root -g lockwell -m 0640 "$tls_key" "${install_root}/etc/lockwell/tls.key"
install -o root -g lockwell -m 0640 "$env_file" "${install_root}/etc/lockwell/lockwelld.env"
install -o root -g root -m 0644 "$unit_template" "${install_root}/etc/systemd/system/lockwelld.service"

"${install_root}/usr/local/bin/lockwell" config validate -c "${install_root}/etc/lockwell/lockwell.toml" || fail "installed configuration validation failed"
systemctl daemon-reload
systemctl enable --now lockwelld.service
systemctl is-active --quiet lockwelld.service || fail "lockwelld did not become active"
echo "cell node installation passed; lockwelld is active"
