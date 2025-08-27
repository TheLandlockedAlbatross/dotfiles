alias a=alias
alias n='nvim '
alias rg="rg --hidden --glob '!.git' --glob '!.svn' --path-separator / "
alias rp="realpath"
alias ssh='sshrc'
alias v='vim '
alias vr='vim -R '
# Show all current single character aliases and functions
s () {
    echo "Single Character Aliases: "
    alias | \grep -o ' .=.*' | sed -nr "s/^ /\t/p"
    echo "Single Character Functions: "
    cat ~/.bashrc | \grep -Pzo '#.*\n. \(\).*\n' | sed -nr "s/^(. |# )/\t\1/p"
}

# Make a directory and cd into it immediately
mcd_func () {
    mkdir -p "${1}"
    cd "${1}"
}
alias mcd=mcd_func

# Show hexcode color (w/o #)
showcolor() {
    perl -e 'foreach $a(@ARGV){print "\e[48:2::".join(":",unpack("C*",pack("H*",$a)))."m \e[49m "};print "\n"' "$@"
}

# Persist as much config as possible when switching to root
sudorc_func() {
    # Intended only for sshrc use
	local SSH_IP=$(echo $SSH_CLIENT | awk '{ print $1 }')
	local SSH2_IP=$(echo $SSH2_CLIENT | awk '{ print $1 }')
	if [ "$SSH2_IP" ] || [ "$SSH_IP" ] ; then
        export MY_HOME="${HOME}"
        sudo --preserve-env=MY_HOME -s <<EOF
if [[ ! -f /root/.bashrc.bak ]]; then
    mv /root/.bashrc /root/.bashrc.bak
fi
cat "${MY_HOME}"/.bashrc > /root/.bashrc
cp -a "${MY_HOME}"/.bashrc_local* /root
cp -a "${MY_HOME}"/.cargo  /root/
EOF
        sudo -i --preserve-env=TMUXDIR --preserve-env=TMUX_PLUGIN_MANAGER_PATH
    else
        echo "Not in ssh shell, use sudo su"
    fi
}
alias sudorc='sudorc_func '
