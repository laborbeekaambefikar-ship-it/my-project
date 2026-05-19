#!/usr/bin/env bash
# =============================================================================
# tools/diagnose_runtime.sh
# Online diagnostic helper. Run AFTER scout_full_stack is up to verify every
# expected ROS interface is alive. Saves you from typing 8 separate
# `ros2 topic`/`ros2 service`/`ros2 node` commands.
#
#   bash tools/diagnose_runtime.sh
# =============================================================================
set -uo pipefail

EXPECTED_NODES=(
  /robot_state_publisher
  /spawn_scoutbot
  /scoutbot/controller_manager
  /waypoint_navigator
  /nav_diagnostics
)
EXPECTED_TOPICS=(
  /scoutbot/cmd_vel
  /scoutbot/odom
  /scoutbot/joint_states
  /scoutbot/nav_status
  /robot_description
  /tf
  /tf_static
  /clock
)
EXPECTED_CONTROLLERS=(
  scoutbot_joint_broadcaster
  scoutbot_base_controller
)
EXPECTED_TF_LINKS=(
  scout_odom
  scout_base_footprint
  scout_base_link
  scout_left_wheel_link
  scout_right_wheel_link
  scout_caster_link
  scout_imu_link
)

failed=0

echo "==> [1/5] Live nodes"
have=$(ros2 node list 2>/dev/null || true)
for n in "${EXPECTED_NODES[@]}"; do
  if grep -qx "$n" <<<"${have}"; then
    printf '  OK    %s\n' "$n"
  else
    printf '  MISS  %s\n' "$n"
    failed=1
  fi
done

echo
echo "==> [2/5] Live topics"
have=$(ros2 topic list 2>/dev/null || true)
for t in "${EXPECTED_TOPICS[@]}"; do
  if grep -qx "$t" <<<"${have}"; then
    printf '  OK    %s\n' "$t"
  else
    printf '  MISS  %s\n' "$t"
    failed=1
  fi
done

echo
echo "==> [3/5] Loaded controllers"
have=$(ros2 control list_controllers --controller-manager /scoutbot/controller_manager 2>/dev/null || true)
for c in "${EXPECTED_CONTROLLERS[@]}"; do
  if grep -q "${c}.*active" <<<"${have}"; then
    printf '  OK    %-30s active\n' "$c"
  else
    printf '  MISS  %-30s not active (have: "%s")\n' "$c" "${have}"
    failed=1
  fi
done

echo
echo "==> [4/5] /scoutbot/cmd_vel publish rate (5 s sample)"
hz=$(timeout 6 ros2 topic hz /scoutbot/cmd_vel 2>&1 | grep -m1 average | awk '{print $3}')
if [[ -n "${hz}" ]]; then
  printf '  cmd_vel ~ %s Hz (expect ~50)\n' "${hz}"
else
  printf '  FAIL no rate observed in 5 s\n'; failed=1
fi

echo
echo "==> [5/5] TF tree completeness"
tf_view=$(timeout 3 ros2 run tf2_tools view_frames -o /tmp/scout_frames 2>&1 || true)
have=$(ros2 topic echo --once /tf 2>/dev/null || true)
have_static=$(ros2 topic echo --once /tf_static 2>/dev/null || true)
combined="${have}${have_static}"
for f in "${EXPECTED_TF_LINKS[@]}"; do
  if grep -q "frame_id: ${f}" <<<"${combined}" \
     || grep -q "child_frame_id: ${f}" <<<"${combined}"; then
    printf '  OK    %s\n' "$f"
  else
    printf '  WARN  %s not seen yet (try again after the robot moves)\n' "$f"
  fi
done

echo
if [[ ${failed} -eq 0 ]]; then
  echo "==> RUNTIME DIAGNOSTICS PASSED"
  exit 0
else
  echo "==> RUNTIME DIAGNOSTICS FAILED -- inspect missing items above"
  exit 1
fi
