# install-fedora

![WIP](https://img.shields.io/badge/status-WIP-yellow)

Install Fedora with Sway from a live Linux system using official RPMs and DNF. Sets up UEFI boot, Btrfs, and SELinux.

## Install

Requires x86_64, internet access, and a disk of at least 16 GiB.

```sh
sudo bash install-fedora.sh
```

Prompts for the disk, user, drivers, display manager, dotfiles, and apps. **The selected disk will be erased.** See `bash install-fedora.sh --help` for options.

## Pardus GUI test

Requires a graphical session, QEMU with GTK, KVM access, curl, and OVMF at `/usr/share/edk2/ovmf/`.

```sh
bash qemu-pardus-gui.sh
```

Downloads and verifies Pardus 25.2 XFCE, then boots its live desktop with a reusable 32 GiB disk at `out/pardus-target.img`. Inside Pardus, mount the shared repository and run:

```sh
sudo modprobe 9p
sudo modprobe 9pnet_virtio
sudo mkdir -p /mnt/install
sudo mount -t 9p -o trans=virtio,version=9p2000.L install /mnt/install
lsblk
sudo bash /mnt/install/install-fedora.sh
```

Select the virtual disk, usually `/dev/vda`. Use the UEFI boot menu to boot the installed disk; closing the window stops the VM.

## Automated QEMU test

Requires Docker, `ssh-keygen`, and KVM.

```sh
bash qemu-test.sh
```

Recreates `out/disk.img` (24 GiB) and runs `qemu-test-inside.sh` in a privileged Debian container. Installs Fedora, boots headless QEMU, and checks UEFI, Sway, ly, Btrfs, and SELinux over SSH. Boot log: `out/serial.log`.

## Dotfiles and local checks

`finish-dotfiles.sh` installs dependencies and applies `osmancoskun/dotfiles`, backing up existing configs. Run either from a live system or inside Fedora:

```sh
sudo bash finish-dotfiles.sh /dev/ROOT_PARTITION
# Or, inside Fedora:
sudo bash finish-dotfiles.sh --installed USERNAME
```

Run non-destructive regression checks:

```sh
python3 -m unittest discover -s tests
```
