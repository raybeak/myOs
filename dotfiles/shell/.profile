# ~/.profile: executed by the command interpreter for login shells.
# This file is not read by bash(1), if ~/.bash_profile or ~/.bash_login
# exists.
# see /usr/share/doc/bash/examples/startup-files for examples.
# the files are located in the bash-doc package.

# the default umask is set in /etc/profile; for setting the umask
# for ssh logins, install and configure the libpam-umask package.
#umask 022

# if running bash
if [ -n "$BASH_VERSION" ]; then
    # include .bashrc if it exists
    if [ -f "$HOME/.bashrc" ]; then
	. "$HOME/.bashrc"
    fi
fi

# set PATH so it includes user's private bin if it exists
if [ -d "$HOME/bin" ] ; then
    PATH="$HOME/bin:$PATH"
fi

# set PATH so it includes user's private bin if it exists
if [ -d "$HOME/.local/bin" ] ; then
    PATH="$HOME/.local/bin:$PATH"
fi
if [ -f "$HOME/.cargo/env" ]; then
    . "$HOME/.cargo/env"
fi

export EDITOR=micro
export VISUAL=micro
export SUDO_EDITOR=micro

# Added by Antigravity CLI installer
if [ -d "$HOME/.local/bin" ]; then
    export PATH="$HOME/.local/bin:$PATH"
fi
export SSH_AUTH_SOCK="$(gpgconf --list-dirs agent-ssh-socket)"

if [ -n "${BASH_VERSION:-}" ] && [ -f "$HOME/.config/myos/env-helpers.sh" ]; then
    . "$HOME/.config/myos/env-helpers.sh"
fi


# Added by Antigravity CLI installer
export PATH="/home/raybeak/.local/bin:$PATH"
