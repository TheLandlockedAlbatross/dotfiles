svn_url_func () {
    svn info "${1}" | \grep -E '^URL: ' | \grep -oE 'https.*' | tr -d '\r'
}
alias svn_url=svn_url_func 

svn_count_commits_func () {
    svn log "${1}" --quiet | \grep "^r" | awk '{print $3}' | sort | uniq -c
}
alias svn_count_commits='svn_count_commits_func '

# usable vimdiff with svn
svnd () {
    if [[ -z "${1}" ]]; then
        src="."
    else
        src="${1}"
    fi
    modified_svn_files=()
    head_files=()
    readarray -t modified_svn_files < <(svn status -q "${src}" | awk '{print $2}' | tr "\\\\" "/" | tr -d '\r')
    for modified_svn_file in "${modified_svn_files[@]}"; do
        tmp_file="tmp.$(date +%s).$(basename ${modified_svn_file})"
        svn cat "${modified_svn_file}" > "/tmp/${tmp_file}"
        head_files+=("/tmp/${tmp_file}")
    done
    if [[ "${#modified_svn_files[@]}" -ne "${#head_files[@]}" ]]; then
        echo "error: not all modified files have matching head files: "
        echo "${modified_svn_files[@]}"
        echo "${head_files[@]}"
    else
        for i in $(eval echo "{0..$(( ${#head_files[@]} - 1 ))}"); do
            if [[ "${i}" -eq 0 ]]; then
                diff_cmd="vim -c 'set diffopt=filler,vertical' -c 'view ${head_files[${i}]}' -c 'diffsplit ${modified_svn_files[${i}]}' "
            else
                diff_cmd="${diff_cmd} ; vim -c 'set diffopt=filler,vertical' -c 'view ${head_files[${i}]}' -c 'diffsplit ${modified_svn_files[${i}]}' "
            fi
        done
        eval "${diff_cmd}"
    fi
}
