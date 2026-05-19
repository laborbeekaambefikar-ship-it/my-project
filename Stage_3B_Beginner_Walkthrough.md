# 🎓 Beginner's Walkthrough — Camera → Optical Sensor Migration

> A hand-holding, no-confusion guide. Read top to bottom. Don't skip sections.

---

# 📚 PART 1: Understand What We're Doing (5-minute read)

## The Analogy

Imagine your AGV used a **webcam pointed at the floor** (old way). Every frame it took a photo, looked at 8 specific pixels, and asked: *"Are these black or white?"*

Now we're replacing that webcam with **8 tiny IR sensors** mounted in a row under the AGV (new way). Each sensor directly tells you: *"I see black"* or *"I see white"* — no photos involved.

**The result is the same** (8 binary numbers), but the way we get those numbers is much more reliable.

## What Are We Actually Building?

In the simulation, we don't have real IR sensors. We **fake them** using math:

1. The AGV publishes its position 50 times per second on `/agv/odom`
2. Our new node reads that position
3. It calculates: *"If 8 sensors were mounted at these exact spots under the AGV, where would they be in the world right now?"*
4. For each sensor's world position, it asks: *"Is there black tape there?"*
5. It publishes 8 binary values: `[0, 0, 0, 1, 1, 0, 0, 0]`

That's it. No camera. No image processing. No OpenCV. Just **math + geometry**.

## Why Is This Better Than the Camera?

| Problem with Camera | Solution with Optical Sensor |
|---|---|
| Camera plugin sometimes doesn't load | No plugin needed |
| `cv_bridge` errors on import | No OpenCV needed |
| Image messages have QoS quirks | Plain Float arrays work fine |
| Lighting in Gazebo affects readings | Pure geometry, no lighting |
| 30 FPS, sometimes stutters | Solid 50 Hz, never drops |
| Hard to debug (can't see what camera sees easily) | RViz markers show exactly what each sensor sees |

---

# 🗺️ PART 2: The Mental Model — Before vs After

## How Data Flowed BEFORE (Camera Version)

```
   Gazebo renders camera image
           ↓
   /agv/line_cam/image_raw  (sensor_msgs/Image)
           ↓
   line_follower_node.py
   ├── Convert image to OpenCV format (cv_bridge)
   ├── Pick a row of pixels at 75% of image height
   ├── Sample 8 evenly-spaced pixels from that row
   ├── Convert to grayscale
   ├── Threshold (< 80 = black, ≥ 80 = white)
   ├── Get [0,0,0,1,1,0,0,0]
   ├── Run PID on those 8 values
   └── Publish to /agv/cmd_vel
```

That's a LOT of steps. Each one can fail.

## How Data Flows AFTER (Optical Sensor Version)

```
   Gazebo publishes AGV pose (already does this — no change)
           ↓
   /agv/odom  (nav_msgs/Odometry)
           ↓
   optical_sensor_node.py  ⭐ NEW FILE
   ├── Get AGV's (x, y, yaw)
   ├── Calculate world position of each of 8 virtual sensors
   ├── Ask track_map.py: "is this point on a black tape line?"
   ├── Get [0,0,0,1,1,0,0,0]
   └── Publish to /agv/line_sensors
           ↓
   line_follower_node.py  (REWRITTEN — much simpler now)
   ├── Receive [0,0,0,1,1,0,0,0]
   ├── Run PID on those 8 values
   └── Publish to /agv/cmd_vel
```

Notice the trick: **we split the old `line_follower_node.py` into two files**:
- `optical_sensor_node.py` — does the "sensor reading" part
- `line_follower_node.py` — does ONLY the PID part

That's the entire migration in one picture.

---

# 📁 PART 3: Every File in Your Project — What's Its Job?

Before we change anything, let me explain **what each file does** so you understand why we're touching some and not others.

## Files in Your Project

```
~/warehouse_agv_sim/src/
│
├── agv_msgs/                          ← Custom message definitions
│   └── msg/
│       ├── Order.msg                  ← Stays. No camera here.
│       ├── RFIDRead.msg               ← Stays. No camera here.
│       └── AGVState.msg               ← Stays. No camera here.
│
├── agv_description/                   ← What the robot LOOKS like
│   ├── urdf/
│   │   ├── turtlebot3_burger_base.xacro   ← Body. No camera here. STAYS.
│   │   ├── tray.xacro                     ← Orange tray. STAYS.
│   │   ├── sensors.xacro                  ← ⚠️ CAMERA LIVES HERE — MUST EDIT
│   │   └── agv.urdf.xacro                 ← Master include file. STAYS.
│   ├── launch/
│   │   ├── spawn_agv.launch.py            ← Launches Gazebo. STAYS.
│   │   └── display.launch.py              ← Launches RViz only. STAYS.
│   ├── rviz/
│   │   └── agv_view.rviz                  ← ⚠️ CAMERA PANEL HERE — MUST EDIT
│   └── package.xml + setup.py             ← STAYS.
│
├── warehouse_world/                   ← The warehouse environment
│   ├── scripts/generate_world.py      ← STAYS. No changes.
│   ├── worlds/warehouse.world         ← STAYS. No changes.
│   └── launch/warehouse.launch.py     ← STAYS. No changes.
│
├── agv_control/                       ← ALL THE BRAINS
│   ├── agv_control/
│   │   ├── line_follower_node.py      ← ⚠️ MUST REPLACE ENTIRE FILE
│   │   ├── optical_sensor_node.py     ← ⭐ NEW FILE — CREATE
│   │   ├── track_map.py               ← ⭐ NEW FILE — CREATE
│   │   ├── shelf_map.py               ← STAYS. Already exists.
│   │   ├── rfid_reader_node.py        ← STAYS. No camera here.
│   │   ├── junction_handler_node.py   ← STAYS. No camera here.
│   │   ├── pivot_controller_node.py   ← STAYS. No camera here.
│   │   ├── arm_stub_node.py           ← STAYS. No camera here.
│   │   ├── state_machine_node.py      ← STAYS. No camera here.
│   │   ├── send_order.py              ← STAYS. No camera here.
│   │   └── gui_node.py                ← STAYS. No camera here.
│   ├── launch/
│   │   ├── line_follower.launch.py    ← STAYS (or delete — not used).
│   │   └── agv_brain.launch.py        ← ⚠️ ADD ONE LINE
│   ├── config/
│   │   └── line_follower_params.yaml  ← ⚠️ DELETE 4 LINES
│   ├── package.xml                    ← ⚠️ EDIT 2 LINES
│   └── setup.py                       ← ⚠️ ADD ONE LINE
│
└── agv_bringup/                       ← The "launch everything" package
    ├── launch/
    │   └── full_demo.launch.py        ← ⚠️ ADD ONE LINE
    └── package.xml + setup.py         ← STAYS.
```

## Score Card

| Action | Count | Files |
|---|---|---|
| ⭐ **Create new** | 2 | `track_map.py`, `optical_sensor_node.py` |
| ✏️ **Edit** | 7 | `sensors.xacro`, `agv_view.rviz`, `line_follower_node.py`, `agv_brain.launch.py`, `full_demo.launch.py`, `line_follower_params.yaml`, `package.xml`, `setup.py` |
| ✅ **Leave alone** | Everything else | |

So out of ~25 files in your project, you're only touching 9 of them. **The other 16 don't know or care that anything changed.**

---

# 🔧 PART 4: The Step-By-Step Execution

I'm going to give you a strict order. **Do not skip ahead.** Each step is testable, so if something breaks you'll know exactly which step caused it.

---

## ⏱️ STEP 0 — Backup First (1 minute)

Before touching anything, save your current state:

```bash
cd ~/warehouse_agv_sim
git add -A
git commit -m "Snapshot before optical sensor migration"
```

If you don't use git, just zip the folder:
```bash
cd ~
cp -r warehouse_agv_sim warehouse_agv_sim_BACKUP_camera_version
```

✅ **Checkpoint:** You can always go back if something breaks.

---

## ⏱️ STEP 1 — Edit `sensors.xacro` (Remove Camera, Add IR Sensors) (10 minutes)

📂 **File location:**
```
~/warehouse_agv_sim/src/agv_description/urdf/sensors.xacro
```

📖 **What this file does:** It defines which sensors are bolted onto the robot. Currently it has 3 sensors: a downward camera, an RFID reader, and an IMU.

🎯 **Goal:** Remove the camera, replace it with 8 IR sensor placeholders. Keep the RFID reader and IMU.

### 1A. DELETE this entire chunk

Open the file and find this big section. **Delete every line of it:**

```xml
  <!-- ============================================================ -->
  <!--  DOWNWARD-FACING CAMERA (for line following)                 -->
  <!--  Mounted at front-bottom of chassis, pointing straight down  -->
  <!-- ============================================================ -->
  <link name="line_cam_link">
    <visual>
      <origin xyz="0 0 0" rpy="0 0 0"/>
      <geometry>
        <box size="0.020 0.030 0.015"/>
      </geometry>
      <material name="blue"/>
    </visual>
    <inertial>
      <mass value="0.01"/>
      <inertia ixx="0.00001" ixy="0.0" ixz="0.0"
               iyy="0.00001" iyz="0.0" izz="0.00001"/>
    </inertial>
  </link>

  <joint name="line_cam_joint" type="fixed">
    <parent link="base_link"/>
    <child  link="line_cam_link"/>
    <origin xyz="0.060 0 0.010" rpy="0 1.5708 0"/>
  </joint>

  <link name="line_cam_optical"/>
  <joint name="line_cam_optical_joint" type="fixed">
    <parent link="line_cam_link"/>
    <child  link="line_cam_optical"/>
    <origin xyz="0 0 0" rpy="-1.5708 0 -1.5708"/>
  </joint>

  <gazebo reference="line_cam_link">
    <material>Gazebo/Blue</material>
    <sensor name="line_camera" type="camera">
      <update_rate>30.0</update_rate>
      <visualize>true</visualize>
      <camera>
        <horizontal_fov>1.0472</horizontal_fov>
        <image>
          <width>160</width>
          <height>120</height>
          <format>R8G8B8</format>
        </image>
        <clip>
          <near>0.005</near>
          <far>0.5</far>
        </clip>
      </camera>
      <plugin name="line_camera_controller" filename="libgazebo_ros_camera.so">
        <ros>
          <namespace>/agv</namespace>
          <remapping>image_raw:=line_cam/image_raw</remapping>
          <remapping>camera_info:=line_cam/camera_info</remapping>
        </ros>
        <frame_name>line_cam_optical</frame_name>
      </plugin>
    </sensor>
  </gazebo>
```

> 🔍 **How to find it:** Search for the word `line_cam` in your editor. Every line that contains `line_cam`, `line_camera`, or is part of the camera's `<gazebo>` block should be deleted.

### 1B. ADD this new chunk in the same place

Paste this where the camera block used to be (anywhere in the `<robot>` element works, but putting it where the camera was keeps things organized):

```xml
  <!-- ============================================================ -->
  <!--  VIRTUAL OPTICAL (IR) SENSOR ARRAY                           -->
  <!--  8 sensors evenly spaced across the front-bottom of the AGV. -->
  <!--  These are visual-only links — the actual sensor reading     -->
  <!--  happens in optical_sensor_node.py via odometry + geometry.  -->
  <!-- ============================================================ -->

  <xacro:macro name="ir_sensor" params="idx y_offset">
    <link name="ir_sensor_${idx}_link">
      <visual>
        <origin xyz="0 0 0" rpy="0 0 0"/>
        <geometry>
          <box size="0.006 0.006 0.004"/>
        </geometry>
        <material name="blue"/>
      </visual>
      <inertial>
        <mass value="0.001"/>
        <inertia ixx="1e-7" ixy="0" ixz="0" iyy="1e-7" iyz="0" izz="1e-7"/>
      </inertial>
    </link>

    <joint name="ir_sensor_${idx}_joint" type="fixed">
      <parent link="base_link"/>
      <child  link="ir_sensor_${idx}_link"/>
      <origin xyz="0.080 ${y_offset} 0.005" rpy="0 0 0"/>
    </joint>

    <gazebo reference="ir_sensor_${idx}_link">
      <material>Gazebo/Blue</material>
    </gazebo>
  </xacro:macro>

  <!-- 8 sensors: index 1 (leftmost) through 8 (rightmost), 12mm apart -->
  <xacro:ir_sensor idx="1" y_offset="0.042"/>
  <xacro:ir_sensor idx="2" y_offset="0.030"/>
  <xacro:ir_sensor idx="3" y_offset="0.018"/>
  <xacro:ir_sensor idx="4" y_offset="0.006"/>
  <xacro:ir_sensor idx="5" y_offset="-0.006"/>
  <xacro:ir_sensor idx="6" y_offset="-0.018"/>
  <xacro:ir_sensor idx="7" y_offset="-0.030"/>
  <xacro:ir_sensor idx="8" y_offset="-0.042"/>
```

### 1C. Verify the file is still valid

Test that xacro can parse it:
```bash
cd ~/warehouse_agv_sim
source /opt/ros/humble/setup.bash
xacro src/agv_description/urdf/agv.urdf.xacro > /tmp/test.urdf
echo "Exit code: $?"
```

✅ **Checkpoint:** Exit code should be `0`. The file `/tmp/test.urdf` should exist and contain XML. If you see errors, you probably deleted a `</robot>` tag by accident — re-check the file.

---

## ⏱️ STEP 2 — Create `track_map.py` (NEW FILE) (5 minutes)

📂 **File location (this file does NOT exist yet — create it):**
```
~/warehouse_agv_sim/src/agv_control/agv_control/track_map.py
```

📖 **What this file does:** It's the "ground truth" of where black tape lines exist in the warehouse. Just like `shelf_map.py` knows where shelves are, this file knows where lines are.

🎯 **Goal:** Define line geometry so we can ask "is point (X, Y) on a black tape line?"

### 2A. Create the file

```bash
nano ~/warehouse_agv_sim/src/agv_control/agv_control/track_map.py
```

Paste in **the exact contents** from `Stage_3B_Optical_Sensor_Migration.md`, Sub-Stage 3B-2 (it's a long file — I won't reprint here. Just copy from that document).

### 2B. Test it

```bash
python3 ~/warehouse_agv_sim/src/agv_control/agv_control/track_map.py
```

✅ **Checkpoint:** You should see output like:
```
🛣️  Track has 6 segments:
   main_aisle      (-2.50,+0.00) → (+12.50,+0.00)
   spur_1          (+0.00,+0.00) → (+0.00,+4.00)
   spur_2          (+3.00,+0.00) → (+3.00,+4.00)
   spur_3          (+6.00,+0.00) → (+6.00,+4.00)
   spur_4          (+9.00,+0.00) → (+9.00,+4.00)
   spur_5          (+12.00,+0.00) → (+12.00,+4.00)

🧪 Self-test:
   ✅ (+0.0,+0.0) [junction main+spur1] → on=True (main_aisle)
   ✅ (+1.5,+0.0) [on main aisle] → on=True (main_aisle)
   ✅ (+1.5,+0.5) [between spur1 and spur2, off main] → on=False ()
   ✅ (+3.0,+2.0) [on spur 2] → on=True (spur_2)
   ✅ (+3.0,+4.5) [past end of spur 2] → on=False ()
```

> ⚠️ **If your warehouse coordinates are different**, the self-tests might fail. That's OK — the failures tell you to update the constants at the top of `track_map.py` to match your `generate_world.py`.

---

## ⏱️ STEP 3 — Create `optical_sensor_node.py` (NEW FILE) (5 minutes)

📂 **File location (does NOT exist yet — create it):**
```
~/warehouse_agv_sim/src/agv_control/agv_control/optical_sensor_node.py
```

📖 **What this file does:** This is the "brain" of the optical sensor. Every 20ms it asks the AGV's position, calculates where each of the 8 sensors are in the world, asks `track_map.py` if they're on a line, and publishes the 8 binary values.

🎯 **Goal:** Replace what the camera + image processing used to do — but using math instead.

### 3A. Create the file

```bash
nano ~/warehouse_agv_sim/src/agv_control/agv_control/optical_sensor_node.py
```

Paste in **the exact contents** from `Stage_3B_Optical_Sensor_Migration.md`, Sub-Stage 3B-3.

### 3B. Don't test yet — it depends on other files we haven't built

Move on to Step 4. We'll test the whole chain at the end.

---

## ⏱️ STEP 4 — Replace `line_follower_node.py` (10 minutes)

📂 **File location (already exists — REPLACE its contents):**
```
~/warehouse_agv_sim/src/agv_control/agv_control/line_follower_node.py
```

📖 **What this file does:** This is your PID controller. It used to do TWO things (read camera + run PID). Now it does ONE thing (just run PID).

🎯 **Goal:** Make this file shorter and simpler. Remove all camera/OpenCV code.

### 4A. Save the old file (just in case)

```bash
cp ~/warehouse_agv_sim/src/agv_control/agv_control/line_follower_node.py \
   ~/warehouse_agv_sim/src/agv_control/agv_control/line_follower_node.py.OLD_camera_version
```

Now if anything goes wrong, the old version is right there.

### 4B. Replace the file completely

Open the file:
```bash
nano ~/warehouse_agv_sim/src/agv_control/agv_control/line_follower_node.py
```

Press `Ctrl+K` repeatedly to delete every line, OR just delete the whole file and create a fresh one:

```bash
rm ~/warehouse_agv_sim/src/agv_control/agv_control/line_follower_node.py
nano ~/warehouse_agv_sim/src/agv_control/agv_control/line_follower_node.py
```

Now paste the **NEW** contents from `Stage_3B_Optical_Sensor_Migration.md`, Sub-Stage 3B-4.

### 4C. Quick sanity check on the new file

```bash
python3 -c "import ast; ast.parse(open('/home/$USER/warehouse_agv_sim/src/agv_control/agv_control/line_follower_node.py').read()); print('OK')"
```

✅ **Checkpoint:** Should print `OK`. If you see a `SyntaxError`, the paste got mangled — try again.

---

## ⏱️ STEP 5 — Update `setup.py` (Add One Line) (2 minutes)

📂 **File location:**
```
~/warehouse_agv_sim/src/agv_control/setup.py
```

📖 **What this file does:** It tells ROS 2 which Python files are runnable nodes.

🎯 **Goal:** Tell ROS that `optical_sensor_node` exists and how to launch it.

### 5A. Find the `entry_points` section

Open the file. Find a section that looks like this:

```python
entry_points={
    'console_scripts': [
        'line_follower_node     = agv_control.line_follower_node:main',
        'rfid_reader_node       = agv_control.rfid_reader_node:main',
        # ...other nodes...
    ],
},
```

### 5B. Add ONE new line

Insert this line **right after** `line_follower_node`:

```python
        'optical_sensor_node    = agv_control.optical_sensor_node:main',
```

So the result looks like:

```python
entry_points={
    'console_scripts': [
        'line_follower_node     = agv_control.line_follower_node:main',
        'optical_sensor_node    = agv_control.optical_sensor_node:main',  ⭐ NEW
        'rfid_reader_node       = agv_control.rfid_reader_node:main',
        # ...other nodes...
    ],
},
```

### 5C. Save the file

In nano: `Ctrl+O`, then `Enter`, then `Ctrl+X`.

✅ **Checkpoint:** No test for this step — we'll catch errors when we build.

---

## ⏱️ STEP 6 — Update `package.xml` (Edit 2 Lines) (2 minutes)

📂 **File location:**
```
~/warehouse_agv_sim/src/agv_control/package.xml
```

📖 **What this file does:** Lists the system dependencies (Python libraries, ROS packages) this package needs.

🎯 **Goal:** Remove camera-only dependencies (cv_bridge, opencv) since we don't need them anymore.

### 6A. Find these two lines and DELETE them

```xml
<exec_depend>cv_bridge</exec_depend>
<exec_depend>python3-opencv</exec_depend>
```

### 6B. Add this one line

Anywhere in the `<exec_depend>` section:

```xml
<exec_depend>visualization_msgs</exec_depend>
```

This is needed because `optical_sensor_node.py` publishes RViz markers.

### 6C. Optional cleanup

If your file currently has `<exec_depend>sensor_msgs</exec_depend>`, you can leave it. Don't worry about it.

✅ **Checkpoint:** Save the file. No test yet.

---

## ⏱️ STEP 7 — Update `line_follower_params.yaml` (Delete 4 Lines) (1 minute)

📂 **File location:**
```
~/warehouse_agv_sim/src/agv_control/config/line_follower_params.yaml
```

📖 **What this file does:** Tunable parameters for the line follower.

🎯 **Goal:** Remove camera-only parameters.

### 7A. Delete these lines

```yaml
black_threshold: 80
sample_row_ratio: 0.75
num_samples: 8
publish_debug: true
```

### 7B. Keep the rest

The file should now look like this:

```yaml
line_follower_node:
  ros__parameters:
    linear_speed: 0.30
    kp: 0.012
    ki: 0.000
    kd: 0.004
    enabled: true
```

That's it. Just 5 parameters now (down from 9).

✅ **Checkpoint:** Save and continue.

---

## ⏱️ STEP 8 — Update Launch Files (Add One Line Each) (3 minutes)

There are TWO launch files to update. Both need the same change: add `optical_sensor_node` to the list of nodes that get launched.

### 8A. Update `agv_brain.launch.py`

📂 **File:**
```
~/warehouse_agv_sim/src/agv_control/launch/agv_brain.launch.py
```

Find this block:

```python
return LaunchDescription([
    Node(package='agv_control', executable='line_follower_node',
         name='line_follower_node', output='screen', parameters=[params]),
    Node(package='agv_control', executable='rfid_reader_node',
         name='rfid_reader_node', output='screen'),
    # ...
])
```

Add ONE new `Node(...)` entry **before** `line_follower_node`:

```python
return LaunchDescription([
    Node(package='agv_control', executable='optical_sensor_node',  ⭐ NEW
         name='optical_sensor_node', output='screen'),               ⭐ NEW
    Node(package='agv_control', executable='line_follower_node',
         name='line_follower_node', output='screen', parameters=[params]),
    Node(package='agv_control', executable='rfid_reader_node',
         name='rfid_reader_node', output='screen'),
    # ...
])
```

> 💡 **Why "before" line_follower_node?** ROS launches everything in parallel anyway, so the order doesn't actually matter. But it's logical to read top-down: "first the sensor publishes data, then the line follower consumes it."

### 8B. Update `full_demo.launch.py`

📂 **File:**
```
~/warehouse_agv_sim/src/agv_bringup/launch/full_demo.launch.py
```

Find the `brain_nodes = TimerAction(...)` block. Add the same new `Node(...)` entry inside its `actions=[...]` list:

```python
brain_nodes = TimerAction(
    period=5.0,
    actions=[
        Node(package='agv_control', executable='optical_sensor_node',  ⭐ NEW
             name='optical_sensor_node', output='screen'),               ⭐ NEW
        Node(package='agv_control', executable='line_follower_node',
             name='line_follower_node', output='screen', parameters=[params_file]),
        # ... rest unchanged
    ]
)
```

✅ **Checkpoint:** Save both files.

---

## ⏱️ STEP 9 — Update RViz Config (Replace Image Panel) (2 minutes)

📂 **File location:**
```
~/warehouse_agv_sim/src/agv_description/rviz/agv_view.rviz
```

📖 **What this file does:** Stores RViz's layout — which panels are open, what topics they're showing, etc.

🎯 **Goal:** Remove the broken camera image panel, add a marker panel showing the 8 IR sensors.

### 9A. Find this block and DELETE it

```yaml
- Class: rviz_default_plugins/Image
  Name: LineCamera
  Topic:
    Value: /agv/line_cam/image_raw
  Enabled: true
```

### 9B. Add this block in its place

```yaml
- Class: rviz_default_plugins/MarkerArray
  Name: IR Sensors
  Topic:
    Value: /agv/line_sensors_markers
  Enabled: true
```

> 💡 **What this does:** When you run RViz, you'll see 8 colored dots floating below the AGV. Red = sensing black tape. Green = sensing white floor. Way more useful than the old camera image.

✅ **Checkpoint:** Save the file.

---

## ⏱️ STEP 10 — Clean Build (5 minutes)

This is critical. Old build artifacts can cause "ghost" errors where the system tries to load the old camera plugin even though you removed it.

### 10A. Delete old build artifacts

```bash
cd ~/warehouse_agv_sim
rm -rf build/ install/ log/
```

### 10B. Build everything fresh

```bash
colcon build --symlink-install
```

This takes 1–2 minutes. Watch for errors.

### 10C. Source the new build

```bash
source install/setup.bash
```

✅ **Checkpoint:** You should see something like `Summary: 5 packages finished` with no failures. If anything failed, the error message will tell you which file is the problem — go back and re-check that step.

---

## ⏱️ STEP 11 — Test the Whole System (10 minutes)

Now we test everything works together.

### Test A: Just the URDF (no Gazebo)

```bash
ros2 launch agv_description display.launch.py
```

✅ **Checkpoint:**
- RViz opens
- You see the AGV
- You see 8 small blue dots on its underside (the IR sensors)
- No errors about cameras

If you see "8 blue dots," your URDF surgery worked.

Close RViz with `Ctrl+C`.

### Test B: Spawn AGV in Gazebo

```bash
ros2 launch agv_description spawn_agv.launch.py
```

✅ **Checkpoint:**
- Gazebo opens, warehouse loads
- AGV spawns at HOME zone
- No errors about `libgazebo_ros_camera.so`

Leave Gazebo running for the next test.

### Test C: Optical sensor publishes data

In a NEW terminal:
```bash
source ~/warehouse_agv_sim/install/setup.bash
ros2 run agv_control optical_sensor_node
```

You should see:
```
🔆 Optical Sensor Node started (8 virtual IR sensors)
```

In ANOTHER new terminal:
```bash
source ~/warehouse_agv_sim/install/setup.bash
ros2 topic echo /agv/line_sensors
```

✅ **Checkpoint:** You should see arrays of 8 numbers streaming at 50 Hz, like:
```
data: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
---
data: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
```

Right now they're all zero because the AGV is at HOME, off the lines. Drive it to the line:

In yet another terminal:
```bash
source ~/warehouse_agv_sim/install/setup.bash
ros2 run teleop_twist_keyboard teleop_twist_keyboard --ros-args -r cmd_vel:=/agv/cmd_vel
```

Press `i` repeatedly. Watch the topic echo terminal — when the AGV crosses onto the main aisle line, the middle values should flip to `1.0`:

```
data: [0.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0]
```

✅ **Checkpoint:** If the binary array reflects the line, **YOU DID IT**. The optical sensor is working.

### Test D: Full mission

Close everything (`Ctrl+C` in all terminals). Then:

```bash
ros2 launch agv_bringup full_demo.launch.py
```

When the GUI opens, pick `S07` and click **SEND ORDER**.

✅ **Checkpoint:** AGV navigates to S07, waits, pivots, returns home — same behavior as before, but now without any camera.

---

# ❓ PART 5: Common Confusions Cleared Up

## "Do I need to change Stage 2 files?"

**Only `sensors.xacro` and `agv_view.rviz`.** That's it. The other Stage 2 files (the chassis, tray, master URDF, launch files, package.xml) don't touch the camera.

## "Do I need to change Stage 4 files?"

**Only the launch file (`agv_brain.launch.py`) and `setup.py`.** None of the Stage 4 nodes (state machine, RFID reader, junction handler, pivot, arm stub) reference the camera. They all just use `/agv/odom`, `/agv/cmd_vel`, and the custom messages — none of which changed.

## "Will the GUI break?"

**No.** The GUI subscribes to `/agv/state` and publishes orders to `/agv/order`. It never touched the camera. It will keep working exactly the same.

## "Why do I need TWO new files (`track_map.py` AND `optical_sensor_node.py`)?"

Because they do different things:
- `track_map.py` = a **library** (just a list of lines + a function to query them). Doesn't run on its own.
- `optical_sensor_node.py` = a **ROS node** (runs in a loop, subscribes to topics, publishes topics). It USES `track_map.py` as a library.

This separation is good engineering — `track_map.py` could be reused by other nodes later (e.g., a "track visualizer" or a "path planner") without dragging in all the optical sensor logic.

## "What if the AGV doesn't see the line at all?"

99% of the time this is because **the coordinates in `track_map.py` don't match `generate_world.py`**.

**To fix:**
1. Open `~/warehouse_agv_sim/src/warehouse_world/scripts/generate_world.py`
2. Look for variables like `MAIN_AISLE_X_START`, `SPUR_X_POSITIONS`, etc.
3. Copy those exact values into the top of `track_map.py`
4. Re-run the self-test: `python3 ~/warehouse_agv_sim/src/agv_control/agv_control/track_map.py`

## "What if I see weird oscillation?"

The PID gains were tuned for noisy camera data. With clean IR data, you might need to reduce them:

```bash
ros2 param set /line_follower_node kp 0.008
ros2 param set /line_follower_node kd 0.003
```

Tune until smooth, then update `line_follower_params.yaml` permanently.

## "Why are the 8 sensor links called 'visual only'? Aren't they real sensors?"

In Gazebo terms:
- A **visual** is something you see in the 3D view but doesn't interact with physics
- A **collision** is something objects can bump into
- A **sensor** is something that generates data (camera, lidar, IR, etc.)

Our 8 IR sensors have ONLY a `<visual>` (the small blue boxes). They have no `<sensor>` element because we don't want Gazebo to simulate IR physics — we're doing it ourselves in `optical_sensor_node.py` using math. The visual is purely for "looking pretty in the 3D view."

## "Can I just delete the old `line_follower_node.py.OLD_camera_version` file?"

Yes, once everything works. Keeping it for a few days as a safety net is fine.

## "I'm getting an error 'visualization_msgs not found'"

```bash
sudo apt install ros-humble-visualization-msgs
```

## "I'm getting an error 'No module named agv_control.track_map'"

You forgot to rebuild after creating the new file:
```bash
cd ~/warehouse_agv_sim
colcon build --symlink-install
source install/setup.bash
```

Always re-source `install/setup.bash` in EVERY terminal after a build.

---

# 🏁 PART 6: Final Sanity Check Table

After completing all 11 steps, run through this list:

| ✅ Check | How to verify |
|---|---|
| ☐ Old camera files no longer referenced | `grep -r "line_cam" ~/warehouse_agv_sim/src` should return nothing |
| ☐ No cv_bridge imports | `grep -r "cv_bridge" ~/warehouse_agv_sim/src` should return nothing |
| ☐ track_map.py self-tests pass | `python3 ~/warehouse_agv_sim/src/agv_control/agv_control/track_map.py` shows ✅ |
| ☐ Build succeeds | `colcon build` finishes with no errors |
| ☐ AGV shows 8 blue dots in RViz | `ros2 launch agv_description display.launch.py` |
| ☐ Optical sensor publishes data | `ros2 topic echo /agv/line_sensors` shows arrays |
| ☐ Full mission works end-to-end | GUI → SEND ORDER → AGV completes mission |

If all 7 boxes are checked, you are 100% done with the migration. 🎉

---

# 🎁 Bonus: Visual Cheat Sheet

```
┌─────────────────────────────────────────────────────────────┐
│  CAMERA VERSION                                             │
│  ┌──────┐                                                   │
│  │Camera│ ──> /image_raw ──> [Process] ──> /line_sensors    │
│  └──────┘                                                   │
│                                                             │
│  Files involved:                                            │
│   - sensors.xacro (camera plugin)                           │
│   - line_follower_node.py (image processing + PID)          │
│   - cv_bridge, opencv (libraries)                           │
│   - line_cam_image_raw, camera_info (topics)                │
└─────────────────────────────────────────────────────────────┘

                            ⬇ MIGRATION ⬇

┌─────────────────────────────────────────────────────────────┐
│  OPTICAL SENSOR VERSION                                     │
│  ┌──────┐    ┌──────────┐    ┌─────────┐    ┌───────────┐  │
│  │ Odom │ ──>│ Optical  │───>│  Line   │───>│ Cmd_vel   │  │
│  │      │    │ Sensor   │    │Follower │    │           │  │
│  └──────┘    │  Node    │    │ (PID)   │    └───────────┘  │
│              └────┬─────┘    └─────────┘                   │
│                   │                                        │
│                   ▼ uses                                   │
│              ┌──────────┐                                  │
│              │track_map │                                  │
│              │  .py     │                                  │
│              └──────────┘                                  │
│                                                            │
│  Files involved:                                           │
│   - sensors.xacro (8 IR sensor visual links)               │
│   - track_map.py (NEW — line geometry library)             │
│   - optical_sensor_node.py (NEW — odom → binary)           │
│   - line_follower_node.py (REWRITTEN — just PID)           │
│   - line_sensors, line_sensors_markers (topics)            │
└─────────────────────────────────────────────────────────────┘
```

---

🚀 **You've got this. Take your time, do one step at a time, run the checkpoint after each step, and you'll be migrated in about an hour.**
