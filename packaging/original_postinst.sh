#!/bin/sh
set -eu

case "${1:-}" in
    configure) ;;
    *) exit 0 ;;
esac

PATH="/usr/bin:/bin:/usr/bin:/bin"
export PATH
bundle="/Library/Application Support/PetDFY.bundle"
if [ ! -d "$bundle" ] || [ -L "$bundle" ]; then exit 1; fi

# Upgrades can retain root-owned directories despite the archive's owner fields.
# Prepare only the three resource directories for the mobile helper process.
for name in originals live .asset-state; do
    directory="$bundle/$name"
    if [ ! -d "$directory" ] || [ -L "$directory" ]; then exit 1; fi
    chown -hR 501:501 "$directory"
    if [ "$name" = .asset-state ]; then
        chmod 0700 "$directory"
    else
        chmod 0755 "$directory"
    fi
done
