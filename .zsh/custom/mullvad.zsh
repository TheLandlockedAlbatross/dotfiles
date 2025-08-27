mullvad_rand_func() {
    local country="$1"
    local relay

    if [ -n "$country" ]; then
        # Filter relays by country (case-insensitive, country code at start of line)
        relay=$(mullvad relay list | sed -e 's/^[\t]\+//' \
            | grep -i "^${country}" | grep -E "^[a-z0-9\-]+wg-[0-9]+" | cut -d ' ' -f 1 | shuf -n 1)
    else
        relay=$(mullvad relay list | sed -e 's/^[\t]\+//' \
            | grep -E "^[a-z0-9\-]+wg-[0-9]+" | cut -d ' ' -f 1 | shuf -n 1)
    fi

    if [ -z "$relay" ]; then
        echo "No relay found for country: $country"
        return 1
    fi

    mullvad relay set location "$relay" > /dev/null
    mullvad connect --wait
    mullvad status
}
alias mullvad_rand='mullvad_rand_func '
