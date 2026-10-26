#!/usr/bin/env bash
# Apply portable desktop and shell settings to an installed Fedora system.
# Run from the live system: sudo bash finish-dotfiles.sh /dev/ROOT_PARTITION
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    exec sudo bash "$0" "$@"
fi

# --installed repairs the running Fedora system without mounting a disk.
if [[ ${1:-} == --installed ]]; then
    [[ $# -le 2 ]] || { echo "Usage: $0 --installed [USER]" >&2; exit 1; }
    [[ -f /etc/fedora-release ]] || { echo "Run --installed inside Fedora" >&2; exit 1; }
    MNT=""
    target() { "$@"; }
else
    [[ $# -eq 1 ]] || { echo "Usage: sudo bash $0 /dev/ROOT_PARTITION" >&2; exit 1; }
    PART=$(readlink -f "$1")
    [[ -b "$PART" ]] || { echo "Not a block device: $PART" >&2; exit 1; }
    [[ "$(blkid -s TYPE -o value "$PART")" == btrfs ]] || { echo "Expected a Btrfs root partition" >&2; exit 1; }
    [[ -z "$(lsblk -no MOUNTPOINTS "$PART" | tr -d '[:space:]')" ]] || { echo "Partition is already mounted" >&2; exit 1; }

    MNT=$(mktemp -d /mnt/fedora-finish.XXXXXX)
    cleanup() {
        set +e
        umount -R "$MNT" 2>/dev/null
        rmdir "$MNT" 2>/dev/null
    }
    trap cleanup EXIT

    mount -o subvol=root "$PART" "$MNT"
    [[ -f "$MNT/etc/fedora-install.conf" || -f "$MNT/etc/fedora-release" ]] || { echo "Not a Fedora installation" >&2; exit 1; }
    mount -o subvol=home "$PART" "$MNT/home"
    mount --bind /dev "$MNT/dev"
    mount --bind /proc "$MNT/proc"
    mount --bind /sys "$MNT/sys"
    rm -f "$MNT/etc/resolv.conf"
    if [[ -e /etc/resolv.conf ]]; then
        cp -L /etc/resolv.conf "$MNT/etc/resolv.conf"
    else
        printf 'nameserver 1.1.1.1\n' > "$MNT/etc/resolv.conf"
    fi

    target() { chroot "$MNT" "$@"; }
fi

USER_NAME=$(awk -F: '$3 == 1000 { print $1; exit }' "$MNT/etc/passwd")
if [[ ${1:-} == --installed && -n ${2:-} ]]; then USER_NAME=$2; fi
id_check=$(target id -u "$USER_NAME")
[[ $id_check -ge 1000 ]] || { echo "Expected a normal user" >&2; exit 1; }
[[ -n "$USER_NAME" ]] || { echo "No uid 1000 user on the installed system." >&2; exit 1; }
echo "Finishing dotfiles for $USER_NAME"

target dnf -y install git zsh vim-enhanced foot alacritty waybar rofi jq cascadia-code-fonts fontawesome-6-free-fonts fontawesome-6-brands-fonts
target runuser -u "$USER_NAME" -- bash -s -- "${DOTFILES_URL:-https://github.com/osmancoskun/dotfiles.git}" <<'EOF'
set -euo pipefail
repo="$HOME/.dotfiles"
if [[ ! -d "$repo/.git" ]]; then
    git clone --depth 1 --filter=blob:none --no-checkout "$1" "$repo"
fi
# Only portable desktop files are checked out. Old display layouts stay out.
git -C "$repo" sparse-checkout set --no-cone \
    '/home/.zshrc' '/home/.vimrc' \
    '/home/.config/sway/' '/home/.config/waybar/' \
    '/home/.config/foot/' '/home/.config/alacritty/' \
    '!/home/.config/sway/config.d/*monitor*' \
    '!/home/.config/sway/scripts/*monitor*' \
    '!/home/.config/sway/wallpaper-daily.env'
git -C "$repo" checkout
backup() {
    if [[ -e "$1" || -L "$1" ]]; then
        mv -- "$1" "$1.before-fedora-install.$(date +%s%N)"
    fi
}
for name in .zshrc .vimrc; do
    [[ -f "$repo/home/$name" ]] || continue
    dest="$HOME/$name"
    [[ -L "$dest" && $(readlink "$dest") == "$repo/home/$name" ]] && continue
    backup "$dest"
    ln -s "$repo/home/$name" "$dest"
done
mkdir -p "$HOME/.config"
for name in sway waybar foot alacritty; do
    [[ -d "$repo/home/.config/$name" ]] || continue
    backup "$HOME/.config/$name"
    cp -a "$repo/home/.config/$name" "$HOME/.config/$name"
done
if [[ -f "$HOME/.config/sway/config" ]]; then
    # Drop the old laptop scale and any workspace/output assignments.
    # Sway detects connected outputs and chooses their preferred modes.
    sed -i -E '/^[[:space:]]*output[[:space:]]/d; /^[[:space:]]*workspace[[:space:]].*[[:space:]]output[[:space:]]/d' "$HOME/.config/sway/config"
fi
if [[ -f "$HOME/.config/sway/wallpaper-daily.env.example" ]]; then
    cp "$HOME/.config/sway/wallpaper-daily.env.example" "$HOME/.config/sway/wallpaper-daily.env"
fi
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
target restorecon -RF "/home/$USER_NAME"
echo "Dotfiles are linked for $USER_NAME."
