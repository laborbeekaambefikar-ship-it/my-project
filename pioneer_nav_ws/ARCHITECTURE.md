# Pioneer Nav Workspace — Architecture & Failure-Prevention Review

**Project:** `pioneer_nav_ws` — Differential-drive AGV `scoutbot` with closed-loop waypoint navigation
**Target stack:** Ubuntu 22.04 + ROS 2 Humble + Gazebo Classic 11 + ros2_control + diff_drive_controller
**Status:** Built from zero. No file, name, package, topic, frame, controller, or path is shared with any prior project.

---

## 0.1 Naming firewall (NOTHING below collides with the previous project)

| Slot                       | New name                                             | Old name (forbidden)        |
|----------------------------|------------------------------------------------------|-----------------------------|
| Workspace                  | `pioneer_nav_ws`                                     | `warehouse_agv_sim`         |
| Robot                      | `scoutbot`                                           | `agv` (TurtleBot3 burger)   |
| ROS namespace              | `/scoutbot`                                          | `/agv`                      |
| Description package        | `scoutbot_description`                               | `agv_description`           |
| Control package            | `scoutbot_control`                                   | `agv_control`               |
| Navigation package         | `scoutbot_navigator`                                 | `agv_msgs` / nav-in-control |
| Simulation package         | `scoutbot_simulation`                                | `warehouse_world`           |
| Bringup package            | `scoutbot_bringup`                                   | `agv_bringup`               |
| Interfaces package         | `scoutbot_interfaces`                                | `agv_msgs`                  |
| Diff-drive controller name | `scoutbot_base_controller`                           | (gazebo plugin, unnamed)    |
| Joint broadcaster          | `scoutbot_joint_broadcaster`                         | `joint_state_publisher`     |
| Main URDF                  | `scoutbot.urdf.xacro`                                | `agv.urdf.xacro`            |
| World file                 | `flat_arena.world`                                   | `warehouse.world`           |
| Master launch              | `scout_full_stack.launch.py`                         | `spawn_agv.launch.py`       |
| Navigator node             | `waypoint_navigator`                                 | (none — never built)        |
| Diagnostic node            | `nav_diagnostics`                                    | (none — never built)        |
| Cmd topic                  | `/scoutbot/cmd_vel`                                  | `/agv/cmd_vel`              |
| Odom topic                 | `/scoutbot/odom`                                     | `/agv/odom`                 |
| Base link                  | `scout_base_link`                                    | `base_link`                 |
| Odom frame                 | `scout_odom`                                         | `odom`                      |

---

## 0.2 Failure analysis — every previous problem mapped to its prevention

The previous project had **17 distinct failure modes**. Each is addressed by a specific architectural decision below. No fix is "we will be careful"; every fix is a structural property of the new design.

| # | Previous failure                          | Root cause                                                                                               | New architectural prevention                                                                                                                                                                                       |
|---|-------------------------------------------|----------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1 | AGV only moved in a straight line         | Single open-loop control law: `cmd_vel.linear = k_d * dist` only.                                        | Explicit 6-state finite state machine: `IDLE → ALIGN_HEADING → DRIVE → FINE_APPROACH → REACHED → MISSION_DONE`. The `ALIGN_HEADING` state holds `linear=0` until heading error < `align_threshold`.                |
| 2 | Robot did not turn toward waypoints       | No heading error term, or heading error not normalized into `(-π, π]`.                                   | Mandatory `wrap_to_pi(atan2(dy, dx) - yaw)` utility in `geometry_utils.py`. Unit-tested. Used in every state.                                                                                                      |
| 3 | Angular velocity commands were incorrect  | Sign of error was lost or output was unbounded; no PID anti-windup.                                      | Dedicated `PID` class with sign-preserving error, output saturation, integral clamping, derivative on measurement (not error), and dead-band. All gains in YAML.                                                   |
| 4 | Controller stuck in "waiting" state       | `controller_manager` started before `robot_description` was published, or spawner ran before CM was up.  | Launch graph uses `RegisterEventHandler(OnProcessExit)` chain: RSP → spawn → `joint_state_broadcaster` spawner → `scoutbot_base_controller` spawner. Controllers come from a single `controllers.yaml`.            |
| 5 | No proper heading control                 | No closed-loop yaw feedback.                                                                             | Heading PID consumes yaw extracted from `/scoutbot/odom` quaternion (via `tf_transformations.euler_from_quaternion`). Yaw and heading-error published on `/scoutbot/nav_status` for inspection.                    |
| 6 | No waypoint orientation correction        | Robot accepted distance-only convergence.                                                                | Optional final-yaw alignment per waypoint: if `Waypoint.target_yaw` is finite, an extra `ALIGN_FINAL` micro-state is run after `REACHED` before advancing.                                                         |
| 7 | Robot oscillated or drifted               | No hysteresis, no dead-band, single threshold for both entry and exit.                                   | Asymmetric thresholds: `align_enter = 0.40 rad`, `align_exit = 0.05 rad`; `goal_enter = 0.30 m`, `goal_tolerance = 0.05 m`. Plus angular dead-band `0.02 rad/s` and linear dead-band `0.01 m/s`.                   |
| 8 | ROS2 topics flooded terminal              | `RCLCPP_INFO` / `get_logger().info()` on every control-loop tick at 50 Hz.                               | All loop-rate logs use `get_logger().info(..., throttle_duration_sec=1.0)`. Diagnostics published on dedicated `/scoutbot/nav_status` topic at **2 Hz** (decoupled from 50 Hz control loop).                       |
| 9 | Controller frequency issues               | `time.sleep` inside callbacks; no real timer; rate drift.                                                | Single `create_timer(1.0/control_hz, …)` at 50 Hz. Control rate is a declared parameter (`control_frequency_hz`). No sleeps in callbacks.                                                                          |
| 10 | Missing parameter files                  | Hard-coded magic numbers; YAML never loaded.                                                             | Every node calls `declare_parameter()` for every tunable; every launch file passes `parameters=[yaml_path]` explicitly. Two YAMLs ship with the package: `navigator_params.yaml`, `pid_gains.yaml`.                |
| 11 | Package duplication problems             | Two packages declared the same `<name>` or installed the same node.                                      | Unique `scoutbot_*` prefix on all 6 packages. Each node has a unique entry-point name. CI-style check script `tools/check_unique_names.sh` enumerates `package.xml` and `entry_points`.                            |
| 12 | Launch file conflicts                    | Two launch files spawned `robot_state_publisher` simultaneously.                                         | RSP is created in **exactly one** launch file (`scout_spawn.launch.py`); higher launches `IncludeLaunchDescription` it. No file recreates RSP.                                                                     |
| 13 | Spawn failures in Gazebo                 | `spawn_entity.py` ran before `/robot_description` topic existed.                                         | Spawn is gated on `OnProcessStart(rsp)` + a 2 s `TimerAction`. We pass `-topic /robot_description` (string-streamed) instead of `-file <path>` so xacro errors surface immediately at RSP, not at spawn time.      |
| 14 | TF tree inconsistencies                  | Both `gazebo_ros_diff_drive` and `robot_state_publisher` published `odom→base_link`.                     | Single source of truth: `diff_drive_controller` from ros2_control publishes `scout_odom → scout_base_link`. RSP publishes only the static chain `scout_base_link → wheels/sensors`. No double publishers.          |
| 15 | Odometry issues                          | Plugin published odom with no covariance; drift unbounded.                                               | `diff_drive_controller` populates `pose.covariance` and `twist.covariance` from YAML. `enable_odom_tf: true` exactly once.                                                                                         |
| 16 | Poor PID tuning                          | Random gains; no documentation.                                                                          | Gains documented per channel in `pid_gains.yaml` with units, ranges, and tuning notes. Defaults derived from a 0.4 m wheelbase / 0.1 m wheel radius / 1.0 m·s⁻¹ max linear / 1.5 rad·s⁻¹ max angular.              |
| 17 | Poor navigation logic                    | Ad-hoc if/else chains.                                                                                   | Pure-Python state machine in `nav_state_machine.py` (no ROS deps) — unit-testable in isolation. The ROS node is a thin shell that feeds it `(pose, waypoint)` and applies the returned `(v, ω)` to `cmd_vel`.       |

---

## 0.3 System architecture (ASCII data-flow)

```
+----------------------------+            +--------------------------+
|   waypoints.yaml           |            |   navigator_params.yaml  |
|   (list of (x, y, yaw?))   |            |   pid_gains.yaml         |
+-------------+--------------+            +------------+-------------+
              |                                        |
              v                                        v
+-----------------------------------------------------------------+
|  waypoint_navigator (rclpy node, 50 Hz timer)                   |
|  ------------------------------------------------------------   |
|  subscribes:  /scoutbot/odom        (nav_msgs/Odometry)         |
|  publishes:   /scoutbot/cmd_vel     (geometry_msgs/Twist)       |
|               /scoutbot/nav_status  (NavigationStatus, 2 Hz)    |
|                                                                 |
|  internals:  NavStateMachine  +  PID(linear)  +  PID(angular)   |
+-----------------------------------------------------------------+
        |                                                ^
        | /scoutbot/cmd_vel                              | /scoutbot/odom
        v                                                |
+-----------------------------------------------------------------+
|  controller_manager  (ros2_control + gazebo_ros2_control)       |
|    - scoutbot_joint_broadcaster                                 |
|    - scoutbot_base_controller (diff_drive_controller)           |
|         publishes: /scoutbot/odom + TF scout_odom→scout_base    |
+-----------------------------------------------------------------+
        |
        v
+-----------------------------------------------------------------+
|  Gazebo Classic 11 + gazebo_ros2_control plugin                 |
|  loads scoutbot.urdf.xacro, simulates physics, exposes joints   |
+-----------------------------------------------------------------+
```

All inter-node communication happens through documented ROS topics. The state machine has zero ROS dependencies and is unit-testable.

---

## 0.4 State machine — formal definition

States: `IDLE`, `ALIGN_HEADING`, `DRIVE`, `FINE_APPROACH`, `ALIGN_FINAL`, `REACHED`, `MISSION_DONE`

Inputs each tick: `(x, y, yaw)` from odom, current waypoint `(wx, wy, wyaw_or_None)`.

Computed each tick:
- `dx = wx - x`, `dy = wy - y`
- `distance = sqrt(dx² + dy²)`
- `desired_heading = atan2(dy, dx)`
- `heading_error = wrap_to_pi(desired_heading - yaw)`

Transitions (in priority order):

| From            | Condition                                                | To              |
|-----------------|----------------------------------------------------------|-----------------|
| IDLE            | waypoint queue not empty                                 | ALIGN_HEADING   |
| ALIGN_HEADING   | `abs(heading_error) ≤ align_exit (0.05 rad)`             | DRIVE           |
| DRIVE           | `distance ≤ goal_enter (0.30 m)`                         | FINE_APPROACH   |
| DRIVE           | `abs(heading_error) ≥ realign_threshold (0.40 rad)`      | ALIGN_HEADING   |
| FINE_APPROACH   | `distance ≤ goal_tolerance (0.05 m)`                     | REACHED         |
| REACHED         | `target_yaw is finite`                                   | ALIGN_FINAL     |
| REACHED         | `target_yaw is None`                                     | (advance queue) |
| ALIGN_FINAL     | `abs(yaw_error) ≤ final_yaw_tolerance (0.05 rad)`        | (advance queue) |
| (advance queue) | queue empty                                              | MISSION_DONE    |
| (advance queue) | queue not empty                                          | ALIGN_HEADING   |

Outputs `(v, ω)` per state:

| State         | v (linear)                                                                | ω (angular)                                |
|---------------|---------------------------------------------------------------------------|--------------------------------------------|
| IDLE          | 0                                                                         | 0                                          |
| ALIGN_HEADING | 0                                                                         | clamp(`pid_yaw(heading_error)`, ±ω_max)    |
| DRIVE         | clamp(`pid_lin(distance)`, 0, v_max) × `cos(heading_error)`               | clamp(`pid_yaw(heading_error)`, ±ω_max)    |
| FINE_APPROACH | clamp(`pid_lin(distance)`, 0, v_slow) × `cos(heading_error)`              | clamp(`pid_yaw(heading_error)`, ±ω_slow)   |
| ALIGN_FINAL   | 0                                                                         | clamp(`pid_yaw(yaw_error)`, ±ω_max)        |
| REACHED       | 0                                                                         | 0                                          |
| MISSION_DONE  | 0                                                                         | 0                                          |

The `cos(heading_error)` factor on `v` is the standard "slow forward when mis-aligned" trick: it goes negative when error > π/2, which prevents overshoot if the robot drifts past sideways during high-speed runs.

---

## 0.5 Design weaknesses identified during review (and how each was fixed)

| Weakness                                                                                           | Fix                                                                                       |
|----------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------|
| If goal is 5 cm away and heading error is 170°, robot will rotate ~180° instead of reversing 5 cm. | At distance ≤ `goal_enter`, switch to FINE_APPROACH which uses gentler ω, not in-place spin. The state machine does not re-enter ALIGN_HEADING from FINE_APPROACH.|
| PID integral can wind up during ALIGN_HEADING if friction stalls the robot.                         | `PID.reset()` is called on every state transition.                                        |
| Odom yaw discontinuity at ±π wraparound can cause a one-tick command spike.                        | All angle differences pass through `wrap_to_pi`. PID derivative uses dead-band `1e-4`.    |
| If the user provides an empty waypoint list, the node would idle forever silently.                  | Startup log warns; `nav_status.state = "MISSION_DONE"` immediately; node remains alive.  |
| Spawning before `controller_manager` parameters were loaded → controllers fail to load.            | `controllers.yaml` is passed to **gazebo_ros2_control** via the `<parameters>` tag inside the URDF, so it is loaded inside Gazebo at the same moment the controller_manager is born. |
| Two `use_sim_time` defaults disagreeing across launches.                                            | Single declared `LaunchArgument('use_sim_time', default='true')` propagated everywhere.   |
| User runs `setup_pioneer_nav.sh` twice → re-creating files clobbers edits.                          | Script is **idempotent**: `mkdir -p`, `cat > file` only if absent or `--force` flag.      |

---

## 0.6 Verification gates

After each phase the following must pass before the next phase begins:

| Phase | Gate command                                                                                          | Expected                                                              |
|-------|-------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------|
| 2     | `colcon list`                                                                                         | 6 packages listed: scoutbot_interfaces, _description, _control, _navigator, _simulation, _bringup |
| 3     | `colcon build --packages-select scoutbot_interfaces`                                                  | NavigationStatus.msg + Waypoint.msg generate Python + C++ bindings    |
| 4     | `xacro src/scoutbot_description/urdf/scoutbot.urdf.xacro > /tmp/scoutbot.urdf && check_urdf …`        | "Successfully Parsed XML"                                             |
| 5     | `ros2 param dump /controller_manager` (after launch)                                                  | shows scoutbot_base_controller + scoutbot_joint_broadcaster           |
| 6     | `python3 -m unittest scoutbot_navigator/test/test_nav_state_machine.py`                               | all transitions assert OK                                             |
| 7     | `gazebo --verbose flat_arena.world` (visual)                                                          | empty arena loads in < 5 s                                            |
| 8     | `ros2 launch scoutbot_bringup scout_full_stack.launch.py`                                             | Gazebo + RSP + spawn + 2 controllers spawned + navigator running      |
| 9     | `ros2 topic hz /scoutbot/cmd_vel` while navigating                                                    | ~50 Hz                                                                |
| 9     | `ros2 topic echo /scoutbot/nav_status --once`                                                         | NavigationStatus message visible                                      |
| 10    | `bash setup_pioneer_nav.sh --dry-run`                                                                 | Lists every file it would write, exits 0                              |

---

End of architecture review. Implementation begins in `setup_pioneer_nav.sh` and the file tree below.
