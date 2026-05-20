# ORION  Warehouse  AGV  Simulation

Production-grade warehouse Autonomous Guided Vehicle simulation for **Ubuntu 22.04 + ROS 2 Humble + Gazebo Classic 11**, generated entirely from a single self-contained installer.

## One-command install

```bash
bash setup_orion.sh
```

The installer:

1. Installs all apt + pip dependencies.
2. Creates `~/orion_ws/` and writes every source file via heredocs.
3. Builds `orion_msgs` first in isolation (so generated message types are visible).
4. Builds the four remaining packages with `colcon`.
5. Runs a self-validation report.
6. Optionally launches the full simulation (set `LAUNCH_AFTER_BUILD=0` to skip).

## Workspace

```
~/orion_ws/src/
  orion_msgs    custom interfaces (Mission, RFIDEvent, RobotStatus)
  orion_world   procedurally-generated warehouse.world (5 aisles, 20 shelves)
  orion_robot   differential-drive AGV URDF + spawn launch + RViz config
  orion_core    runtime nodes (mission manager + controllers + GUI + CLI)
  orion_launch  master warehouse.launch.py (single-command bring-up)
```

## Run

```bash
source ~/orion_ws/install/setup.bash
ros2 launch orion_launch warehouse.launch.py
```

This brings up Gazebo, the AGV, RViz, the PyQt5 dashboard, and every controller / monitor node.

## Send a mission

From the GUI: click **Create Mission** and pick a shelf.

From the CLI (separate terminal):

```bash
source ~/orion_ws/install/setup.bash
ros2 run orion_core send_mission S07
ros2 run orion_core send_mission S12 SKU-9001 2
```

## Architecture in one paragraph

`mission_manager` is the **sole publisher** on `/orion/cmd_vel`. The line follower, IMU 90° turn controller, and IMU 180° pivot controller each publish to a private velocity topic (`/orion/follow_vel`, `/orion/turn_vel`, `/orion/pivot_vel`). At 50 Hz the mission manager forwards exactly one of those onto `/orion/cmd_vel` based on the current finite-state-machine state. This eliminates publisher race conditions permanently.

## State machine

```
IDLE -> NAVIGATING(spine) -> TURNING(right) -> NAVIGATING(aisle)
     -> AT_SHELF -> LOADING -> PIVOTING (180 deg CCW)
     -> PIVOT_NUDGE (15 cm forward) -> RETURNING(aisle)
     -> TURNING(left) -> RETURNING(spine) -> DOCKED -> IDLE
```

`/orion/estop` immediately drives the FSM to `ERROR`. `/orion/reset` clears it.

## Key parameters

| Subsystem        | Parameter        | Value          |
| ---------------- | ---------------- | -------------- |
| Line follower    | linear_speed     | 0.50 m/s       |
| Line follower    | kp, ki, kd       | 0.50, 0.0, 0.15|
| Optical sensors  | count, rate      | 8 @ 50 Hz      |
| Optical sensors  | line_width       | 0.040 m        |
| Junction         | threshold        | 5 sensors      |
| Junction         | confirm_frames   | 2              |
| Junction         | cooldown         | 1.5 s          |
| Turning          | speed, tolerance | 0.5 rad/s, 3 deg|
| Pivot            | speed, tolerance | 0.5 rad/s, 3 deg|
| Pivot nudge      | speed, duration  | 0.20 m/s, 0.75 s|
| RFID             | detect, rearm    | 0.60 m, 0.90 m |

## Reproducibility

`setup_orion.sh` is the single source of truth. Delete `~/orion_ws/` and re-run it; everything is regenerated identically.
