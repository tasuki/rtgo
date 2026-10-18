#!/usr/bin/env bash
# Exercise installation and cleanup without Podman, sudo, network or /opt writes.
set -euo pipefail
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
export TEST_LOG="$work/calls"
export PATH="$work/bin:$PATH"

cat > "$work/bin/podman" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf 'podman %s\n' "$*" >> "$TEST_LOG"
case "$1" in
  image) [[ "$TEST_MODE" != missing-image ]] ;;
  create) echo temporary-katago-container ;;
  cp)
    [[ "$TEST_MODE" != copy-failed ]] || exit 1
    target="${@: -1}"
    printf 'engine' > "$target/katago"
    printf 'license' > "$target/LICENSE"
    if [[ "$TEST_MODE" != missing-model ]]; then
      printf 'model' > "$target/kata1-b6c96-s175395328-d26788732.txt.gz"
    fi
    ;;
  rm) exit 0 ;;
  *) exit 1 ;;
esac
MOCK
cat > "$work/bin/sha256sum" <<'MOCK'
#!/usr/bin/env bash
set -eu
read -r checksum file
[[ "$checksum" == 48d6754de3c4754f95bf6a5ca40957a49e5e915aaaeede133a17b9ccf8fa5fcb ]]
[[ -f "$file" ]]
printf 'verified network\n' >> "$TEST_LOG"
[[ "$TEST_MODE" != bad-checksum ]]
MOCK
cat > "$work/bin/install" <<'MOCK'
#!/usr/bin/env bash
printf 'install %s\n' "$*" >> "$TEST_LOG"
MOCK
cat > "$work/bin/sudo" <<'MOCK'
#!/usr/bin/env bash
exec "$@"
MOCK
chmod +x "$work/bin/"*

run_case() {
  export TEST_MODE="$1"
  : > "$TEST_LOG"
  if bash "$project/scripts/install-katago.sh" > "$work/output" 2>&1; then
    [[ "$2" == success ]] || { echo "Unexpected success: $1" >&2; exit 1; }
  else
    [[ "$2" == failure ]] || { echo "Unexpected failure: $1" >&2; exit 1; }
  fi
}

unset KATAGO_IMAGE
run_case installed success
grep -q 'podman image exists localhost/rtgo:latest' "$TEST_LOG"
grep -q 'verified network' "$TEST_LOG"
grep -q 'install -m 755 .* /opt/katago/katago' "$TEST_LOG"
grep -Fq "$project/container/analysis.cfg" "$TEST_LOG"
grep -q 'install -m 644 .*LICENSE /opt/katago/' "$TEST_LOG"
grep -q 'podman rm -v temporary-katago-container' "$TEST_LOG"

export KATAGO_IMAGE=custom/rtgo:dev
run_case installed success
grep -q 'podman image exists custom/rtgo:dev' "$TEST_LOG"

for scenario in copy-failed missing-model bad-checksum; do
  run_case "$scenario" failure
  grep -q 'podman rm -v temporary-katago-container' "$TEST_LOG"
  if grep -q '^install ' "$TEST_LOG"; then
    echo "Installed files despite failure: $scenario" >&2
    exit 1
  fi
done

run_case missing-image failure
if grep -qE 'podman create|^install ' "$TEST_LOG"; then
  echo 'Created a container or installed files without a local image' >&2
  exit 1
fi

echo 'KataGo installer: 6 scenarios passed (no real installation performed).'
