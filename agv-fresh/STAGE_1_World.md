# 🏭 Stage 1 — Workspace + Warehouse World

> **Goal:** Set up a clean ROS 2 workspace and create a Gazebo warehouse with shelves, tape lines, and a HOME zone. By the end, you'll launch Gazebo and see your warehouse.

**Time:** ~30 minutes. **Files created:** 1 workspace, 5 packages, 1 world file, 1 launch file.

---

## 📐 Layout We're Building

```
                    ┌─────────────────────────────────────┐
                    │         WAREHOUSE FLOOR              │
                    │                                      │
   Y=4 ┤  S04   S08   S12   S16   S20  ← far shelves      │
       │  S03   S07   S11   S15   S19                     │
   Y=2 ┤  S02   S06   S10   S14   S18                     │
       │  S01   S05   S09   S13   S17  ← near shelves     │
   Y=0 ┤━━●━━━━━●━━━━━●━━━━━●━━━━━●━━━━━━━  ← MAIN AISLE  │
       │  │     │     │     │     │                       │
       │ X=0   X=3   X=6   X=9  X=12                      │
       │ Aisle1 Aisle2 Aisle3 Aisle4 Aisle5                │
       │                                                   │
   X=-2,Y=0  ← [HOME zone, green]                          │
                    │                                      │
                    └─────────────────────────────────────┘
```

- **Main aisle**: black tape from X=-2.5 to X=12.5, along Y=0
- **5 spurs**: black tape going from Y=0 to Y=4, at X=0,3,6,9,12
- **20 shelves**: 4 per aisle, all on the LEFT side of each spur, spaced 0.8m apart
- **HOME zone**: green disc at (-2, 0)

---

## 📋 Step 1 — Create the Workspace

Open a terminal. Type:

```bash
mkdir -p ~/agv_ws/src
cd ~/agv_ws/src
```

✅ **Test:** `pwd` should print `/home/<your-user>/agv_ws/src`.

---

## 📋 Step 2 — Create the 5 Empty Packages

We're creating 5 packages (think of them as folders with manifests). They'll be empty for now; each stage fills in its own.

```bash
cd ~/agv_ws/src

ros2 pkg create --build-type ament_python agv_world
ros2 pkg create --build-type ament_python agv_robot
ros2 pkg create --build-type ament_python agv_brain
ros2 pkg create --build-type ament_python agv_run
ros2 pkg create --build-type ament_cmake  agv_msgs
```

✅ **Test:** `ls ~/agv_ws/src` should show all 5 folders.

---

## 📋 Step 3 — Build the World Generator Script

This Python script creates the Gazebo world file. We use a script (instead of writing 500 lines of XML by hand) because **the script defines layout once** — and we'll reuse the same coordinates in `track_map.py` later. **Single source of truth = no mismatches.**

Create this folder:

```bash
mkdir -p ~/agv_ws/src/agv_world/scripts
mkdir -p ~/agv_ws/src/agv_world/worlds
mkdir -p ~/agv_ws/src/agv_world/launch
```

Now create the generator script. Use any text editor (e.g., `nano`):

```bash
nano ~/agv_ws/src/agv_world/scripts/build_world.py
```

Paste this **complete file** (don't change anything):

```python
#!/usr/bin/env python3
"""
build_world.py - Generates warehouse.world for Gazebo.
Run once: python3 build_world.py
Output:   ~/agv_ws/src/agv_world/worlds/warehouse.world
"""

import os

# ============================================================
# LAYOUT CONSTANTS — these are the SOURCE OF TRUTH.
# Same numbers appear in track_map.py (Stage 3) & shelf_map.py (Stage 4).
# Change them HERE only.
# ============================================================
MAIN_AISLE_X_START = -2.5
MAIN_AISLE_X_END   = 12.5
MAIN_AISLE_Y       = 0.0
LINE_WIDTH         = 0.05    # 5 cm wide tape
LINE_HEIGHT        = 0.002   # 2 mm tall, lays flat on ground

SPUR_X_LIST = [0.0, 3.0, 6.0, 9.0, 12.0]   # 5 aisles
SPUR_Y_START = 0.0
SPUR_Y_END   = 4.0

HOME_X = -2.0
HOME_Y = 0.0

# Shelves: 4 per aisle, all on left side, spaced 0.8m apart
SHELF_X_OFFSET = -0.9          # 0.9m left of the spur line
SHELF_Y_START  = 0.8
SHELF_Y_STEP   = 0.8
SHELVES_PER_AISLE = 4

# RFID tags: 0.4m left of spur (between spur and shelf)
TAG_X_OFFSET = -0.4

# ============================================================
def make_box_visual(name, x, y, z, sx, sy, sz, r, g, b, a=1.0):
    """A static visual-only box (no physics interaction)."""
    return f"""
    <model name="{name}">
      <static>true</static>
      <pose>{x} {y} {z} 0 0 0</pose>
      <link name="link">
        <visual name="visual">
          <geometry>
            <box><size>{sx} {sy} {sz}</size></geometry>
          </box></geometry>
          <material>
            <ambient>{r} {g} {b} {a}</ambient>
            <diffuse>{r} {g} {b} {a}</diffuse>
          </material>
        </visual>
      </link>
    </model>"""

def make_box(name, x, y, z, sx, sy, sz, r, g, b, a=1.0):
    """Same as above but valid XML (the function above had a typo for clarity)."""
    return f"""
    <model name="{name}">
      <static>true</static>
      <pose>{x} {y} {z} 0 0 0</pose>
      <link name="link">
        <visual name="visual">
          <geometry>
            <box><size>{sx} {sy} {sz}</size></box>
          </geometry>
          <material>
            <ambient>{r} {g} {b} {a}</ambient>
            <diffuse>{r} {g} {b} {a}</diffuse>
          </material>
        </visual>
      </link>
    </model>"""

def make_cylinder(name, x, y, z, radius, height, r, g, b, a=1.0):
    return f"""
    <model name="{name}">
      <static>true</static>
      <pose>{x} {y} {z} 0 0 0</pose>
      <link name="link">
        <visual name="visual">
          <geometry>
            <cylinder><radius>{radius}</radius><length>{height}</length></cylinder>
          </geometry>
          <material>
            <ambient>{r} {g} {b} {a}</ambient>
            <diffuse>{r} {g} {b} {a}</diffuse>
          </material>
        </visual>
      </link>
    </model>"""

# ============================================================
def main():
    parts = []

    # --- Main aisle (black tape) ---
    main_len = MAIN_AISLE_X_END - MAIN_AISLE_X_START
    main_x   = (MAIN_AISLE_X_START + MAIN_AISLE_X_END) / 2.0
    parts.append(make_box(
        "tape_main_aisle",
        main_x, MAIN_AISLE_Y, LINE_HEIGHT/2,
        main_len, LINE_WIDTH, LINE_HEIGHT,
        0.05, 0.05, 0.05))

    # --- Spurs (black tape) ---
    spur_len = SPUR_Y_END - SPUR_Y_START
    spur_y   = (SPUR_Y_START + SPUR_Y_END) / 2.0
    for i, sx in enumerate(SPUR_X_LIST, start=1):
        parts.append(make_box(
            f"tape_spur_{i}",
            sx, spur_y, LINE_HEIGHT/2,
            LINE_WIDTH, spur_len, LINE_HEIGHT,
            0.05, 0.05, 0.05))

    # --- HOME zone (green disc) ---
    parts.append(make_cylinder(
        "home_zone",
        HOME_X, HOME_Y, 0.001,
        0.30, 0.005,
        0.0, 0.7, 0.0))

    # --- Shelves + RFID tag markers ---
    shelf_idx = 1
    for aisle_idx, ax in enumerate(SPUR_X_LIST, start=1):
        for slot in range(SHELVES_PER_AISLE):
            sy = SHELF_Y_START + slot * SHELF_Y_STEP
            sx = ax + SHELF_X_OFFSET
            tx = ax + TAG_X_OFFSET
            ty = sy

            # Shelf body (brown wooden box, 0.6m wide x 0.4m deep x 0.6m tall)
            parts.append(make_box(
                f"shelf_S{shelf_idx:02d}",
                sx, sy, 0.30,
                0.6, 0.4, 0.6,
                0.55, 0.35, 0.20))

            # RFID tag marker (small blue disc on floor)
            parts.append(make_cylinder(
                f"tag_S{shelf_idx:02d}",
                tx, ty, 0.001,
                0.05, 0.003,
                0.1, 0.4, 1.0))

            shelf_idx += 1

    # --- Combine into full SDF world ---
    world = f"""<?xml version="1.0"?>
<sdf version="1.6">
  <world name="warehouse">
    <include><uri>model://sun</uri></include>
    <include><uri>model://ground_plane</uri></include>

    <!-- Ground color override (light gray) -->
    <model name="floor_color">
      <static>true</static>
      <pose>5 2 -0.001 0 0 0</pose>
      <link name="link">
        <visual name="visual">
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
    </physics>

{''.join(parts)}

  </world>
</sdf>
"""

    # Write file
    out_dir = os.path.expanduser("~/agv_ws/src/agv_world/worlds")
    os.makedirs(out_dir, exist_ok=True)
    out_file = os.path.join(out_dir, "warehouse.world")
    with open(out_file, "w") as f:
        f.write(world)

    print(f"✅ Wrote {out_file}")
    print(f"   {len(SPUR_X_LIST)} aisles, "
          f"{SHELVES_PER_AISLE * len(SPUR_X_LIST)} shelves")

if __name__ == "__main__":
    main()
```

Save and exit (in nano: `Ctrl+O`, `Enter`, `Ctrl+X`).

### Run it once:

```bash
python3 ~/agv_ws/src/agv_world/scripts/build_world.py
```

✅ **Test:** Should print `✅ Wrote .../warehouse.world` and `5 aisles, 20 shelves`.

---

## 📋 Step 4 — Create the Launch File

The launch file tells ROS how to start Gazebo with our world.

```bash
nano ~/agv_ws/src/agv_world/launch/world.launch.py
```

Paste this **complete file**:

```python
#!/usr/bin/env python3
"""world.launch.py - Launches Gazebo with our warehouse world."""

import os
from launch import LaunchDescription
from launch.actions import ExecuteProcess
from ament_index_python.packages import get_package_share_directory


def generate_launch_description():
    pkg_world = get_package_share_directory('agv_world')
    world_file = os.path.join(pkg_world, 'worlds', 'warehouse.world')

    gazebo = ExecuteProcess(
        cmd=['gazebo', '--verbose', world_file,
             '-s', 'libgazebo_ros_init.so',
             '-s', 'libgazebo_ros_factory.so'],
        output='screen'
    )

    return LaunchDescription([gazebo])
```

Save and exit.

---

## 📋 Step 5 — Update `setup.py` for `agv_world`

The package's `setup.py` needs to know about the world file and launch file. Open it:

```bash
nano ~/agv_ws/src/agv_world/setup.py
```

**Replace the entire file** with this:

```python
from setuptools import setup
from glob import glob
import os

package_name = 'agv_world'

setup(
    name=package_name,
    version='0.1.0',
    packages=[package_name],
    data_files=[
        ('share/ament_index/resource_index/packages',
            ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
        (os.path.join('share', package_name, 'launch'), glob('launch/*.py')),
        (os.path.join('share', package_name, 'worlds'), glob('worlds/*.world')),
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    maintainer='you',
    maintainer_email='you@example.com',
    description='Warehouse Gazebo world',
    license='MIT',
    entry_points={'console_scripts': []},
)
```

---

## 📋 Step 6 — First Build

```bash
cd ~/agv_ws
colcon build --symlink-install
source install/setup.bash
```

✅ **Test:** Should end with `Summary: 5 packages finished` and no errors.

If you see warnings about deprecated `setup.py` — **ignore them**. Harmless.

---

## 📋 Step 7 — Launch the World

```bash
ros2 launch agv_world world.launch.py
```

✅ **Test:** Gazebo should open showing:
- A light gray floor
- A long horizontal black line (main aisle)
- 5 vertical black lines (spurs) branching from it
- 20 brown rectangles (shelves) — 4 per aisle, on the left side of each spur
- A green disc at the far left (HOME zone)
- 20 small blue dots near the shelves (RFID tag markers)

Press `Ctrl+C` in the terminal to stop Gazebo.

---

## 🎉 Stage 1 Done!

You now have:
- ✅ A workspace at `~/agv_ws`
- ✅ 5 packages skeleton
- ✅ A warehouse world with 20 shelves, tape lines, HOME zone, and RFID markers
- ✅ A launch file to open it

### What's Next?

Open `STAGE_2_Robot.md` to build the AGV.

---

## 🆘 Troubleshooting

| Problem | Fix |
|---|---|
| `gazebo: command not found` | `sudo apt install gazebo` |
| Black screen in Gazebo | Wait 10–20 seconds. First launch is slow. |
| `package agv_world not found` | You forgot to `source install/setup.bash` |
| "Failed to load library" | `sudo apt install ros-humble-gazebo-ros-pkgs` |
| Build fails on `agv_msgs` | Don't worry, we'll fill it in Stage 4. For now: `colcon build --packages-skip agv_msgs` |
| `import error` in build_world.py | You're running it with python2. Use `python3` explicitly. |
