#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
script="$repo_root/scripts/tofu-init-scaleway.sh"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

fake_bin="$tmp_dir/bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/tofu" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$TOFU_ARGS_FILE"
EOF
chmod +x "$fake_bin/tofu"

write_valid() {
  cat >"$1" <<'EOF'
bucket = "state"
key = "lockwell/test.tfstate"
region = "fr-par"
use_lockfile = true
encrypt = true
EOF
}

valid="$tmp_dir/valid.s3.tfbackend"
write_valid "$valid"
TOFU_ARGS_FILE="$tmp_dir/args" PATH="$fake_bin:$PATH" "$script" "$valid"
grep -Fxq "init" "$tmp_dir/args"
grep -Fxq -- "-reconfigure" "$tmp_dir/args"
grep -Fxq -- "-backend-config=$valid" "$tmp_dir/args"

secret="$tmp_dir/secret.s3.tfbackend"
write_valid "$secret"
printf '%s\n' 'secret_key = "must-not-be-here"' >>"$secret"
if TOFU_ARGS_FILE="$tmp_dir/unused" PATH="$fake_bin:$PATH" "$script" "$secret"; then
  echo "expected credential-bearing backend config to be rejected" >&2
  exit 1
fi

unlocked="$tmp_dir/unlocked.s3.tfbackend"
write_valid "$unlocked"
sed -i 's/use_lockfile = true/use_lockfile = false/' "$unlocked"
if TOFU_ARGS_FILE="$tmp_dir/unused" PATH="$fake_bin:$PATH" "$script" "$unlocked"; then
  echo "expected unlocked backend config to be rejected" >&2
  exit 1
fi

unencrypted="$tmp_dir/unencrypted.s3.tfbackend"
write_valid "$unencrypted"
sed -i 's/encrypt = true/encrypt = false/' "$unencrypted"
if TOFU_ARGS_FILE="$tmp_dir/unused" PATH="$fake_bin:$PATH" "$script" "$unencrypted"; then
  echo "expected unencrypted backend config to be rejected" >&2
  exit 1
fi
