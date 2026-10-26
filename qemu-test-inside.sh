#!/usr/bin/env bash
# Runs inside a privileged Debian container. See qemu-test.sh.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/sbin:/sbin:/usr/bin:/bin"
printf 'Acquire::ForceIPv4 "true";\n' > /etc/apt/apt.conf.d/99force-ipv4

apt-get update
apt-get install -y util-linux

losetup -fP /work/out/disk.img
DEV=$(losetup -j /work/out/disk.img | awk -F: 'NR==1 { print $1 }')
[[ -b "$DEV" ]] || { echo "loop device missing" >&2; exit 1; }
echo "Installing onto $DEV"

cleanup() {
    set +e
    umount -R /mnt/check 2>/dev/null
    if [[ -n "${DEV:-}" ]]; then
        losetup -d "$DEV" 2>/dev/null
    fi
    if [[ -n "${QEMU_PID:-}" ]]; then
        kill "$QEMU_PID" 2>/dev/null
    fi
}
trap cleanup EXIT

bash /work/install-fedora.sh \
    --disk "$DEV" \
    --user osman \
    --password 'Fedora-qemu-1' \
    --nvidia no \
    --dm ly \
    --configs no \
    --apps none \
    --hostname fedora \
    --timezone Europe/Istanbul \
    --kernel-arg 'console=ttyS0,115200' \
    --ssh-authorized-key /work/out/test_key.pub \
    --yes

partx -u "$DEV" || true
# Partition nodes created with mknod go stale if the kernel renumbers them.
base=$(basename "$DEV")
for name in "${base}p1" "${base}p2" "${base}p3"; do
    [[ -b "/dev/$name" ]] && continue
    [[ -r "/sys/class/block/$name/dev" ]] || continue
    IFS=: read -r major minor < "/sys/class/block/$name/dev"
    mknod "/dev/$name" b "$major" "$minor"
done
EFI="/dev/${base}p1"
BOOT="/dev/${base}p2"
ROOTP="/dev/${base}p3"
mkdir -p /mnt/check
mount -o subvol=root "$ROOTP" /mnt/check
echo "---- boot entry ----"
grep -H . /mnt/check/boot/loader/entries/*.conf
test -f /mnt/check/boot/efi/EFI/BOOT/BOOTX64.EFI
test -e /mnt/check/etc/systemd/system/multi-user.target.wants/ly@tty2.service
test ! -e /mnt/check/usr/bin/sddm
umount -R /mnt/check
losetup -d "$DEV"
DEV=""

apt-get install -y qemu-system-x86 ovmf openssh-client
code=""
vars=""
for candidate in \
    /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/edk2/ovmf/OVMF_CODE.fd
do
    if [[ -f "$candidate" ]]; then
        code=$candidate
        break
    fi
done
for candidate in \
    /usr/share/OVMF/OVMF_VARS_4M.fd \
    /usr/share/OVMF/OVMF_VARS.fd \
    /usr/share/edk2/ovmf/OVMF_VARS.fd
do
    if [[ -f "$candidate" ]]; then
        vars=$candidate
        break
    fi
done
[[ -n "$code" && -n "$vars" ]] || { echo "OVMF firmware not found" >&2; exit 1; }
cp "$vars" /tmp/ovmf-vars.fd

qemu-system-x86_64 \
    -machine q35,accel=kvm \
    -cpu host \
    -m 3072 \
    -smp 4 \
    -display none \
    -serial file:/work/out/serial.log \
    -netdev user,id=n0,hostfwd=tcp::2222-:22 \
    -device virtio-net-pci,netdev=n0 \
    -drive if=pflash,format=raw,readonly=on,file="$code" \
    -drive if=pflash,format=raw,file=/tmp/ovmf-vars.fd \
    -drive file=/work/out/disk.img,format=raw,if=virtio \
    -pidfile /tmp/qemu.pid \
    -daemonize

QEMU_PID=$(cat /tmp/qemu.pid)
echo "QEMU pid $QEMU_PID"

ok=0
for _ in $(seq 1 60); do
    if ssh -i /work/out/test_key \
        -p 2222 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o BatchMode=yes \
        -o ConnectTimeout=3 \
        osman@127.0.0.1 'echo SSH_OK'; then
        ok=1
        break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "qemu exited early" >&2
        break
    fi
    sleep 5
done

if (( ok == 0 )); then
    echo "---- serial log ----" >&2
    tail -n 80 /work/out/serial.log >&2 || true
    exit 1
fi

ssh -i /work/out/test_key \
    -p 2222 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes \
    osman@127.0.0.1 'bash -s' <<'REMOTE'
set -euo pipefail
test -d /sys/firmware/efi
systemctl is-enabled ly@tty2.service
systemctl is-enabled sshd.service
rpm -q sway ly grub2-efi-x64 shim-x64
if rpm -q sddm >/dev/null 2>&1; then
    echo "sddm should not be installed" >&2
    exit 1
fi
findmnt -no FSTYPE / | grep -qx btrfs
grep -q 'rootflags=subvol=root' /proc/cmdline
echo BOOT_OK
REMOTE

echo "QEMU boot checks passed"
