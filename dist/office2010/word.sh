#!/bin/sh
WPREFIX="/home/$USER/.office2010"
WINWORD_PATH="C:\\Program Files\\Microsoft Office\\Office14\\WINWORD.EXE"
WIN_PATH=$(WINEPREFIX="$WPREFIX" winepath -w "$*" 2>/dev/null)
WINEPREFIX="$WPREFIX" wine "$WINWORD_PATH" "$WIN_PATH"
exit 0
