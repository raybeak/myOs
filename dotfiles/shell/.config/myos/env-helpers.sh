# Workspace .env pure-GPG Dual-Recipient helpers (no plaintext on disk)
_resolve_env_gpg() {
    if [[ -n "${ENV_GPG_FILE:-}" ]]; then
        echo "$ENV_GPG_FILE"
    elif [[ -f ".env.gpg" ]]; then
        echo ".env.gpg"
    elif [[ -f "$HOME/workspace/.env.gpg" ]]; then
        echo "$HOME/workspace/.env.gpg"
    else
        echo ".env.gpg"
    fi
}

envlock() {
    local src="${1:-}"
    if [[ -z "$src" ]]; then
        if [[ -f ".env" ]]; then
            src=".env"
        else
            src="$HOME/workspace/.env"
        fi
    fi
    local dst="${2:-${src}.gpg}"
    local recips_file="$HOME/.config/myos/gpg-recipients"
    if [[ ! -f "$src" ]]; then
        echo "envlock: $src not found" >&2
        return 1
    fi
    if [[ ! -s "$recips_file" ]]; then
        echo "envlock: $recips_file missing or empty" >&2
        return 1
    fi
    local args=() line
    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line// /}"
        [[ -z "$line" ]] && continue
        args+=(-r "$line")
    done < "$recips_file"
    if (( ${#args[@]} == 0 )); then
        echo "envlock: no recipients found in $recips_file" >&2
        return 1
    fi
    gpg --yes --encrypt --armor "${args[@]}" -o "$dst" "$src"
}

envview() {
    local src="${1:-$(_resolve_env_gpg)}"
    if [[ ! -f "$src" ]]; then
        echo "envview: $src not found" >&2
        return 1
    fi
    gpg --quiet --decrypt "$src"
}

envrun() {
    local enc="$(_resolve_env_gpg)"
    if [[ ! -f "$enc" ]]; then
        echo "envrun: $enc not found" >&2
        return 1
    fi
    if (( $# == 0 )); then
        echo "Usage: envrun <command> [args...]" >&2
        return 1
    fi
    local dec
    dec="$(gpg --quiet --decrypt "$enc")" || return 1
    (
        set -a
        # shellcheck disable=SC1090
        source <(printf '%s\n' "$dec")
        set +a
        unset dec enc
        exec "$@"
    )
}
