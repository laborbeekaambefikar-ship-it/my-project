# 🚀 START HERE — Warehouse AGV Project, Fresh & Clean

> Welcome back! This is your **complete project guide**. Every command. Every file. Every test. No shortcuts. No "see earlier section." Everything is here.

---

## 📋 What You're Building

A simulated warehouse robot ("AGV") that:
1. Sits at a **HOME position**, waiting for orders
2. Receives an order ("go to shelf S07")
3. Drives along **black tape lines** on the floor
4. Turns into the right aisle to find the shelf
5. Stops at the shelf, waits, turns 180°, comes home
6. Has a button on a GUI to send orders

Layout: **4 rows × 5 aisles = 20 shelves**, with a main horizontal aisle and 5 vertical spurs.

---

## 🎯 Why This Tutorial Is Different (vs. the old one)

| Old Plan | New Plan |
|---|---|
| Used a downward camera | Uses **optical sensors** (no camera bugs) |
| Long folder/file names | **Short names** (`agv_ws/` not `warehouse_agv_sim/`) |
| 5 separate stages, lots of context-switching | **5 stages, fully self-contained** (each file works alone) |
| Some bugs in original code | **All bugs fixed up front** |
| Junction handler used X-coordinates only | Junction handler uses **sensors AND coordinates** |
| Speed too slow (PID was scaling x100) | Speed correctly tuned, **fast and stable** |
| "Edit this part" instructions | **Full files**, copy-paste only |

---

## 📁 New Naming Conventions (Memorize These)

| Old name | New name |
|---|---|
| `warehouse_agv_sim` | **`agv_ws`** (the workspace) |
| `agv_description` | **`agv_robot`** (the robot's body) |
| `agv_control` | **`agv_brain`** (the robot's brain) |
| `agv_msgs` | **`agv_msgs`** (kept — it's already short) |
| `agv_bringup` | **`agv_run`** (master launcher) |
| `warehouse_world` | **`agv_world`** (the warehouse) |

So your project tree will look like:

```
~/agv_ws/
└── src/
    ├── agv_robot/      ← URDF, launch, RViz config
    ├── agv_world/      ← Gazebo world
    ├── agv_msgs/       ← Custom message types
    ├── agv_brain/      ← Python nodes
    └── agv_run/        ← Master launchers
```

Way cleaner, way shorter.

---

## ⏱️ Time Estimates Per Stage

| Stage | What You Build | Time |
|---|---|---|
| **Stage 1** | Workspace + warehouse world | 30 min |
| **Stage 2** | The AGV robot (URDF) | 30 min |
| **Stage 3** | Optical sensors + line follower | 45 min |
| **Stage 4** | Brain (state machine, RFID, junctions) | 90 min |
| **Stage 5** | GUI + final polish | 30 min |
| **Total** | | **~3.5 hours** of careful work |

**Don't try to do it in one sitting.** One stage per session is healthy.

---

## 📚 The Files in This Tutorial

| File | Purpose |
|---|---|
| `START_HERE.md` | This file. Read first. |
| `STAGE_1_World.md` | Build the warehouse + workspace |
| `STAGE_2_Robot.md` | Build the AGV robot |
| `STAGE_3_Driving.md` | Make it drive on lines |
| `STAGE_4_Brain.md` | Make it autonomous |
| `STAGE_5_GUI.md` | Add the GUI |

**Always do them in order.** Each stage tests the previous one.

---

## 🔧 One-Time Setup (Do This Once Before Stage 1)

If you haven't already, install the system tools you'll need. Open a terminal and run **all** of these:

```bash
sudo apt update
sudo apt install -y \
    ros-humble-desktop-full \
    ros-humble-gazebo-ros-pkgs \
    ros-humble-xacro \
    ros-humble-joint-state-publisher-gui \
    ros-humble-teleop-twist-keyboard \
    ros-humble-visualization-msgs \
    python3-colcon-common-extensions \
    python3-tk \
    python3-numpy
```

That's it. No more `apt install` commands needed for the rest of the project.

---

## 🚦 Universal Rules — Read Before Every Stage

### Rule 1: Always source ROS in every new terminal
Before doing anything in a new terminal:
```bash
source /opt/ros/humble/setup.bash
```

After you've built your project at least once:
```bash
source /opt/ros/humble/setup.bash
source ~/agv_ws/install/setup.bash
```

### Rule 2: After editing any code file, rebuild
```bash
cd ~/agv_ws
colcon build --symlink-install
source install/setup.bash
```

The `--symlink-install` flag means future Python edits don't need a rebuild — just save the file. Magic.

### Rule 3: If something is "weird," do a clean rebuild
```bash
cd ~/agv_ws
rm -rf build/ install/ log/
colcon build --symlink-install
source install/setup.bash
```

This is the universal "fix it" command. ~95% of weird bugs are caused by stale build artifacts.

### Rule 4: Test after every single step
Each stage has tests **between** the steps, not just at the end. Don't skip them. If a test fails, fix it before moving on. **Five minutes of testing saves an hour of debugging.**

### Rule 5: When something breaks, run this
```bash
ros2 node list           # what nodes are running?
ros2 topic list          # what topics exist?
ros2 topic echo <topic>  # what's being published?
```
These three commands solve 80% of "it doesn't work" problems.

---

## 🆘 If You Get Stuck

1. **Re-read the step.** Sometimes you missed a line.
2. **Check the test for that step.** It tells you what should happen.
3. **Open a new terminal** and source it freshly. Old terminals can have stale state.
4. **Do a clean rebuild** (Rule 3 above).
5. **Tell me exactly which step you're at and paste the error.** I'll help.

---

## ✅ Ready to Start?

Open `STAGE_1_World.md` and go. Take your time. You've got this. 💪

---

**Quick reference card** — pin this somewhere:

```
Workspace:       ~/agv_ws
Build:           cd ~/agv_ws && colcon build --symlink-install
Source:          source ~/agv_ws/install/setup.bash
Clean rebuild:   rm -rf build/ install/ log/ && colcon build --symlink-install
Run a node:      ros2 run <package> <executable>
List nodes:      ros2 node list
List topics:     ros2 topic list
Echo a topic:    ros2 topic echo <topic_name>
```
