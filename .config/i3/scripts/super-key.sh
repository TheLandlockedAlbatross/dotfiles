#!/bin/bash

# Set a small timeout (in seconds)
timeout=5

# Wait for key release or timeout
if read -rsn1 -t "$timeout"; then
    # If a key is pressed within the timeout, do nothing
    exit 0
else
    # If no key is pressed within the timeout, run the Whisker menu
    xfce4-popup-whiskermenu -p
fi

