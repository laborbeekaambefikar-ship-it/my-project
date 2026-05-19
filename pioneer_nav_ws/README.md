# pioneer_nav_ws — `scoutbot` AGV waypoint navigation

A from-scratch ROS 2 Humble + Gazebo Classic 11 + ros2_control workspace
implementing closed-loop waypoint navigation for a differential-drive AGV
named `scoutbot`. Built **specifically to fix every failure mode** of an
earlier project (full failure-by-failure mapping in `ARCHITECTURE.md`).

* No file, package, node, controller, frame, or topic is shared with the
  prior project.
* The navigation logic is a pure-Python state machine, separated from ROS,
  and verified by **21 unit tests** that pass without ROS installed.
* A single master script (`setup_pioneer_nav.sh`) recreates the entire
  workspace from zero on a clean Ubuntu 22.04 + ROS 2 Humble box, builds it,
  and (optionally) launches the full stack.

## Quick start

```bash
# 1) Clone or copy this repository, then:
cd pioneer_nav_ws
bash setup_pioneer_nav.sh --launch
```

Open a second terminal and run the live diagnostic check:

```bash
source ~/pioneer_nav_ws/install/setup.bash
bash ~/pioneer_nav_ws/tools/diagnose_runtime.sh
```

To drive manually instead of running the navigator:

```bash
bash ~/pioneer_nav_ws/tools/teleop_quickdrive.sh
```

## Layout

```
pioneer_nav_ws/
├── ARCHITECTURE.md              # phase-0 review, failure analysis, FSM spec
├── README.md                    # this file
├── setup_pioneer_nav.sh         # master terminal script (auto-generated)
├── src/
│   ├── scoutbot_interfaces/     # NavigationStatus.msg + Waypoint.msg
│   ├── scoutbot_description/    # URDF/xacro + ros2_control hardware spec
│   ├── scoutbot_control/        # controllers.yaml + pid_gains.yaml
│   ├── scoutbot_navigator/      # state machine + rclpy node + 21 unit tests
│   ├── scoutbot_simulation/     # flat_arena.world + spawn launch
│   └── scoutbot_bringup/        # scout_full_stack.launch.py (top-level)
└── tools/
    ├── check_workspace.sh       # offline static analysis (no ROS needed)
    ├── diagnose_runtime.sh      # online runtime health check
    ├── teleop_quickdrive.sh     # teleop_twist_keyboard wrapper
    └── _gen_master_script.py    # regenerator for setup_pioneer_nav.sh
```

## ROS interface summary (single source of truth)

| Topic / Frame                  | Direction          | Type                                       |
|--------------------------------|--------------------|--------------------------------------------|
| `/scoutbot/cmd_vel`            | nav -> controller  | `geometry_msgs/Twist` (50 Hz)              |
| `/scoutbot/odom`               | controller -> nav  | `nav_msgs/Odometry`                        |
| `/scoutbot/joint_states`       | broadcaster -> tf  | `sensor_msgs/JointState`                   |
| `/scoutbot/nav_status`         | nav -> consumer    | `scoutbot_interfaces/NavigationStatus` (2 Hz) |
| `/robot_description`           | RSP                | `std_msgs/String` (URDF)                   |
| `/tf`, `/tf_static`            | RSP + diff_drive   | TF tree                                    |
| `scout_odom -> scout_base_*`   | diff_drive_controller (ONLY publisher) | TF                       |
| `scout_base_link -> wheels/*`  | RSP (ONLY publisher) | TF                                       |

## Verification gates (all pass)

```
$ bash tools/check_workspace.sh
==> ALL CHECKS PASSED
    14 Python files       (AST parse)
     8 XML files          (well-formedness)
     3 YAML files         (safe_load)
     6 packages           (unique names)
     2 entry-points       (unique)
    21 unit tests passed  (geometry + PID + state machine)
```

After launching the full stack, `tools/diagnose_runtime.sh` verifies:
5 expected ROS nodes, 8 expected topics, 2 active controllers,
`/scoutbot/cmd_vel` published at ~50 Hz, and a complete TF tree.

## Tuning waypoints / gains

* Edit `src/scoutbot_navigator/config/waypoints.yaml` to change the mission.
* Edit `src/scoutbot_control/config/pid_gains.yaml` to retune the PIDs and
  state-machine thresholds. Defaults are documented inline.
* Edit `src/scoutbot_control/config/controllers.yaml` to change wheel
  geometry or velocity caps. **Keep these in sync with the URDF
  `xacro:property` values** (the only manual cross-file dependency).

After any source-tree edit, optionally regenerate the master script:

```bash
python3 tools/_gen_master_script.py -o setup_pioneer_nav.sh
```

## License

Apache-2.0 across all packages.
