# List paths to all modified files in git repo
gitm_func() {
    if [[ -n "${1}" ]]; then
        git status "${1}" --porcelain | sed s,^...,.\/,
    else
        git status --porcelain | sed s,^...,.\/,
    fi
}
alias gitm='gitm_func '

# nice usable vimdiff with git
# uses temp vimscript file
# for each modified file, opens local copy next to head (stored in unwriteable /tmp buffer)
# also opens most useful vimdiff / fold commands + a window to type a commit msg in a variable
gitd () {
    if [[ -z "${1}" ]]; then
        src="."
    else
        src="${1}"
    fi
    modified_git_files=()
    head_files=()
    readarray -t modified_git_files < <(git -C "${src}" status -s | awk '/^\s*M/ {print $2}' | xargs -I {} realpath "{}")
    for modified_git_file in "${modified_git_files[@]}"; do
        # need to use paths relative to git repo
        modified_git_file_git_path=$(git ls-files --full-name "${modified_git_file}")
        tmp_file="tmp.$(date +%s).$(basename ${modified_git_file})"
        git show HEAD:"${modified_git_file_git_path}" > "/tmp/${tmp_file}"
        head_files+=("/tmp/${tmp_file}")
    done
    if [[ "${#modified_git_files[@]}" -ne "${#head_files[@]}" ]]; then
        echo "error: not all modified files have matching head files: "
        echo "${modified_git_files[@]}"
        echo "${head_files[@]}"
    else
        # create vimscript file to execute commands
        export GITD_REPO=$(git rev-parse --show-toplevel)
        repo=$(basename "${GITD_REPO}")
        rev=$(git rev-parse HEAD)
        tmp_vimscript_file="/tmp/tmp.gitd.setup.${repo}_${rev}.vim"
        export GITD_COMMIT="/tmp/tmp.gitd.commit.${repo}_${rev}.sh"
        if [[ ! -e "${GITD_COMMIT}" ]]; then
            touch "${GITD_COMMIT}"
            chmod +x "${GITD_COMMIT}"
            echo "# Current git status:" > "${GITD_COMMIT}"
            git status | awk '{print "# " $0}' >> "${GITD_COMMIT}"
            cat <<EOF >> "${GITD_COMMIT}"
# files=($(echo "${modified_git_files[@]}" | awk '{ for (i=1; i<=NF; i++) printf "\"%s\"",(i==NF?$i:$i FS) }' ))
# GITD_REPO="${GITD_REPO}"
files=()
message=""
git add "\${files[@]}"
git commit -m "\${message}" "\${files[@]}"
echo "Added and committed: \${files[@]}"
echo "Message: \${message}"
rm "${GITD_COMMIT}"
EOF
        fi
        for i in $(eval echo "{0..$(( ${#head_files[@]} - 1 ))}"); do
            # initial does not need tab
            if [[ "${i}" -eq 0 ]]; then
                cat <<EOF > "${tmp_vimscript_file}"
" Initial file 
h jumpto-diff 
wincmd r
resize 20%
vsplit
wincmd w
h fold-commands
vsplit
wincmd w
e ${GITD_COMMIT}
normal! G
wincmd w
set diffopt=filler,vertical
view ${head_files[${i}]}
diffsplit ${modified_git_files[${i}]}
EOF
            else
                cat <<EOF >> "${tmp_vimscript_file}"
" Subsequent file (in its own tab)
tabnew
wincmd w
h jumpto-diff 
wincmd r
resize 20%
vsplit
wincmd w
h fold-commands
vsplit
wincmd w
e ${GITD_COMMIT}
normal! G
wincmd w
set diffopt=filler,vertical
view ${head_files[${i}]}
diffsplit ${modified_git_files[${i}]}
EOF
            fi
        done
        vim -S "${tmp_vimscript_file}"
    fi
}
