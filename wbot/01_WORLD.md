# 🏭 Stage 1 — Workspace + Warehouse World

> **Goal:** Set up a clean ROS 2 workspace and create the Gazebo warehouse with shelves, tape lines, and a HOME zone.
>
> **Time:** 20 minutes  •  **Files created:** 1 workspace, 5 package skeletons, 1 world generator, 1 launch file

---

## 🧠 What We're Building This Stage

```
                    ┌─────────────────────────────────────┐
                    │         WAREHOUSE FLOOR              │
                    │                                      │
  Y=4 ┤   S04   S08   S12   S16   S20   ← far shelves      │
       │   S03   S07   S11   S15   S19                     │
  Y=2 ┤   S02   S06   S10   S14   S18                      │
       │   S01   S05   S09   S13   S17   ← near shelves    │
  Y=0 ┤━━●━━━━━●━━━━━●━━━━━●━━━━━●━━━━━━━  ← MAIN AISLE   │
       │   │     │     │     │     │                       │
       │  X=0   X=3   X=6   X=9   X=12                     │
       │  Aisle1 Aisle2 Aisle3 Aisle4 Aisle5                │
       │                                                   │
  X=-2,Y=0  ← [HOME zone — green disc]                     │
                                                            │
                    └─────────────────────────────────────┘
```

- **Main aisle:** black tape from X=-2.5 to X=12.5, along Y=0
- **5 spurs:** vertical tape from Y=0 to Y=4, at X = 0, 3, 6, 9, 12
- **20 shelves:** brown boxes, 4 per aisle, on the LEFT of each spur
- **HOME:** green disc at (-2, 0)
- **20 RFID tags:** small blue dots on the floor (one per shelf) + 1 HOME tag

---

## 📋 Step 1 — Create the Workspace

```bash
mkdir -p ~/wbot_ws/src
cd ~/wbot_ws/src
```

✅ **Test:** `pwd` should print `/home/<your-username>/wbot_ws/src`.

---

## 📋 Step 2 — Create the 5 Empty Packages

```bash
cd ~/wbot_ws/src

ros2 pkg create --build-type ament_python wbot_world
ros2 pkg create --build-type ament_python wbot_robot
ros2 pkg create --build-type ament_python wbot_brain
ros2 pkg create --build-type ament_python wbot_run
ros2 pkg create --build-type ament_cmake  wbot_msgs
```

✅ **Test:**
```bash
ls ~/wbot_ws/src
```
Should print: `wbot_brain  wbot_msgs  wbot_robot  wbot_run  wbot_world`

---

## 📋 Step 3 — Set Up `wbot_world` Folder Structure

```bash
mkdir -p ~/wbot_ws/src/wbot_world/scripts
mkdir -p ~/wbot_ws/src/wbot_world/worlds
mkdir -p ~/wbot_ws/src/wbot_world/launch
```

---

## 📋 Step 4 — Create the World Generator

This Python script creates the Gazebo `.world` file. Generating it from a script means **all tape coordinates live in ONE place** — we'll reuse them in `track.py` and `shelves.py` later.

```bash
nano ~/wbot_ws/src/wbot_world/scripts/build_world.py
```

Paste **this complete file**:

```python
#!/usr/bin/env python3
"""
build_world.py — Generates warehouse.world for Gazebo.

Run once after cloning, or any time you change layout constants:
    python3 ~/wbot_ws/src/wbot_world/scripts/build_world.py

The constants at the top are the SOURCE OF TRUTH. They appear again in
wbot_brain/track.py and wbot_brain/shelves.py — those files import them
identically so coordinates can never drift out of sync.
"""

import os

# ====================================================================
# LAYOUT CONSTANTS (source of truth)
# ====================================================================
LINE_WIDTH  = 0.05    # 5 cm wide black tape
LINE_HEIGHT = 0.002   # 2 mm tall, lays flat

# Main aisle (horizontal)
MAIN_AISLE_X_START = -2.5
MAIN_AISLE_X_END   = 12.5
MAIN_AISLE_Y       = 0.0

# Spurs (vertical, branching upward from main aisle)
SPUR_X_LIST  = [0.0, 3.0, 6.0, 9.0, 12.0]
SPUR_Y_START = 0.0
SPUR_Y_END   = 4.0

# Home zone
HOME_X = -2.0
HOME_Y = 0.0

# Shelves: 4 per aisle, all on LEFT (-X side) of spur
SHELF_X_OFFSET    = -0.9          # shelf is 0.9 m left of spur centreline
SHELF_Y_START     = 0.8           # first shelf at Y=0.8
SHELF_Y_STEP      = 0.8           # 0.8 m between shelves
SHELVES_PER_AISLE = 4

# RFID tags: 0.4 m left of spur (between spur line and shelf)
TAG_X_OFFSET = -0.4


# ====================================================================
# SDF GENERATORS
# ====================================================================
def make_box(name, x, y, z, sx, sy, sz, r, g, b):
    return f"""
    <model name="{name}">
      <static>true</static>
      <pose>{x} {y} {z} 0 0 0</pose>
      <link name="link">
        <visual name="v">
          <geometry><box><size>{sx} {sy} {sz}</size></box></geometry>
          <material>
            <ambient>{r} {g} {b} 1</ambient>
            <diffuse>{r} {g} {b} 1</diffuse>
          </material>
        </visual>
      </link>
    </model>"""


def make_cyl(name, x, y, z, radius, height, r, g, b):
    return f"""
    <model name="{name}">
      <static>true</static>
      <pose>{x} {y} {z} 0 0 0</pose>
      <link name="link">
        <visual name="v">
          <geometry><cylinder><radius>{radius}</radius><length>{height}</length></cylinder></geometry>
          <material>
            <ambient>{r} {g} {b} 1</ambient>
            <diffuse>{r} {g} {b} 1</diffuse>
          </material>
        </visual>
      </link>
    </model>"""


# ====================================================================
# MAIN
# ====================================================================
def main():
    parts = []

    # Main aisle (black tape)
    main_len = MAIN_AISLE_X_END - MAIN_AISLE_X_START
    main_xc  = (MAIN_AISLE_X_START + MAIN_AISLE_X_END) / 2.0
    parts.append(make_box(
        "tape_main", main_xc, MAIN_AISLE_Y, LINE_HEIGHT/2,
        main_len, LINE_WIDTH, LINE_HEIGHT,
        0.05, 0.05, 0.05))

    # Spurs (black tape)
    spur_len = SPUR_Y_END - SPUR_Y_START
    spur_yc  = (SPUR_Y_START + SPUR_Y_END) / 2.0
    for i, sx in enumerate(SPUR_X_LIST, start=1):
        parts.append(make_box(
            f"tape_spur_{i}", sx, spur_yc, LINE_HEIGHT/2,
            LINE_WIDTH, spur_len, LINE_HEIGHT,
            0.05, 0.05, 0.05))

    # HOME zone (green disc)
    parts.append(make_cyl(
        "home_zone", HOME_X, HOME_Y, 0.001,
        0.30, 0.005,
        0.0, 0.7, 0.0))

    # Shelves + RFID tags
    n = 1
    for ax in SPUR_X_LIST:
        for slot in range(SHELVES_PER_AISLE):
            sx = ax + SHELF_X_OFFSET
            sy = SHELF_Y_START + slot * SHELF_Y_STEP
            tx = ax + TAG_X_OFFSET
            ty = sy

            # Shelf body — brown box, 0.6 × 0.4 × 0.6 m
            parts.append(make_box(
                f"shelf_S{n:02d}", sx, sy, 0.30,
                0.6, 0.4, 0.6,
                0.55, 0.35, 0.20))

            # RFID tag marker — small blue disc
            parts.append(make_cyl(
                f"tag_S{n:02d}", tx, ty, 0.001,
                0.05, 0.003,
                0.1, 0.4, 1.0))

            n += 1

    # Assemble final SDF
    world = f"""<?xml version="1.0"?>
<sdf version="1.6">
  <world name="warehouse">
    <include><uri>model://sun</uri></include>
    <include><uri>model://ground_plane</uri></include>

    <!-- Light gray floor surface -->
    <model name="floor_color">
      <static>true</static>
      <pose>5 2 -0.001 0 0 0</pose>
      <link name="link">
        <visual name="v">
          <geometry><box><size>20 10 0.001</size></box></geometry>
          <material>
            <ambient>0.95 0.95 0.95 1</ambient>
            <diffuse>0.95 0.95 0.95 1</diffuse>
          </material>
        </visual>
      </link>
    </model>

    <physics type="ode">
      <max_step_size>0.001</max_step_size>
      <real_time_factor>1.0</real_time_factor>
      <real_time_update_rate>1000</real_time_update_rate>
      <ode>
        <solver>
          <type>quick</type>
          <iters>50</iters>
          <sor>1.3</sor>
        </solver>
        <constraints>
          <cfm>0.0</cfm>
          <erp>0.2</erp>
          <contact_max_correcting_vel>100</contact_max_correcting_vel>
          <contact_surface_layer>0.001</contact_surface_layer>
        </constraints>
      </ode>
    </physics>

{''.join(parts)}

  </world>
</sdf>
"""

    out_dir = os.path.expanduser("~/wbot_ws/src/wbot_world/worlds")
    os.makedirs(out_dir, exist_ok=True)
    out_file = os.path.join(out_dir, "warehouse.world")
    with open(out_file, "w") as f:
        f.write(world)

    n_shelves = len(SPUR_X_LIST) * SHELVES_PER_AISLE
    print(f"OK: wrote {out_file}")
    print(f"    {len(SPUR_X_LIST)} aisles, {n_shelves} shelves, "
          f"{n_shelves + 1} RFID tags (incl. HOME)")


if __name__ == "__main__":
    main()
```

Save (Ctrl+O, Enter) and exit (Ctrl+X).

---

## 📋 Step 5 — Run the Generator Once

```bash
python3 ~/wbot_ws/src/wbot_world/scripts/build_world.py
```

✅ **Expected output:**
```
OK: wrote /home/<you>/wbot_ws/src/wbot_world/worlds/warehouse.world
    5 aisles, 20 shelves, 21 RFID tags (incl. HOME)
```

The world file is now ~10 KB. You can inspect it if curious:
```bash
ls -la ~/wbot_ws/src/wbot_world/worlds/warehouse.world
```

---

## 📋 Step 6 — Create the Launch File

```bash
nano ~/wbot_ws/src/wbot_world/launch/world.launch.py
```

Paste:

```python
#!/usr/bin/env python3
"""world.launch.py — Launches Gazebo with the warehouse world."""

import os
from launch import LaunchDescription
from launch.actions import ExecuteProcess
from ament_index_python.packages import get_package_share_directory


def generate_launch_description():
    pkg = get_package_share_directory('wbot_world')
    world = os.path.join(pkg, 'worlds', 'warehouse.world')

    gazebo = ExecuteProcess(
        cmd=['gazebo', '--verbose', world,
             '-s', 'libgazebo_ros_init.so',
             '-s', 'libgazebo_ros_factory.so'],
        output='screen'
    )

    return LaunchDescription([gazebo])
```

Save and exit.

---

## 📋 Step 7 — Update `setup.py` for `wbot_world`

```bash
nano ~/wbot_ws/src/wbot_world/setup.py
```

Replace the entire file with:

```python
from setuptools import setup
from glob import glob
import os

package_name = 'wbot_world'

setup(
    name=package_name,
    version='0.1.0',
    packages=[package_name],
    data_files=[
        ('share/ament_index/resource_index/packages',
            ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
        (os.path.join('share', package_name, 'launch'),
            glob('launch/*.py')),
        (os.path.join('share', package_name, 'worlds'),
            glob('worlds/*.world')),
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    maintainer='you',
    maintainer_email='you@example.com',
    description='Warehouse Gazebo world for wbot',
    license='MIT',
    entry_points={'console_scripts': []},
)
```

---

## 📋 Step 8 — First Build

```bash
cd ~/wbot_ws
colcon build --symlink-install
source install/setup.bash
```

✅ **Expected:** `Summary: 5 packages finished`

You'll see warnings like `SetuptoolsDeprecationWarning` — **ignore them**, they're harmless on Humble.

---

## 📋 Step 9 — Launch the World

```bash
ros2 launch wbot_world world.launch.py
```

Wait ~15 seconds for Gazebo to fully load.

✅ **You should see in Gazebo:**
- A light gray floor (the warehouse)
- A long horizontal black tape line (main aisle)
- 5 vertical black tape lines branching from it (spurs)
- 20 brown rectangular shelves arranged in 5 columns of 4
- A green disc on the far left (HOME zone)
- 20 small blue dots near the shelves (RFID tags)

Press **Ctrl+C** in the terminal to stop Gazebo.

---

## 🎉 Stage 1 Complete

You now have:
- ✅ Workspace at `~/wbot_ws/`
- ✅ All 5 packages skeleton-built
- ✅ Working warehouse with 20 shelves, tape lines, HOME zone, RFID markers
- ✅ Single launch command to start the world

---

## 🆘 Troubleshooting

| Problem | Fix |
|---|---|
| `gazebo: command not found` | `sudo apt install gazebo` |
| Black screen for >30 seconds | Wait longer. First Gazebo launch is slow as it loads models. |
| `package wbot_world not found` | You forgot `source ~/wbot_ws/install/setup.bash` |
| `Failed to load library libgazebo_ros_init.so` | `sudo apt install ros-humble-gazebo-ros-pkgs` |
| Build fails on a `wbot_*` package | Run only that package: `colcon build --packages-select <name>` to see specific error |
| `python3 build_world.py` fails | Make sure you used `python3` not `python` (Python 2 is gone) |

---

## ➡️ Next Up

`02_ROBOT.md` — Build the robot itself with **correct physics from day 1**. No spawn-drift bug.
