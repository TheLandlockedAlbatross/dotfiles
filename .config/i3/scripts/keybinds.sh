sxhkd_config=~/.config/sxhkd/sxhkdrc

# Extract and format the keybinds
awk '/^[^[:space:]]/{key=$0; next} /^[\t ]/{printf "%-30s %s\n", key, $0}' "$sxhkd_config" | \
# Clean up whitespace and sort
sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
sort
