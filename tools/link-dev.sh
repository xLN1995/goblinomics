#!/usr/bin/env bash
# Link the repo's addon folders into the WoW Retail AddOns directory for development.
#
#   tools/link-dev.sh            create/update symlinks (idempotent)
#   tools/link-dev.sh --status   show link -> target and whether it resolves
#   tools/link-dev.sh --unlink   remove only symlinks that point into this repo
#   tools/link-dev.sh --prune    remove dangling symlinks in the AddOns folder (asks first)
#
# Override the AddOns path with WOW_ADDONS=/path/to/Interface/AddOns.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADDONS="${WOW_ADDONS:-$HOME/Games/World of Warcraft/_retail_/Interface/AddOns}"

# link name : path relative to repo root
PAIRS=(
    "Goblinomics:."
    "Goblinomics_Vault:Modules/Vault"
    "Goblinomics_Ledger:Modules/Ledger"
    "Goblinomics_Gatherer:Modules/Gatherer"
    "Goblinomics_Workshop:Modules/Workshop"
    "Goblinomics_Insights:Modules/Insights"
    "Goblinomics_Link:Modules/Link"
    "Goblinomics_Import:Modules/Import"
    "Goblinomics_Connector_TSM:Connectors/TSM"
    "Goblinomics_Connector_Auctionator:Connectors/Auctionator"
    "Goblinomics_Connector_CraftSim:Connectors/CraftSim"
    "Goblinomics_Connector_GatherMate2:Connectors/GatherMate2"
)

if [[ ! -d "$ADDONS" ]]; then
    echo "AddOns folder not found: $ADDONS" >&2
    echo "Set WOW_ADDONS to your Interface/AddOns path." >&2
    exit 1
fi

link_all() {
    for pair in "${PAIRS[@]}"; do
        name="${pair%%:*}"; rel="${pair#*:}"
        src="$(cd "$REPO/$rel" && pwd)"
        dst="$ADDONS/$name"
        if [[ -e "$dst" && ! -L "$dst" ]]; then
            echo "SKIP    $name (a real directory exists at the target)"
            continue
        fi
        ln -sfn "$src" "$dst"
        echo "LINKED  $name -> $src"
    done
    echo
    echo "Restart the client once so it picks up new addon folders; afterwards /reload is enough."
}

status_all() {
    for pair in "${PAIRS[@]}"; do
        name="${pair%%:*}"
        dst="$ADDONS/$name"
        if [[ -L "$dst" ]]; then
            target="$(readlink "$dst")"
            if [[ -e "$dst" ]]; then state="OK"; else state="DANGLING"; fi
            printf '%-36s -> %s [%s]\n' "$name" "$target" "$state"
        elif [[ -e "$dst" ]]; then
            printf '%-36s    (real directory, not managed)\n' "$name"
        else
            printf '%-36s    (missing)\n' "$name"
        fi
    done
}

unlink_all() {
    for pair in "${PAIRS[@]}"; do
        name="${pair%%:*}"
        dst="$ADDONS/$name"
        if [[ -L "$dst" ]]; then
            target="$(readlink "$dst")"
            if [[ "$target" == "$REPO"* ]]; then
                rm "$dst"
                echo "REMOVED $name"
            else
                echo "KEPT    $name (points elsewhere: $target)"
            fi
        fi
    done
}

prune_dangling() {
    mapfile -t dangling < <(find "$ADDONS" -maxdepth 1 -type l ! -exec test -e {} \; -print)
    if [[ ${#dangling[@]} -eq 0 ]]; then
        echo "No dangling symlinks."
        return
    fi
    echo "Dangling symlinks in $ADDONS:"
    for l in "${dangling[@]}"; do
        printf '  %s -> %s\n' "$(basename "$l")" "$(readlink "$l")"
    done
    read -r -p "Remove them? [y/N] " answer
    if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
        for l in "${dangling[@]}"; do rm "$l"; echo "REMOVED $(basename "$l")"; done
    else
        echo "Nothing removed."
    fi
}

case "${1:-}" in
    "")         link_all ;;
    --status)   status_all ;;
    --unlink)   unlink_all ;;
    --prune)    prune_dangling ;;
    *)          echo "Usage: $0 [--status|--unlink|--prune]" >&2; exit 2 ;;
esac
