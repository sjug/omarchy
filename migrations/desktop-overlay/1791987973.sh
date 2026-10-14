echo "Relink the Omarchy agent skill to its current location"

# The skill moved from default/omarchy-skill to default/agents/skills/omarchy;
# migrations/1786098807.sh relinked product installs. Only links that still
# point at the old location are repaired here; none are created.
for link in ~/.agents/skills/omarchy ~/.claude/skills/omarchy ~/.codex/skills/omarchy ~/.pi/agent/skills/omarchy; do
  [[ -L $link && $(readlink "$link") == */default/omarchy-skill ]] || continue
  ln -sfn "$OMARCHY_PATH/default/agents/skills/omarchy" "$link"
done
