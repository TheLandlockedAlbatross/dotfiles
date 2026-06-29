systemctl is-active --quiet sanoid.timer && st -e $SHELL -c 'systemctl status sanoid.timer ; sudo systemctl disable --now sanoid.timer ; systemctl status sanoid.timer ; echo Exiting... ; sleep 2' || st -e $SHELL -c 'systemctl status sanoid.timer ; sudo systemctl enable --now sanoid.timer ; systemctl status sanoid.timer ; echo Exiting... ; sleep 2'

