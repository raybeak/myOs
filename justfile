# myOs deterministic read-only verification entrypoint

default:
    @just --list

# Run all read-only verification checks
check: lint-sh lint-sway eval-sweeper

# Check POSIX login scripts and Bash tooling
lint-sh:
    #!/usr/bin/env bash
    set -euo pipefail
    shopt -s nullglob
    sh -n dotfiles/shell/.profile
    shellcheck -s sh -S error dotfiles/shell/.profile
    bash_scripts=(bootstrap.sh etc/local-sbin/myos-battery-ctl dotfiles/shell/.config/myos/env-helpers.sh dotfiles/myos-bin/.local/bin/* dotfiles/waybar/.config/waybar/*.sh dotfiles/sway/.config/sway/scripts/*.sh)
    if ((${#bash_scripts[@]} > 0)); then
        bash -n "${bash_scripts[@]}"
        shellcheck -s bash -S error "${bash_scripts[@]}"
    fi

# Validate Sway configuration syntax
lint-sway:
    sway -C -c dotfiles/sway/.config/sway/config

# Verify all packages in packagesV2.txt exist in local apt cache
check-packages:
    grep -Ev '^\s*(#|$)' packagesV2.txt | sed 's/#.*//' | xargs -r apt-cache show >/dev/null

# Run myosSweeper offline evaluation suite
eval-sweeper:
    @if [ -f sweeper/evals/runEval.py ]; then python3 sweeper/evals/runEval.py; fi
