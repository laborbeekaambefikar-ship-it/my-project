#!/usr/bin/env bash
# =============================================================================
# tools/teleop_quickdrive.sh
# Convenience wrapper around teleop_twist_keyboard with the correct topic
# remap for the scoutbot. Useful for sanity-checking the diff_drive_controller
# without running the navigator.
#
#   bash tools/teleop_quickdrive.sh
# =============================================================================
set -euo pipefail

if ! command -v ros2 >/dev/null 2>&1; then
  echo "ERROR: ROS 2 environment not sourced. Source install/setup.bash first." >&2
  exit 1
fi

if ! ros2 pkg list 2>/dev/null | grep -q '^teleop_twist_keyboard$'; then
  echo "ERROR: teleop_twist_keyboard not installed." >&2
  echo "       sudo apt install -y ros-humble-teleop-twist-keyboard" >&2
  exit 1
fi

echo "Driving /scoutbot/cmd_vel (i/k/j/l/u/o/m/,/. , q/z to change speed)"
exec ros2 run teleop_twist_keyboard teleop_twist_keyboard \
  --ros-args -r cmd_vel:=/scoutbot/cmd_vel
