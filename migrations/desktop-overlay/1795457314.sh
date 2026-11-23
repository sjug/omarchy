echo "Link every agent skill from the Omarchy tree in use"

# Desktop-only counterpart of product migration 1794988405.sh. Keep its
# completion independent from the product migration ledger.

# Skills were linked once, at first login, so skills shipped since (web-game)
# never reached existing installs, and a dev-linked checkout's agents kept
# reading the package's copies.
"$OMARCHY_PATH/bin/omarchy-agent-skills-link"
