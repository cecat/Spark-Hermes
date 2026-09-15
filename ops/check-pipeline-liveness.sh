#!/usr/bin/env bash
# SHIM — real file moved to spark-ops/ops/checks/check-pipeline-liveness.sh
# (Phase 4.1). Remove only after `journalctl -t spark-ops-shim` is empty across
# a full reboot cycle, and only with Charlie's approval (C-0b).
logger -t spark-ops-shim "shim hit: $0 by PPID $PPID ($(ps -o comm= -p $PPID 2>/dev/null))"
exec /home/catlett/code/spark-ops/ops/checks/check-pipeline-liveness.sh "$@"
