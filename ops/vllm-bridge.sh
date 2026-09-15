#!/usr/bin/env bash
# SHIM — real file moved to spark-ops/ops/bridges/vllm-bridge.sh (Phase 4.2).
# Remove only after `journalctl -t spark-ops-shim` is empty across a full
# reboot cycle, and only with Charlie's approval (C-0b).
#
# exec replaces this process, so systemd still supervises the real script and
# Restart=always / the exit-75 re-resolve path behave unchanged.
logger -t spark-ops-shim "shim hit: $0 by PPID $PPID ($(ps -o comm= -p $PPID 2>/dev/null))"
exec /home/catlett/code/spark-ops/ops/bridges/vllm-bridge.sh "$@"
