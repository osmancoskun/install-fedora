#!/usr/bin/env bash
# Bootstrap Fedora onto a disk from any live Linux (Debian, Fedora, Arch, …).
# This does not use Anaconda. It unpacks a Fedora rootfs, then installs
# packages with the target's own dnf, the way debootstrap does for Debian.
#
# Interactive questions: disk, username, password, NVIDIA, display manager,
# dotfiles, applications.
#
# Non-interactive:
#   install-fedora.sh --yes --disk /dev/sdX --user osman --password 'secret' \
#     --nvidia no --dm ly --configs no --apps none
set -euo pipefail

export PATH="/usr/sbin:/sbin:/usr/bin:/bin:${PATH:-}"

RELEASE=44
DOTFILES_URL="${DOTFILES_URL:-https://github.com/osmancoskun/dotfiles.git}"
CACHE_DIR="${FEDORA_INSTALL_CACHE:-/var/tmp/fedora-install-cache}"
MIN_BYTES=$((16 * 1024 * 1024 * 1024))

ASSUME_YES=0
DISK=""
USER_NAME=""
PASSWORD=""
NVIDIA=""
DM=""
CONFIGS=""
APPS=""
HOSTNAME_NAME=""
TIMEZONE=""
SSH_KEY=""
EXTRA_KERNEL_ARGS=()

MNT=""
ROOT_UUID=""
BOOT_UUID=""

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: install-fedora.sh [OPTIONS]

Boot a live Linux system, run this as root, and it installs Fedora onto the
disk you choose. The target disk is erased.

Questions (skipped when the matching option is passed):
  disk              which disk to erase and install onto
  username          account name (default suggestion: osman)
  password          that account, also used for root
  NVIDIA            install the 580xx driver used by GTX 10-series
  display manager   ly, sddm, or none
  configs           clone and stow osmancoskun/dotfiles, plus Oh My Zsh
  applications      Chrome, VS Code, WARP, cloudflared, Cursor, Discord,
                    Docker CE, Steam

Options:
  --disk DEVICE
  --user NAME
  --password PASS
  --nvidia yes|no
  --dm ly|sddm|none
  --configs yes|no
  --apps none|all|chrome,vscode,warp,cloudflared,cursor,discord,docker,steam
  --hostname NAME          default: fedora
  --timezone ZONE          default: this live system's zone, else Europe/Istanbul
  --release N              Fedora release (default: 44)
  --kernel-arg ARG         extra kernel command-line argument (repeatable)
  --ssh-authorized-key FILE
  --yes                    do not ask for a final confirmation
  -h, --help
EOF
}

while (($#)); do
    case "$1" in
        --disk) DISK=$2; shift 2 ;;
        --user) USER_NAME=$2; shift 2 ;;
        --password) PASSWORD=$2; shift 2 ;;
        --nvidia) NVIDIA=$2; shift 2 ;;
        --dm) DM=$2; shift 2 ;;
        --configs) CONFIGS=$2; shift 2 ;;
        --apps) APPS=$2; shift 2 ;;
        --hostname) HOSTNAME_NAME=$2; shift 2 ;;
        --timezone) TIMEZONE=$2; shift 2 ;;
        --release) RELEASE=$2; shift 2 ;;
        --kernel-arg) EXTRA_KERNEL_ARGS+=("$2"); shift 2 ;;
        --ssh-authorized-key) SSH_KEY=$2; shift 2 ;;
        --yes) ASSUME_YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
done

[[ "$(id -u)" -eq 0 ]] || die "run this as root from the live system"

prompt() {
    local _var=$1 text=$2 default=${3:-}
    local reply
    if [[ -n "$default" ]]; then
        printf '%s [%s]: ' "$text" "$default" >&2
    else
        printf '%s: ' "$text" >&2
    fi
    IFS= read -r reply < /dev/tty
    if [[ -z "$reply" ]]; then
        reply=$default
    fi
    printf -v "$_var" '%s' "$reply"
}

prompt_yes_no() {
    local _var=$1 text=$2 default=$3 reply
    local hint=y/N
    [[ "$default" == "yes" ]] && hint=Y/n
    printf '%s [%s]: ' "$text" "$hint" >&2
    IFS= read -r reply < /dev/tty
    reply=${reply,,}
    if [[ -z "$reply" ]]; then
        printf -v "$_var" '%s' "$default"
    elif [[ "$reply" == y || "$reply" == yes ]]; then
        printf -v "$_var" '%s' yes
    elif [[ "$reply" == n || "$reply" == no ]]; then
        printf -v "$_var" '%s' no
    else
        die "answer yes or no"
    fi
}

normalize_yes_no() {
    local v=${1,,}
    case "$v" in
        y|yes) printf 'yes' ;;
        n|no) printf 'no' ;;
        *) return 1 ;;
    esac
}

list_disks() {
    local name type size model tran
    say ""
    say "Disks:"
    while read -r name type size model tran; do
        [[ "$type" == "disk" ]] || continue
        [[ "$name" =~ ^(zram|ram|fd|sr) ]] && continue
        printf '  /dev/%-12s %8s  %s %s\n' "$name" "$size" "$model" "$tran"
    done < <(lsblk -dn -o NAME,TYPE,SIZE,MODEL,TRAN)
    say ""
}

choose_disk() {
    [[ -n "$DISK" ]] && return 0
    [[ -r /dev/tty ]] || die "--disk is required when there is no terminal"
    list_disks
    local pick name
    prompt pick "Disk to erase (for example nvme0n1 or /dev/nvme0n1)"
    [[ -n "$pick" ]] || die "no disk selected"
    name=${pick#/dev/}
    DISK=/dev/$name
}

validate_disk() {
    [[ -b "$DISK" ]] || die "$DISK is not a block device"
    local type pk root_src root_disk
    type=$(lsblk -dno TYPE "$DISK")
    case "$type" in
        disk|loop) ;;
        *) die "$DISK is not a whole disk (type: ${type:-unknown})" ;;
    esac
    local name
    name=$(basename "$DISK")
    [[ "$name" =~ ^(zram|ram|fd|sr) ]] && die "$DISK cannot be an install target"

    root_src=$(findmnt -no SOURCE / 2>/dev/null || true)
    root_src=${root_src%%\[*}
    root_src=${root_src%% *}
    if [[ -n "$root_src" && -b "$root_src" ]]; then
        root_disk=$(lsblk -no PKNAME "$root_src" 2>/dev/null || true)
        if [[ -n "$root_disk" && "/dev/$root_disk" == "$DISK" ]]; then
            die "$DISK holds the running system and will not be erased"
        fi
    fi

    if lsblk -no MOUNTPOINTS "$DISK" | grep -q '[^[:space:]]'; then
        die "$DISK has a mounted filesystem. Unmount it first."
    fi

    local bytes
    bytes=$(blockdev --getsize64 "$DISK")
    (( bytes >= MIN_BYTES )) || die "$DISK is smaller than 16 GiB"
}

confirm_wipe() {
    local name size model
    name=$(basename "$DISK")
    size=$(lsblk -dno SIZE "$DISK")
    model=$(lsblk -dno MODEL "$DISK" | sed 's/[[:space:]]*$//')
    say ""
    say "Install plan"
    say "  disk        $DISK ($size ${model:-unknown})"
    say "  user        $USER_NAME  (root gets the same password)"
    say "  hostname    $HOSTNAME_NAME"
    say "  timezone    $TIMEZONE"
    say "  NVIDIA      $NVIDIA"
    say "  display     $DM"
    say "  configs     $CONFIGS"
    say "  apps        ${APPS:-none}"
    say "  release     Fedora $RELEASE"
    say "  layout      GPT, 600 MiB EFI, 2 GiB /boot, btrfs root + home"
    say ""
    say "This erases every partition on $DISK."
    (( ASSUME_YES )) && return 0
    local typed
    prompt typed "Type $name to continue"
    [[ "$typed" == "$name" ]] || die "confirmation did not match; nothing was written"
}

ask_questions() {
    choose_disk

    if [[ -z "$USER_NAME" ]]; then
        [[ -r /dev/tty ]] || die "--user is required when there is no terminal"
        prompt USER_NAME "Username" "osman"
    fi
    [[ "$USER_NAME" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "username must be a lowercase linux account name"
    [[ "$USER_NAME" != "root" ]] || die "username cannot be root"

    if [[ -z "$PASSWORD" ]]; then
        [[ -r /dev/tty ]] || die "--password is required when there is no terminal"
        local again
        printf 'Password (8 or more characters): ' >&2
        IFS= read -rs PASSWORD < /dev/tty
        printf '\n' >&2
        printf 'Password again: ' >&2
        IFS= read -rs again < /dev/tty
        printf '\n' >&2
        [[ "$PASSWORD" == "$again" ]] || die "passwords did not match"
    fi
    (( ${#PASSWORD} >= 8 )) || die "password must be at least 8 characters"
    [[ "$PASSWORD" != *$'\n'* ]] || die "password must be a single line"

    if [[ -z "$NVIDIA" ]]; then
        [[ -r /dev/tty ]] || die "--nvidia is required when there is no terminal"
        if command -v lspci >/dev/null 2>&1 && lspci -nn | grep -qi nvidia; then
            say "An NVIDIA device is visible on this machine:"
            lspci -nn | grep -i nvidia | sed 's/^/  /'
        else
            say "No NVIDIA device was detected from this live system (lspci missing or no device)."
        fi
        prompt_yes_no NVIDIA "Install the NVIDIA 580xx driver (GTX 10-series / Pascal)" no
    else
        NVIDIA=$(normalize_yes_no "$NVIDIA") || die "--nvidia must be yes or no"
    fi

    if [[ -z "$DM" ]]; then
        [[ -r /dev/tty ]] || die "--dm is required when there is no terminal"
        say ""
        say "Display manager:"
        say "  1) ly     (TUI, this machine's current login)"
        say "  2) sddm   (Fedora Sway default)"
        say "  3) none   (text console only)"
        local pick
        prompt pick "Choice" "1"
        case "$pick" in
            1|ly) DM=ly ;;
            2|sddm) DM=sddm ;;
            3|none) DM=none ;;
            *) die "display manager must be ly, sddm, or none" ;;
        esac
    fi
    case "$DM" in
        ly|sddm|none) ;;
        *) die "--dm must be ly, sddm, or none" ;;
    esac

    if [[ -z "$CONFIGS" ]]; then
        [[ -r /dev/tty ]] || die "--configs is required when there is no terminal"
        prompt_yes_no CONFIGS "Install your dotfiles and Oh My Zsh ($DOTFILES_URL)" yes
    else
        CONFIGS=$(normalize_yes_no "$CONFIGS") || die "--configs must be yes or no"
    fi

    if [[ -z "$APPS" ]]; then
        [[ -r /dev/tty ]] || die "--apps is required when there is no terminal"
        say ""
        say "Applications (empty skips, 0 selects all):"
        say "  1) Google Chrome"
        say "  2) Visual Studio Code"
        say "  3) Cloudflare WARP"
        say "  4) cloudflared"
        say "  5) Cursor"
        say "  6) Discord"
        say "  7) Docker CE + Compose"
        say "  8) Steam"
        local line
        prompt line "Numbers"
        APPS=$(apps_from_line "$line")
    else
        APPS=$(normalize_apps "$APPS")
    fi

    if [[ -z "$HOSTNAME_NAME" ]]; then
        HOSTNAME_NAME=fedora
    fi
    [[ "$HOSTNAME_NAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || die "invalid hostname"

    if [[ -z "$TIMEZONE" ]]; then
        local host_zone
        host_zone=$(readlink -f /etc/localtime 2>/dev/null || true)
        host_zone=${host_zone#/usr/share/zoneinfo/}
        if [[ -n "$host_zone" && "$host_zone" != /etc/localtime && -f "/usr/share/zoneinfo/$host_zone" ]]; then
            TIMEZONE=$host_zone
        else
            TIMEZONE=Europe/Istanbul
        fi
    fi
}

apps_from_line() {
    local line=$1
    line=${line//,/ }
    if [[ -z "${line// }" ]]; then
        printf 'none'
        return 0
    fi
    local -a keys=(chrome vscode warp cloudflared cursor discord docker steam)
    local -a want=()
    local token
    for token in $line; do
        if [[ "$token" == "0" || "$token" == "all" ]]; then
            printf 'all'
            return 0
        fi
        [[ "$token" =~ ^[1-8]$ ]] || die "unknown application number: $token"
        want+=("${keys[token-1]}")
    done
    local IFS=,
    printf '%s' "${want[*]}"
}

normalize_apps() {
    local raw=${1,,}
    raw=${raw// /}
    [[ "$raw" == "none" || -z "$raw" ]] && { printf 'none'; return 0; }
    [[ "$raw" == "0" || "$raw" == "all" ]] && { printf 'all'; return 0; }
    local IFS=,
    local -a parts
    read -ra parts <<< "$raw"
    local p
    for p in "${parts[@]}"; do
        case "$p" in
            chrome|vscode|warp|cloudflared|cursor|discord|docker|steam) ;;
            *) die "unknown application: $p" ;;
        esac
    done
    printf '%s' "$raw"
}

app_selected() {
    local key=$1
    [[ "$APPS" == "all" ]] && return 0
    [[ ",$APPS," == *",$key,"* ]]
}

part_dev() {
    local n=$1
    if [[ "$DISK" =~ [0-9]$ ]]; then
        printf '%sp%s' "$DISK" "$n"
    else
        printf '%s%s' "$DISK" "$n"
    fi
}

host_package_manager() {
    local id like
    id=""; like=""
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        id=${ID:-}
        like=${ID_LIKE:-}
    fi
    case "$id" in
        fedora|rhel|centos|nobara) printf 'dnf'; return ;;
        debian|ubuntu|linuxmint|pop) printf 'apt'; return ;;
        arch|manjaro|endeavouros) printf 'pacman'; return ;;
    esac
    case "$like" in
        *fedora*|*rhel*) printf 'dnf' ;;
        *debian*|*ubuntu*) printf 'apt' ;;
        *arch*) printf 'pacman' ;;
        *) die "this live system ($id) has no supported package manager (apt, dnf, or pacman)" ;;
    esac
}

ensure_host_tools() {
    local -A need=()
    if ! command -v sfdisk >/dev/null; then
        if [[ "$(host_package_manager)" == apt ]]; then
            need[fdisk]=1
        else
            need[util-linux]=1
        fi
    fi
    command -v lsblk >/dev/null || need[util-linux]=1
    command -v blkid >/dev/null || need[util-linux]=1
    command -v partx >/dev/null || need[util-linux]=1
    command -v findmnt >/dev/null || need[util-linux]=1
    command -v mkfs.vfat >/dev/null || need[dosfstools]=1
    command -v mkfs.ext4 >/dev/null || need[e2fsprogs]=1
    command -v mkfs.btrfs >/dev/null || need[btrfs-progs]=1
    command -v curl >/dev/null || need[curl]=1
    command -v tar >/dev/null || need[tar]=1
    if ! command -v xz >/dev/null; then
        local pm
        pm=$(host_package_manager)
        if [[ "$pm" == "apt" ]]; then
            need[xz-utils]=1
        else
            need[xz]=1
        fi
    fi
    ((${#need[@]})) || return 0

    local -a pkgs=()
    local k
    for k in "${!need[@]}"; do
        pkgs+=("$k")
    done
    say "Installing live-system tools: ${pkgs[*]}"
    local pm
    pm=$(host_package_manager)
    case "$pm" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y ca-certificates "${pkgs[@]}"
            ;;
        dnf)
            dnf install -y "${pkgs[@]}"
            ;;
        pacman)
            pacman -Sy --noconfirm "${pkgs[@]}"
            ;;
    esac
}

cleanup() {
    set +e
    if [[ -n "$MNT" && -d "$MNT" ]]; then
        umount -R "$MNT" 2>/dev/null
        rmdir "$MNT" 2>/dev/null
    fi
}
trap cleanup EXIT

ensure_part_node() {
    local n=$1 node name major minor
    node=$(part_dev "$n")
    [[ -b "$node" ]] && return 0
    name=$(basename "$node")
    [[ -r "/sys/class/block/$name/dev" ]] || return 1
    IFS=: read -r major minor < "/sys/class/block/$name/dev"
    mknod "$node" b "$major" "$minor"
    [[ -b "$node" ]]
}

wait_parts() {
    local i
    for i in 1 2 3 4 5 6 7 8; do
        partx -u "$DISK" 2>/dev/null || true
        ensure_part_node 1 || true
        ensure_part_node 2 || true
        ensure_part_node 3 || true
        if [[ -b "$(part_dev 1)" && -b "$(part_dev 2)" && -b "$(part_dev 3)" ]]; then
            return 0
        fi
        sleep 1
    done
    die "partition devices for $DISK did not appear"
}

partition_disk() {
    say "Partitioning $DISK"
    sfdisk --wipe always --force "$DISK" <<EOF
label: gpt
size=600MiB, type=uefi, name=EFI
size=2GiB, type=linux, name=boot
type=linux, name=fedora
EOF
    wait_parts
    local efi boot root
    efi=$(part_dev 1)
    boot=$(part_dev 2)
    root=$(part_dev 3)
    say "Creating filesystems"
    mkfs.vfat -F 32 -n EFI "$efi"
    mkfs.ext4 -F -L boot "$boot"
    mkfs.btrfs -f -L fedora "$root"
    BOOT_UUID=$(blkid -s UUID -o value "$boot")
    ROOT_UUID=$(blkid -s UUID -o value "$root")
    [[ -n "$BOOT_UUID" && -n "$ROOT_UUID" ]] || die "failed to read filesystem UUIDs"

    MNT=$(mktemp -d /mnt/fedora-install.XXXXXX)
    mount "$root" "$MNT"
    btrfs subvolume create "$MNT/root"
    btrfs subvolume create "$MNT/home"
    umount "$MNT"
    mount -o subvol=root,compress=zstd:1 "$root" "$MNT"
    mkdir -p "$MNT/home" "$MNT/boot"
    mount -o subvol=home,compress=zstd:1 "$root" "$MNT/home"
    mount "$boot" "$MNT/boot"
    mkdir -p "$MNT/boot/efi"
    mount "$efi" "$MNT/boot/efi"
}

fetch_rootfs() {
    local index latest url dest
    index="https://images.linuxcontainers.org/images/fedora/${RELEASE}/amd64/default/"
    say "Looking up the Fedora ${RELEASE} rootfs"
    latest=$(curl -fsSL "$index" | grep -oE '20[0-9]{6}_[0-9]{2}:[0-9]{2}/' | tail -1)
    [[ -n "$latest" ]] || die "no Fedora ${RELEASE} rootfs published at $index"
    url="${index}${latest}rootfs.tar.xz"
    mkdir -p "$CACHE_DIR"
    dest="$CACHE_DIR/fedora-${RELEASE}-rootfs.tar.xz"
    if [[ -s "$dest" ]]; then
        say "Using cached rootfs $dest"
    else
        say "Downloading $url"
        curl -fL --retry 3 -o "$dest.partial" "$url"
        mv "$dest.partial" "$dest"
    fi
    say "Unpacking Fedora into $MNT"
    tar -C "$MNT" --exclude='./dev/*' --exclude='./proc/*' --exclude='./sys/*' --exclude='./run/*' -xJf "$dest"
    mkdir -p "$MNT"/{dev,proc,sys,run,boot/efi,home}
}

mount_api() {
    mount --bind /dev "$MNT/dev"
    mount --bind /proc "$MNT/proc"
    mount --bind /sys "$MNT/sys"
    mount -t tmpfs tmpfs "$MNT/run"
    if [[ -d /sys/firmware/efi/efivars ]]; then
        mkdir -p "$MNT/sys/firmware/efi/efivars"
        mount -t efivarfs efivarfs "$MNT/sys/firmware/efi/efivars" || true
    fi
    rm -f "$MNT/etc/resolv.conf"
    if [[ -e /etc/resolv.conf ]]; then
        cp -L /etc/resolv.conf "$MNT/etc/resolv.conf"
    else
        printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$MNT/etc/resolv.conf"
    fi
}

target() {
    chroot "$MNT" "$@"
}

write_boot_config() {
    local cmdline args
    # selinux=0: this install is not labeled, and enforcing mode freezes systemd.
    args="root=UUID=${ROOT_UUID} ro rootflags=subvol=root rhgb quiet selinux=0"
    if [[ "$NVIDIA" == "yes" ]]; then
        args+=" nvidia-drm.modeset=1 rd.driver.blacklist=nouveau,nova_core modprobe.blacklist=nouveau,nova_core"
    fi
    local extra
    for extra in "${EXTRA_KERNEL_ARGS[@]}"; do
        args+=" $extra"
    done
    cmdline=$args

    mkdir -p "$MNT/etc/dnf" "$MNT/etc/dracut.conf.d" "$MNT/etc/kernel"
    if [[ -f "$MNT/etc/dnf/dnf.conf" ]] && ! grep -q '^max_parallel_downloads=' "$MNT/etc/dnf/dnf.conf"; then
        printf '\nmax_parallel_downloads=10\n' >> "$MNT/etc/dnf/dnf.conf"
    fi
    cat > "$MNT/etc/dracut.conf.d/99-fedora-install.conf" <<'EOF'
# Generic initramfs: the live system is not the installed machine.
hostonly="no"
hostonly_cmdline="no"
filesystems+=" btrfs "
EOF
    printf '%s\n' "$cmdline" > "$MNT/etc/kernel/cmdline"
    cat > "$MNT/etc/default/grub" <<EOF
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Fedora"
GRUB_DEFAULT=saved
GRUB_DISABLE_SUBMENU=true
GRUB_TERMINAL_OUTPUT="console"
GRUB_CMDLINE_LINUX="$cmdline"
GRUB_DISABLE_RECOVERY="true"
GRUB_ENABLE_BLSCFG=true
GRUB_DISABLE_OS_PROBER=true
EOF
    # cmdline must be newer than grub defaults so kernel-install keeps this line
    touch "$MNT/etc/kernel/cmdline"

    local efi_uuid
    efi_uuid=$(blkid -s UUID -o value "$(part_dev 1)")
    cat > "$MNT/etc/fstab" <<EOF
UUID=${ROOT_UUID}  /          btrfs  subvol=root,compress=zstd:1,ssd,discard=async,space_cache=v2  0 0
UUID=${ROOT_UUID}  /home      btrfs  subvol=home,compress=zstd:1,ssd,discard=async,space_cache=v2  0 0
UUID=${BOOT_UUID}  /boot      ext4   defaults  1 2
UUID=${efi_uuid}   /boot/efi  vfat   umask=0077,shortname=winnt  0 2
EOF

    printf '%s\n' "$HOSTNAME_NAME" > "$MNT/etc/hostname"
    cat > "$MNT/etc/hosts" <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME_NAME}
EOF
    ln -sfn "/usr/share/zoneinfo/${TIMEZONE}" "$MNT/etc/localtime"
    printf 'LANG=en_US.UTF-8\n' > "$MNT/etc/locale.conf"
    printf '%%wheel ALL=(ALL) ALL\n' > "$MNT/etc/sudoers.d/wheel"
    chmod 440 "$MNT/etc/sudoers.d/wheel"

    # kernel-install names boot entries with this id, so it has to exist first.
    if [[ -f "$MNT/etc/machine-id" ]] && ! grep -Eq '^[a-f0-9]{32}$' "$MNT/etc/machine-id"; then
        rm -f "$MNT/etc/machine-id"
    fi
    target systemd-machine-id-setup
}

install_base_packages() {
    local -a pkgs=(
        kernel linux-firmware
        grub2-efi-x64 shim-x64 grub2-tools grubby efibootmgr
        btrfs-progs e2fsprogs dosfstools
        NetworkManager openssh-server firewalld sudo shadow-utils passwd
        zram-generator-defaults polkit curl ca-certificates
        @swaywm @swaywm-extended
    )
    local -a excludes=()
    case "$DM" in
        ly)
            pkgs+=(ly)
            excludes+=(--exclude=sddm --exclude=sddm-wayland-sway)
            ;;
        sddm)
            pkgs+=(sddm sddm-wayland-sway)
            ;;
        none)
            excludes+=(--exclude=sddm --exclude=sddm-wayland-sway)
            ;;
    esac
    if [[ "$CONFIGS" == "yes" ]]; then
        pkgs+=(git stow zsh)
    fi
    say "Installing the base system (this downloads the desktop and kernel)"
    target dnf -y install "${excludes[@]}" "${pkgs[@]}"
    if [[ "$DM" != "sddm" ]]; then
        target dnf -y remove sddm sddm-wayland-sway >/dev/null 2>&1 || true
    fi
}

enable_unit() {
    local unit=$1 target_name=${2:-multi-user.target}
    local wants="$MNT/etc/systemd/system/${target_name}.wants/$unit"
    if target systemctl enable "$unit" && [[ -e "$wants" || -L "$wants" ]]; then
        return 0
    fi
    say "Linking $unit into ${target_name}.wants"
    local src=""
    if [[ "$unit" == *@* ]]; then
        src="/usr/lib/systemd/system/${unit%%@*}@.service"
    elif [[ -f "$MNT/usr/lib/systemd/system/$unit" ]]; then
        src="/usr/lib/systemd/system/$unit"
    elif [[ -f "$MNT/etc/systemd/system/$unit" ]]; then
        src="/etc/systemd/system/$unit"
    fi
    [[ -n "$src" && -e "$MNT$src" ]] || die "cannot enable $unit"
    mkdir -p "$MNT/etc/systemd/system/${target_name}.wants"
    ln -sfn "$src" "$MNT/etc/systemd/system/${target_name}.wants/$unit"
}

relax_selinux() {
    mkdir -p "$MNT/etc/selinux"
    if [[ -f "$MNT/etc/selinux/config" ]]; then
        sed -i 's/^SELINUX=.*/SELINUX=permissive/' "$MNT/etc/selinux/config"
    else
        printf '%s\n' 'SELINUX=permissive' 'SELINUXTYPE=targeted' > "$MNT/etc/selinux/config"
    fi
}

configure_system() {
    relax_selinux

    mkdir -p "$MNT/etc/security/pwquality.conf.d"
    printf '%s\n' 'minlen = 8' 'dictcheck = 0' > "$MNT/etc/security/pwquality.conf.d/installer.conf"
    target useradd -m -G wheel -s /bin/bash "$USER_NAME"
    printf '%s\n' "${USER_NAME}:${PASSWORD}" "root:${PASSWORD}" | target chpasswd

    enable_unit NetworkManager.service
    enable_unit sshd.service
    enable_unit firewalld.service || true
    target firewall-offline-cmd --add-service=ssh || true

    case "$DM" in
        ly)
            enable_unit ly@tty2.service
            if ! target systemctl set-default graphical.target; then
                ln -sfn /usr/lib/systemd/system/graphical.target "$MNT/etc/systemd/system/default.target"
            fi
            ;;
        sddm)
            enable_unit sddm.service graphical.target
            if ! target systemctl set-default graphical.target; then
                ln -sfn /usr/lib/systemd/system/graphical.target "$MNT/etc/systemd/system/default.target"
            fi
            ;;
        none)
            if ! target systemctl set-default multi-user.target; then
                ln -sfn /usr/lib/systemd/system/multi-user.target "$MNT/etc/systemd/system/default.target"
            fi
            ;;
    esac

    if [[ -n "$SSH_KEY" ]]; then
        [[ -f "$SSH_KEY" ]] || die "ssh key not found: $SSH_KEY"
        local home="$MNT/home/$USER_NAME"
        install -d -m 700 "$home/.ssh"
        cat "$SSH_KEY" >> "$home/.ssh/authorized_keys"
        chmod 600 "$home/.ssh/authorized_keys"
        target chown -R "${USER_NAME}:${USER_NAME}" "/home/${USER_NAME}/.ssh"
    fi
}

install_efi() {
    say "Installing the UEFI bootloader"
    target grub2-mkconfig -o /boot/grub2/grub.cfg
    local fedora_efi="$MNT/boot/efi/EFI/fedora"
    [[ -d "$fedora_efi" ]] || die "shim/grub did not land on the EFI system partition"
    local boot_efi="$MNT/boot/efi/EFI/BOOT"
    mkdir -p "$boot_efi"
    cp -a "$fedora_efi/"*.efi "$boot_efi/"
    if [[ -f "$fedora_efi/shimx64.efi" ]]; then
        cp -a "$fedora_efi/shimx64.efi" "$boot_efi/BOOTX64.EFI"
    elif [[ -f "$fedora_efi/shim.efi" ]]; then
        cp -a "$fedora_efi/shim.efi" "$boot_efi/BOOTX64.EFI"
    else
        die "shim EFI binary is missing from $fedora_efi"
    fi
    local stub
    for stub in "$fedora_efi/grub.cfg" "$boot_efi/grub.cfg"; do
        cat > "$stub" <<EOF
search --no-floppy --fs-uuid --set=dev ${BOOT_UUID}
set prefix=(\$dev)/grub2
export \$prefix
configfile \$prefix/grub.cfg
EOF
    done

    # os-prober is installed after the first grub.cfg so it cannot wander
    # onto the live system's disks. The first boot of the installed system
    # regenerates grub.cfg, which is when a UEFI boot can see Windows.
    target dnf -y install os-prober
    sed -i 's/^GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' "$MNT/etc/default/grub"
    mkdir -p "$MNT/var/lib/fedora-install" "$MNT/etc/systemd/system"
    : > "$MNT/var/lib/fedora-install/regenerate-grub"
    cat > "$MNT/usr/local/sbin/fedora-install-regen-grub" <<'EOF'
#!/bin/bash
set -euo pipefail
grub2-mkconfig -o /boot/grub2/grub.cfg.new
mv /boot/grub2/grub.cfg.new /boot/grub2/grub.cfg
rm -f /var/lib/fedora-install/regenerate-grub
EOF
    chmod 755 "$MNT/usr/local/sbin/fedora-install-regen-grub"
    cat > "$MNT/etc/systemd/system/fedora-install-regen-grub.service" <<'EOF'
[Unit]
Description=Regenerate GRUB once so other operating systems can be detected
ConditionPathExists=/var/lib/fedora-install/regenerate-grub
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/fedora-install-regen-grub

[Install]
WantedBy=multi-user.target
EOF
    enable_unit fedora-install-regen-grub.service

    if [[ -d /sys/firmware/efi/efivars ]]; then
        target efibootmgr -c -d "$DISK" -p 1 -L Fedora -l '\EFI\fedora\shimx64.efi' || \
            say "efibootmgr could not add an NVRAM entry; the EFI/BOOT fallback is still in place"
    else
        say "This live system is not booted in UEFI mode, so no NVRAM entry was created."
        say "The disk still has \\EFI\\BOOT\\BOOTX64.EFI. Switch the firmware to UEFI and boot this disk."
    fi
}

write_nvidia_session() {
    cat > "$MNT/usr/local/bin/start-sway-nvidia" <<'EOF'
#!/bin/bash
# NVIDIA session for ly. KVM and other VMs keep Fedora's start-sway.
set -euo pipefail
LOG="${XDG_STATE_HOME:-$HOME/.local/state}/sway-start.log"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
echo "==== $(date -Is) starting Sway Custom ===="

export XDG_CURRENT_DESKTOP="${XDG_CURRENT_DESKTOP:-sway}"
export XDG_SESSION_TYPE="${XDG_SESSION_TYPE:-wayland}"
export MOZ_ENABLE_WAYLAND=1

virt=$(systemd-detect-virt --vm || true)
if [[ "$virt" != "none" && -n "$virt" ]]; then
    exec /usr/bin/start-sway "$@"
fi

export WLR_RENDERER=vulkan
echo "renderer: $WLR_RENDERER"
started=$SECONDS
set +e
/usr/bin/start-sway --unsupported-gpu "$@"
status=$?
set -e
elapsed=$((SECONDS - started))
if [[ "$status" -ne 0 && "$elapsed" -lt 20 ]]; then
    echo "vulkan renderer failed (status $status after ${elapsed}s); falling back to gles2"
    export WLR_RENDERER=gles2
    exec /usr/bin/start-sway --unsupported-gpu "$@"
fi
exit "$status"
EOF
    chmod 755 "$MNT/usr/local/bin/start-sway-nvidia"
    cat > "$MNT/usr/share/wayland-sessions/sway-custom.desktop" <<'EOF'
[Desktop Entry]
Name=Sway Custom
Comment=Sway with the NVIDIA renderer
Exec=/usr/local/bin/start-sway-nvidia
Type=Application
DesktopNames=sway
EOF
    printf '%s\n' 'blacklist nouveau' 'blacklist nova_core' 'options nvidia-drm modeset=1' \
        > "$MNT/etc/modprobe.d/nvidia-blacklist.conf"
}

install_nvidia() {
    [[ "$NVIDIA" == "yes" ]] || return 0
    say "Installing the NVIDIA 580xx driver"
    local ver
    ver=$(target rpm -E %fedora)
    target dnf -y install \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${ver}.noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${ver}.noarch.rpm"
    if ! target dnf -y install akmod-nvidia-580xx xorg-x11-drv-nvidia-580xx nvidia-settings-580xx; then
        say "The driver could not be built in this live system. It will build on first boot."
        target dnf -y install --setopt=tsflags=noscripts \
            akmod-nvidia-580xx xorg-x11-drv-nvidia-580xx nvidia-settings-580xx
    fi
    enable_unit akmods.service || true
    write_nvidia_session
}

ensure_rpmfusion() {
    target rpm -q rpmfusion-nonfree-release >/dev/null 2>&1 && return 0
    local ver
    ver=$(target rpm -E %fedora)
    target dnf -y install \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${ver}.noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${ver}.noarch.rpm"
}

install_apps() {
    [[ "$APPS" == "none" ]] && return 0
    say "Installing selected applications"
    if app_selected discord || app_selected steam; then
        ensure_rpmfusion
    fi
    if app_selected chrome; then
        cat > "$MNT/etc/yum.repos.d/google-chrome.repo" <<'EOF'
[google-chrome]
name=google-chrome
baseurl=http://dl.google.com/linux/chrome/rpm/stable/x86_64
enabled=1
gpgcheck=1
gpgkey=https://dl.google.com/linux/linux_signing_key.pub
EOF
        target dnf -y install google-chrome-stable
    fi
    if app_selected vscode; then
        target rpm --import https://packages.microsoft.com/keys/microsoft.asc
        cat > "$MNT/etc/yum.repos.d/vscode.repo" <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
        target dnf -y install code
    fi
    if app_selected warp || app_selected cloudflared; then
        target rpm --import https://pkg.cloudflareclient.com/pubkey.gpg
        curl -fsSL -o "$MNT/etc/yum.repos.d/cloudflare-warp.repo" \
            https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo
    fi
    if app_selected warp; then
        target dnf -y install cloudflare-warp
    fi
    if app_selected cloudflared; then
        if ! target dnf -y install cloudflared; then
            curl -fL --retry 3 -o /tmp/cloudflared-linux-x86_64.rpm \
                https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-x86_64.rpm
            cp /tmp/cloudflared-linux-x86_64.rpm "$MNT/tmp/cloudflared-linux-x86_64.rpm"
            target dnf -y install /tmp/cloudflared-linux-x86_64.rpm
        fi
    fi
    if app_selected cursor; then
        cat > "$MNT/etc/yum.repos.d/cursor.repo" <<'EOF'
[cursor]
name=Cursor
baseurl=https://downloads.cursor.com/yumrepo
enabled=1
gpgcheck=1
gpgkey=https://downloads.cursor.com/keys/anysphere.asc
EOF
        target dnf -y install cursor
    fi
    if app_selected discord; then
        target dnf -y install discord
    fi
    if app_selected docker; then
        cat > "$MNT/etc/yum.repos.d/docker-ce.repo" <<'EOF'
[docker-ce-stable]
name=Docker CE Stable
baseurl=https://download.docker.com/linux/fedora/$releasever/$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://download.docker.com/linux/fedora/gpg
EOF
        target rpm --import https://download.docker.com/linux/fedora/gpg || true
        target dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        enable_unit docker.service
        target usermod -aG docker "$USER_NAME"
    fi
    if app_selected steam; then
        target dnf -y install steam
    fi
}

install_configs() {
    [[ "$CONFIGS" == "yes" ]] || return 0
    say "Installing dotfiles and Oh My Zsh"
    if [[ ! -d "$MNT/home/${USER_NAME}/.dotfiles/.git" ]]; then
        target git clone --depth 1 "$DOTFILES_URL" "/home/${USER_NAME}/.dotfiles"
    fi
    target chown -R "${USER_NAME}:${USER_NAME}" "/home/${USER_NAME}/.dotfiles"
    # useradd copies /etc/skel/.zshrc from the zsh package. Stow will not
    # replace that regular file unless it is removed first.
    target runuser -u "$USER_NAME" -- bash -s <<'EOF'
set -euo pipefail
cd "$HOME/.dotfiles/home"
while IFS= read -r -d '' src; do
    dest="$HOME/${src#./}"
    if [[ -e "$dest" && ! -L "$dest" ]]; then
        echo "replacing existing $dest"
        rm -rf "$dest"
    fi
done < <(find . -mindepth 1 \( -type f -o -type l \) -print0)
stow --restow --target="$HOME" --dir="$HOME/.dotfiles" home
EOF
    target runuser -u "$USER_NAME" -- bash -s <<'EOF'
set -euo pipefail
if [[ ! -f "$HOME/.oh-my-zsh/oh-my-zsh.sh" ]]; then
    KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
fi
mkdir -p "$HOME/.oh-my-zsh/custom/plugins"
clone_plugin() {
    local name=$1 url=$2 dest="$HOME/.oh-my-zsh/custom/plugins/$1"
    if [[ ! -d "$dest/.git" ]]; then
        git clone --depth 1 "$url" "$dest"
    fi
}
clone_plugin zsh-autosuggestions https://github.com/zsh-users/zsh-autosuggestions
clone_plugin zsh-syntax-highlighting https://github.com/zsh-users/zsh-syntax-highlighting.git
clone_plugin zsh-history-substring-search https://github.com/zsh-users/zsh-history-substring-search
EOF
    target chsh -s /bin/zsh "$USER_NAME"
}

verify_install() {
    [[ -f "$MNT/boot/efi/EFI/BOOT/BOOTX64.EFI" ]] || die "EFI fallback bootloader is missing"
    compgen -G "$MNT/boot/loader/entries/*.conf" >/dev/null || die "no boot loader entry was created"
    grep -q "root=UUID=${ROOT_UUID}" "$MNT"/boot/loader/entries/*.conf || die "boot entry is missing the root filesystem"
    grep -q 'rootflags=subvol=root' "$MNT"/boot/loader/entries/*.conf || die "boot entry is missing the btrfs subvolume"
    [[ -x "$MNT/usr/bin/sway" ]] || die "sway was not installed"
    case "$DM" in
        ly) [[ -x "$MNT/usr/bin/ly" ]] || die "ly was not installed" ;;
        sddm) [[ -x "$MNT/usr/bin/sddm" ]] || die "sddm was not installed" ;;
    esac
}

write_stamp() {
    cat > "$MNT/etc/fedora-install.conf" <<EOF
user=${USER_NAME}
nvidia=${NVIDIA}
dm=${DM}
configs=${CONFIGS}
apps=${APPS}
release=${RELEASE}
EOF
}

main() {
    ensure_host_tools
    ask_questions
    validate_disk
    confirm_wipe
    partition_disk
    fetch_rootfs
    mount_api
    write_boot_config
    install_base_packages
    configure_system
    install_efi
    install_nvidia
    install_apps
    install_configs
    # A later package install can restore the stock enforcing policy config.
    relax_selinux
    verify_install
    write_stamp
    target dnf -y clean all || true
    sync
    say ""
    say "Fedora ${RELEASE} is installed on ${DISK}."
    say "  UEFI boot file: \\EFI\\BOOT\\BOOTX64.EFI"
    say "  user ${USER_NAME}, root password is the same"
    say "  SELinux is permissive because the install was not labeled by Anaconda."
    if [[ "$NVIDIA" == "yes" ]]; then
        say "  At ly, pick the Sway Custom session."
    fi
    if [[ "$DM" == "ly" ]]; then
        say "  ly listens on tty2. tty1 stays a text console."
    fi
}

main
