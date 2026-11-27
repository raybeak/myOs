# myOs deterministic read-only verification entrypoint

default:
    @just --list

# Run all read-only verification checks
check: lint-sh lint-sway check-security eval-sweeper

# Check POSIX login scripts and Bash tooling
lint-sh:
    #!/usr/bin/env bash
    set -euo pipefail
    shopt -s nullglob
    sh -n dotfiles/shell/.profile
    shellcheck -s sh -S error dotfiles/shell/.profile
    bash_scripts=(bootstrap.sh sweeper/installSweeper.sh etc/local-sbin/myos-battery-ctl dotfiles/shell/.config/myos/env-helpers.sh dotfiles/myos-bin/.local/bin/* dotfiles/waybar/.config/waybar/*.sh dotfiles/sway/.config/sway/scripts/*.sh)
    if ((${#bash_scripts[@]} > 0)); then
        bash -n "${bash_scripts[@]}"
        shellcheck -s bash -S error "${bash_scripts[@]}"
    fi

# Validate Sway configuration syntax
lint-sway:
    sway -C -c dotfiles/sway/.config/sway/config

# Read-only security hygiene checks (no sudo or mutation)
check-security:
    #!/usr/bin/env bash
    set -euo pipefail
    if grep -Eq 'curl[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh' bootstrap.sh sweeper/installSweeper.sh; then
        echo "ERR: unverified curl|sh pipeline detected" >&2
        exit 1
    fi
    if git grep -nE '(BEGIN (RSA|OPENSSH|PGP|EC) PRIVATE KEY|ghp_[A-Za-z0-9]{20,}|OPENGATEWAY_API_KEY=)' -- . ':!justfile'; then
        echo "ERR: potential secret material found in tracked files" >&2
        exit 1
    fi
    for f in dotfiles/myos-bin/.local/bin/* etc/local-sbin/*; do
        if [[ ! -x "$f" ]]; then
            echo "ERR: missing executable bit on $f" >&2
            exit 1
        fi
    done
    python3 -m json.tool etc/docker/daemon.json >/dev/null
    python3 -m json.tool dotfiles/waybar/.config/waybar/config >/dev/null

# Verify all packages in packagesV2.txt exist in local apt cache
check-packages:
    grep -Ev '^\s*(#|$)' packagesV2.txt | sed 's/#.*//' | xargs -r apt-cache show >/dev/null

# Run myosSweeper offline evaluation suite
eval-sweeper:
    @if [ -f sweeper/evals/runEval.py ]; then python3 sweeper/evals/runEval.py; fi
