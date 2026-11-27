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
    local tmp_dst
    tmp_dst="$(umask 077 && mktemp "${dst}.tmp.XXXXXX")" || return 1
    if ! (
        umask 077
        gpg --yes --encrypt --armor "${args[@]}" -o "$tmp_dst" "$src"
    ); then
        rm -f "$tmp_dst"
        return 1
    fi
    chmod 600 "$tmp_dst" && mv -f "$tmp_dst" "$dst" || {
        rm -f "$tmp_dst"
        return 1
    }
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
    local enc
    enc="$(_resolve_env_gpg)"
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
        local line trimmed key val
        while IFS= read -r line || [[ -n "$line" ]]; do
            trimmed="${line#"${line%%[![:space:]]*}"}"
            trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
            [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue
            if [[ "$trimmed" == export[[:space:]]* ]]; then
                trimmed="${trimmed#export}"
                trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
            fi
            if [[ "$trimmed" != *=* ]]; then
                echo "envrun: malformed line in $enc" >&2
                exit 1
            fi
            key="${trimmed%%=*}"
            val="${trimmed#*=}"
            if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
                echo "envrun: invalid variable name '$key' in $enc" >&2
                exit 1
            fi
            if [[ "${val:0:1}" == "'" || "${val: -1}" == "'" ]]; then
                if [[ "${#val}" -lt 2 || "${val:0:1}" != "'" || "${val: -1}" != "'" ]]; then
                    echo "envrun: unmatched single quote for '$key' in $enc" >&2
                    exit 1
                fi
                val="${val:1:${#val}-2}"
            elif [[ "${val:0:1}" == '"' || "${val: -1}" == '"' ]]; then
                if [[ "${#val}" -lt 2 || "${val:0:1}" != '"' || "${val: -1}" != '"' ]]; then
                    echo "envrun: unmatched double quote for '$key' in $enc" >&2
                    exit 1
                fi
                val="${val:1:${#val}-2}"
            elif [[ "$val" == *'$('* || "$val" == *'`'* ]]; then
                echo "envrun: unsupported unquoted shell substitution for '$key' in $enc" >&2
                exit 1
            fi
            export "${key}=${val}"
        done <<< "$dec"
        unset dec enc line trimmed key val
        exec "$@"
    )
}
