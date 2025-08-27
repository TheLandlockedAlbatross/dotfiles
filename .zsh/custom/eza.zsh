alias eza='eza --icons=auto -a '
alias l='clear && eza -h'
alias ls='eza -h'                                           # colors and file type extensions
alias la='eza -lh'                                          # long file names
alias lx='eza -lXBh'                                        # sort by extension
alias lk='eza -lSrh'                                        # sort by size
alias lc='eza -lrh -s changed'                              # sort by change time
alias lu='eza -lrh -s access'                               # sort by access time
alias lr='eza -lRh'                                         # recursive ls
alias lt='eza -lhr -s new'                                  # sort by date
alias lm='eza -lh | more'                                   # pipe through 'more'
alias lw='eza -xh'                                          # wide listing format
alias ll='eza -l'                                           # long listing format
alias labc='eza -l -s name'                                 # alphabetical sort
alias lf='eza -lf'                                          # files only
alias ld='eza -lD'                                          # directories only

