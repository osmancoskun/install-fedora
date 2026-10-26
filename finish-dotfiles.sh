#!/usr/bin/env bash
# Finish dotfiles on an already installed disk after stow stopped on ~/.zshrc.
# Run from the live system: sudo bash finish-dotfiles.sh
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    exec sudo bash "$0" "$@"
fi

PART=$(blkid -t LABEL=fedora -o device | head -1)
[[ -n "$PART" ]] || { echo "No filesystem labeled fedora. Is the install disk attached?" >&2; exit 1; }

MNT=$(mktemp -d /mnt/fedora-finish.XXXXXX)
cleanup() {
    set +e
    umount -R "$MNT" 2>/dev/null
    rmdir "$MNT" 2>/dev/null
}
trap cleanup EXIT

mount -o subvol=root "$PART" "$MNT"
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

USER_NAME=$(awk -F: '$3 == 1000 { print $1; exit }' "$MNT/etc/passwd")
[[ -n "$USER_NAME" ]] || { echo "No uid 1000 user on the installed system." >&2; exit 1; }
echo "Finishing dotfiles for $USER_NAME"

if [[ ! -d "$MNT/home/${USER_NAME}/.dotfiles/.git" ]]; then
    chroot "$MNT" git clone --depth 1 https://github.com/osmancoskun/dotfiles.git "/home/${USER_NAME}/.dotfiles"
fi
chroot "$MNT" chown -R "${USER_NAME}:${USER_NAME}" "/home/${USER_NAME}/.dotfiles"
chroot "$MNT" runuser -u "$USER_NAME" -- bash -s <<'EOF'
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
chroot "$MNT" chsh -s /bin/zsh "$USER_NAME"
echo "Dotfiles are linked for $USER_NAME."
