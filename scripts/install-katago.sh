#!/usr/bin/env bash
set -euo pipefail

image="${KATAGO_IMAGE:-localhost/rtgo:latest}"
model="kata1-b6c96-s175395328-d26788732.txt.gz"
destination=/opt/katago
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

if ! command -v podman >/dev/null 2>&1; then
  echo 'Podman is required to extract the existing KataGo image bundle.' >&2
  exit 1
fi
if ! podman image exists "$image"; then
  echo "Local image not found: $image. Set KATAGO_IMAGE to your existing RTGO image." >&2
  exit 1
fi

work=$(mktemp -d)
container=""
cleanup() {
  if [[ -n "$container" ]]; then
    podman rm -v "$container" >/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

# Creating a stopped container lets us copy files without running its server.
container=$(podman create --pull=never "$image")
podman cp "$container:/opt/katago/." "$work/"
for file in katago "$model" LICENSE; do
  if [[ ! -s "$work/$file" ]]; then
    echo "Missing or empty KataGo bundle file: $file" >&2
    exit 1
  fi
done
printf '48d6754de3c4754f95bf6a5ca40957a49e5e915aaaeede133a17b9ccf8fa5fcb  %s\n' "$work/$model" | sha256sum -c -

privilege=()
if (( EUID != 0 )) && ! [[ -d "$destination" && -w "$destination" ]] && ! [[ ! -e "$destination" && -w /opt ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    echo 'Installing into /opt/katago requires write access or sudo.' >&2
    exit 1
  fi
  privilege=(sudo)
fi
"${privilege[@]}" install -d -m 755 "$destination"
"${privilege[@]}" install -m 755 "$work/katago" "$destination/katago"
"${privilege[@]}" install -m 644 "$work/$model" "$project/container/analysis.cfg" "$work/LICENSE" "$destination/"

echo "Installed KataGo, network, config, and license into $destination."
echo 'Run mise run dev, then open http://localhost:1234 and add a bot.'
