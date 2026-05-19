# ============================================================================
# NavigationStatus.msg
# Real-time diagnostic snapshot published by the waypoint navigator at 2 Hz
# (decoupled from the 50 Hz control loop -- prevents terminal flooding).
#
# Topic: /scoutbot/nav_status
# ============================================================================

# Standard header. stamp = last odom timestamp seen by the controller.
std_msgs/Header header

# Current state name. One of:
#   "IDLE", "ALIGN_HEADING", "DRIVE", "FINE_APPROACH",
#   "ALIGN_FINAL", "REACHED", "MISSION_DONE".
string state

# Index of the waypoint currently being pursued (0-based).
# -1 if mission is finished or no waypoints loaded.
int32 current_waypoint_index

# Total number of waypoints in the loaded mission.
int32 total_waypoints

# Straight-line distance from current pose to the active waypoint [m].
float64 distance_to_goal

# Heading error: desired_heading - current_yaw, wrapped to (-pi, pi]  [rad].
float64 heading_error

# Last commanded linear velocity [m/s] (sent on /scoutbot/cmd_vel).
float64 cmd_linear_velocity

# Last commanded angular velocity [rad/s].
float64 cmd_angular_velocity

# True iff the navigator believes it is still actively driving.
bool is_active
