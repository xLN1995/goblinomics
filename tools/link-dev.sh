#!/usr/bin/env bash
# Link the repo's addon folders into a WoW AddOns directory for development.
#
#   tools/link-dev.sh                        create/update symlinks in Retail (idempotent)
#   tools/link-dev.sh --forever              the same for WoW: Forever (_forever_)
#   tools/link-dev.sh [--forever] --status   show link -> target and whether it resolves
#   tools/link-dev.sh [--forever] --unlink   remove only symlinks that point into this repo
#   tools/link-dev.sh [--forever] --prune    remove dangling symlinks in the AddOns folder (asks first)
#
# The WoW folder is guessed (~/Games/World of Warcraft, or a Wine prefix under
# ~/Games/battlenet or ~/.wine). Override the AddOns path with
# WOW_ADDONS=/path/to/Interface/AddOns; --forever swaps _retail_ for _forever_ in it.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLAVOR="_retail_"
ACTION=""
for arg in "$@"; do
    case "$arg" in
        --forever) FLAVOR="_forever_" ;;
        --retail)  FLAVOR="_retail_" ;;
        --status|--unlink|--prune) ACTION="$arg" ;;
        *) echo "Usage: $0 [--forever] [--status|--unlink|--prune]" >&2; exit 2 ;;
    esac
done

guess_addons() {
    local root
    for root in "$HOME/Games/World of Warcraft" \
                "$HOME/Games/battlenet/drive_c/Program Files (x86)/World of Warcraft" \
                "$HOME/.wine/drive_c/Program Files (x86)/World of Warcraft"; do
        if [[ -d "$root/$FLAVOR/Interface/AddOns" ]]; then
            echo "$root/$FLAVOR/Interface/AddOns"
            return
        fi
    done
    echo "$HOME/Games/World of Warcraft/$FLAVOR/Interface/AddOns"
}
if [[ -n "${WOW_ADDONS:-}" ]]; then
    ADDONS="${WOW_ADDONS/_retail_/$FLAVOR}"
else
    ADDONS="$(guess_addons)"
fi

# link name : path relative to repo root
PAIRS=(
    "Goblinomics:."
    "Goblinomics_Vault:Modules/Vault"
    "Goblinomics_Ledger:Modules/Ledger"
    "Goblinomics_Flips:Modules/Flips"
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
    echo "Set WOW_ADDONS to your Interface/AddOns path (--forever swaps _retail_ for _forever_)." >&2
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

case "$ACTION" in
    "")         link_all ;;
    --status)   status_all ;;
    --unlink)   unlink_all ;;
    --prune)    prune_dangling ;;
esac
