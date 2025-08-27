#!/bin/bash
num="$1"
icon="$2"
i3-msg workspace "${num} ${icon} "
i3-msg workspace "$((num+25)) ${icon} "
i3-msg workspace "$((num+50)) ${icon} "
i3-msg workspace "$((num+75)) ${icon} "
