# apt
if command -v apt &> /dev/null; then 
    alias install='sudo apt install '
    alias installed="(zcat $(ls -tr /var/log/apt/history.log*); cat /var/log/apt/history.log) 2>/dev/null | egrep '^(Commandline:)' | \grep -v aptdaemon | egrep -o 'apt(-get)? install.*'"
    # adapted from https://askubuntu.com/a/250530
    # no apt* text, flags (-y, etc) or newlines
    alias installed_neat="installed | sed -E 's/apt(-get)? (install)?//g' | tr '\n' ' ' | sed 's/ -[[:alnum:]]\+//g'"
    alias remove='sudo apt-get remove '
    alias search='apt search --names-only'
    alias update='sudo apt-get update && sudo apt-get upgrade'
fi
