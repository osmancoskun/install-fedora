#!/usr/bin/env bash
# Boot Pardus 25 XFCE in a QEMU window, with an empty disk for install-fedora.sh.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
ISO="$ROOT/iso/Pardus-25.2-XFCE-amd64.iso"
ISO_URL="https://indir.pardus.org.tr/ISO/Pardus25/Pardus-25.2-XFCE-amd64.iso"
ISO_SHA256="47337d2cb5e703a53c6f95b77ebe34e9cfdbde4df9db23e928265043d1461690"
DISK="$ROOT/out/pardus-target.img"
VARS="$ROOT/out/pardus-ovmf-vars.qcow2"
CODE="/usr/share/edk2/ovmf/OVMF_CODE_4M.qcow2"
VARS_TEMPLATE="/usr/share/edk2/ovmf/OVMF_VARS_4M.qcow2"

mkdir -p "$ROOT/iso" "$ROOT/out"

if [[ ! -x /usr/bin/qemu-system-x86_64 ]]; then
    echo "qemu-system-x86_64 is not installed." >&2
    exit 1
fi
if [[ ! -f "$CODE" || ! -f "$VARS_TEMPLATE" ]]; then
    echo "OVMF firmware is missing (edk2-ovmf)." >&2
    exit 1
fi
if [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    echo "No graphical session. DISPLAY and WAYLAND_DISPLAY are both empty." >&2
    exit 1
fi

if [[ ! -f "$ISO" ]]; then
    echo "Downloading Pardus 25.2 XFCE..."
    curl -fL --retry 3 -C - -o "$ISO.partial" "$ISO_URL"
    mv "$ISO.partial" "$ISO"
fi

echo "Checking ISO checksum..."
actual=$(sha256sum "$ISO" | awk '{print $1}')
if [[ "$actual" != "$ISO_SHA256" ]]; then
    echo "Checksum mismatch for $ISO" >&2
    echo "  expected $ISO_SHA256" >&2
    echo "  actual   $actual" >&2
    exit 1
fi

if [[ ! -f "$DISK" ]]; then
    truncate -s 32G "$DISK"
fi
if [[ ! -f "$VARS" ]]; then
    cp "$VARS_TEMPLATE" "$VARS"
fi

cat <<EOF
Pardus 25 XFCE is starting in a QEMU window.

Inside the live desktop, open a terminal and run:

  sudo modprobe 9p
  sudo modprobe 9pnet_virtio
  sudo mkdir -p /mnt/install
  sudo mount -t 9p -o trans=virtio,version=9p2000.L,msize=104857600 install /mnt/install
  lsblk
  sudo bash /mnt/install/install-fedora.sh

The empty install disk is the 32 GiB virtio disk (usually /dev/vda).
Do not pick the live CD. The installer will ask before it erases anything.

Close the QEMU window to power the VM off.
EOF

exec qemu-system-x86_64 \
    -name "Pardus 25 XFCE" \
    -machine q35,accel=kvm \
    -cpu host \
    -m 4G \
    -smp 4 \
    -display gtk,gl=off \
    -device virtio-vga \
    -usb -device usb-tablet \
    -audio none \
    -drive if=pflash,format=qcow2,readonly=on,file="$CODE" \
    -drive if=pflash,format=qcow2,file="$VARS" \
    -drive file="$ISO",media=cdrom,readonly=on,if=ide \
    -boot order=d,menu=on \
    -drive file="$DISK",format=raw,if=virtio \
    -netdev user,id=n0 \
    -device virtio-net-pci,netdev=n0 \
    -virtfs "local,path=${ROOT},mount_tag=install,security_model=mapped-xattr,id=install"
