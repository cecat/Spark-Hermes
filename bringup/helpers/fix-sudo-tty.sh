#!/usr/bin/env bash
# Run this ONCE in the terminal where `sudo -v` works.
# It writes a sudoers drop-in that disables per-TTY sudo scoping for catlett,
# so a single `sudo -v` is visible to all of catlett's shells (including the
# Claude Code shell). After this, the NemoClaw installer can sudo without
# prompting from Claude Code.

set -euo pipefail

echo 'Defaults:catlett !tty_tickets' | sudo tee /etc/sudoers.d/catlett-notty >/dev/null
sudo chmod 440 /etc/sudoers.d/catlett-notty
sudo -v
echo READY
