echo "Move the keyboard layout widget to the right side of the bar"

# Mirrors migrations/1791640449.sh: the widget now leads the right-hand cluster.
# One the user already moved out of the center stays put, and a shell that is
# not running leaves the bar as it is.
omarchy-bar move omarchy.keyboard-layout --from-section center --section right --index 0 || true
