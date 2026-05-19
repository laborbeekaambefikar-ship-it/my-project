# ============================================================================
# Waypoint.msg
# A single 2-D goal pose for the scoutbot waypoint navigator.
#
# Coordinates are interpreted in the frame named by `frame_id`
# (typically "scout_odom"). `target_yaw` is in radians, range (-pi, pi].
# Set `has_target_yaw = false` to skip the optional ALIGN_FINAL state for
# this waypoint (translation-only goal).
# ============================================================================

# Frame the (x, y) is expressed in. Default: "scout_odom".
string frame_id

# Target X position [m] in `frame_id`.
float64 x

# Target Y position [m] in `frame_id`.
float64 y

# Target final yaw [rad], wrapped to (-pi, pi]. Ignored if has_target_yaw=false.
float64 target_yaw

# If true, navigator will run the ALIGN_FINAL micro-state at the goal.
bool has_target_yaw

# Per-waypoint position tolerance [m]. 0.0 -> use navigator default.
float64 tolerance
