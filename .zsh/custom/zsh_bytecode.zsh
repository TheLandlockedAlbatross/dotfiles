function compile_zsh_files() {
    # Check if the custom directory exists
    if [[ -d "$ZSH_CUSTOM" ]]; then
        # Loop through all .zsh files in the custom directory
        for file in "$ZSH_CUSTOM"/*.zsh; do
            # Check if the file exists to avoid errors
            if [[ -f "$file" ]]; then
                # Compile the .zsh file to .zwc
                zcompile "$file"
                echo "Compiled: $file to ${file%.zsh}.zwc"
            fi
        done
    else
        echo "Directory $ZSH_CUSTOM does not exist."
    fi
}
