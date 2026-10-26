#!/usr/bin/env bash
# Install Fedora onto a throwaway disk image from a Debian container, then boot
# that image with UEFI in QEMU. The host disks are not used.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
OUT="$ROOT/out"
IMAGE="$OUT/disk.img"
KEY="$OUT/test_key"
TEST_IMAGE="${FEDORA_TEST_IMAGE:-debian:bookworm}"
mkdir -p "$OUT"
rm -f "$IMAGE" "$KEY" "$KEY.pub" "$OUT/serial.log"
truncate -s 24G "$IMAGE"
ssh-keygen -t ed25519 -f "$KEY" -N '' -q -C 'fedora-install-qemu'

docker run --rm --privileged --network host \
    -v "$ROOT:/work" \
    -e FEDORA_INSTALL_CACHE=/work/cache \
    "$TEST_IMAGE" \
    bash /work/qemu-test-inside.sh
