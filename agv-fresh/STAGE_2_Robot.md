# 🤖 Stage 2 — The AGV Robot

> **Goal:** Build the AGV's body (URDF), spawn it in the warehouse, and drive it manually with the keyboard.

**Time:** ~30 minutes. **Files created:** 1 URDF, 1 RViz config, 1 launch file.

---

## 🎯 What the AGV Looks Like

```
              TOP VIEW
   ┌─────────────────────────┐
   │      ╔═══════════╗       │
   │      ║   TRAY    ║       │  ← Orange flat top (for future arm)
   │      ╚═══════════╝       │
   │                          │
   │   ◆                ◆     │  ← Wheels
   │                          │
   │   ●●●●●●●●  ← 8 IR        │
   │   sensors                │
   │                          │
   └─────────────────────────┘
       ↑ FRONT (where IR sensors are)
       
       Footprint: 25 × 20 cm
```

The AGV has:
- A **chassis** (gray box)
- **2 driven wheels** + 1 passive caster
- An **orange tray** on top
- **8 small blue boxes** at the front-bottom (IR sensor placeholders — visual only; the actual sensor logic comes in Stage 3)
- An **IMU** (invisible link, used for pivoting in Stage 4)

---

## 📋 Step 1 — Create Folders

```bash
mkdir -p ~/agv_ws/src/agv_robot/urdf
mkdir -p ~/agv_ws/src/agv_robot/launch
mkdir -p ~/agv_ws/src/agv_robot/rviz
```

---

## 📋 Step 2 — Create the URDF

```bash
nano ~/agv_ws/src/agv_robot/urdf/agv.urdf.xacro
```

Paste this **complete file**:

```xml
<?xml version="1.0"?>
<robot name="agv" xmlns:xacro="http://www.ros.org/wiki/xacro">

  <!-- ========== MATERIALS ========== -->
  <material name="black"><color rgba="0.1 0.1 0.1 1"/></material>
  <material name="gray"><color rgba="0.4 0.4 0.4 1"/></material>
  <material name="orange"><color rgba="1.0 0.5 0.0 1"/></material>
  <material name="blue"><color rgba="0.1 0.3 1.0 1"/></material>

  <!-- ========== BASE FOOTPRINT (origin at floor) ========== -->
  <link name="base_footprint"/>

  <joint name="base_joint" type="fixed">
    <parent link="base_footprint"/>
    <child  link="base_link"/>
    <origin xyz="0 0 0.040" rpy="0 0 0"/>
  </joint>

  <!-- ========== CHASSIS ========== -->
  <link name="base_link">
    <visual>
      <origin xyz="0 0 0" rpy="0 0 0"/>
      <geometry><box size="0.25 0.20 0.08"/></geometry>
      <material name="gray"/>
    </visual>
    <collision>
      <origin xyz="0 0 0" rpy="0 0 0"/>
      <geometry><box size="0.25 0.20 0.08"/></geometry>
    </collision>
    <inertial>
      <mass value="2.0"/>
      <inertia ixx="0.01" ixy="0" ixz="0" iyy="0.015" iyz="0" izz="0.015"/>
    </inertial>
  </link>

  <!-- ========== TRAY ========== -->
  <link name="tray_link">
    <visual>
      <origin xyz="0 0 0.005" rpy="0 0 0"/>
      <geometry><box size="0.20 0.18 0.01"/></geometry>
      <material name="orange"/>
    </visual>
    <inertial>
      <mass value="0.05"/>
      <inertia ixx="1e-4" ixy="0" ixz="0" iyy="1e-4" iyz="0" izz="1e-4"/>
    </inertial>
  </link>
  <joint name="tray_joint" type="fixed">
    <parent link="base_link"/>
    <child  link="tray_link"/>
    <origin xyz="0 0 0.045" rpy="0 0 0"/>
  </joint>

  <!-- ========== LEFT WHEEL ========== -->
  <link name="wheel_left">
    <visual>
      <origin xyz="0 0 0" rpy="1.5708 0 0"/>
      <geometry><cylinder length="0.025" radius="0.04"/></geometry>
      <material name="black"/>
    </visual>
    <collision>
      <origin xyz="0 0 0" rpy="1.5708 0 0"/>
      <geometry><cylinder length="0.025" radius="0.04"/></geometry>
    </collision>
    <inertial>
      <mass value="0.1"/>
      <inertia ixx="1e-4" ixy="0" ixz="0" iyy="1e-4" iyz="0" izz="1e-4"/>
    </inertial>
  </link>
  <joint name="joint_left_wheel" type="continuous">
    <parent link="base_link"/>
    <child  link="wheel_left"/>
    <origin xyz="0 0.105 -0.005" rpy="0 0 0"/>
    <axis xyz="0 1 0"/>
  </joint>

  <!-- ========== RIGHT WHEEL ========== -->
  <link name="wheel_right">
    <visual>
      <origin xyz="0 0 0" rpy="1.5708 0 0"/>
      <geometry><cylinder length="0.025" radius="0.04"/></geometry>
      <material name="black"/>
    </visual>
    <collision>
      <origin xyz="0 0 0" rpy="1.5708 0 0"/>
      <geometry><cylinder length="0.025" radius="0.04"/></geometry>
    </collision>
    <inertial>
      <mass value="0.1"/>
      <inertia ixx="1e-4" ixy="0" ixz="0" iyy="1e-4" iyz="0" izz="1e-4"/>
    </inertial>
  </link>
  <joint name="joint_right_wheel" type="continuous">
    <parent link="base_link"/>
    <child  link="wheel_right"/>
    <origin xyz="0 -0.105 -0.005" rpy="0 0 0"/>
    <axis xyz="0 1 0"/>
  </joint>

  <!-- ========== CASTER (rear ball) ========== -->
  <link name="caster_link">
    <visual>
      <geometry><sphere radius="0.02"/></geometry>
      <material name="black"/>
    </visual>
    <collision>
      <geometry><sphere radius="0.02"/></geometry>
    </collision>
    <inertial>
      <mass value="0.02"/>
      <inertia ixx="1e-5" ixy="0" ixz="0" iyy="1e-5" iyz="0" izz="1e-5"/>
    </inertial>
  </link>
  <joint name="caster_joint" type="fixed">
    <parent link="base_link"/>
    <child  link="caster_link"/>
    <origin xyz="-0.10 0 -0.025" rpy="0 0 0"/>
  </joint>

  <!-- ========== IMU (invisible link) ========== -->
  <link name="imu_link"/>
  <joint name="imu_joint" type="fixed">
    <parent link="base_link"/>
    <child  link="imu_link"/>
    <origin xyz="0 0 0.01" rpy="0 0 0"/>
  </joint>

  <!-- ========== 8 IR SENSOR PLACEHOLDERS ==========
       Visual-only links. The optical_sensor_node (Stage 3) computes
       readings using odometry + track geometry — NOT Gazebo physics.
  -->
  <xacro:macro name="ir_sensor" params="idx y_offset">
    <link name="ir_${idx}">
      <visual>
        <geometry><box size="0.006 0.006 0.004"/></geometry>
        <material name="blue"/>
      </visual>
      <inertial>
        <mass value="0.001"/>
        <inertia ixx="1e-7" ixy="0" ixz="0" iyy="1e-7" iyz="0" izz="1e-7"/>
      </inertial>
    </link>
    <joint name="ir_${idx}_joint" type="fixed">
      <parent link="base_link"/>
      <child  link="ir_${idx}"/>
      <origin xyz="0.10 ${y_offset} -0.035" rpy="0 0 0"/>
    </joint>
  </xacro:macro>

  <xacro:ir_sensor idx="1" y_offset="0.042"/>
  <xacro:ir_sensor idx="2" y_offset="0.030"/>
  <xacro:ir_sensor idx="3" y_offset="0.018"/>
  <xacro:ir_sensor idx="4" y_offset="0.006"/>
  <xacro:ir_sensor idx="5" y_offset="-0.006"/>
  <xacro:ir_sensor idx="6" y_offset="-0.018"/>
  <xacro:ir_sensor idx="7" y_offset="-0.030"/>
  <xacro:ir_sensor idx="8" y_offset="-0.042"/>

  <!-- ========== GAZEBO MATERIALS ========== -->
  <gazebo reference="base_link"><material>Gazebo/Grey</material></gazebo>
  <gazebo reference="tray_link"><material>Gazebo/Orange</material></gazebo>
  <gazebo reference="wheel_left"><material>Gazebo/Black</material></gazebo>
  <gazebo reference="wheel_right"><material>Gazebo/Black</material></gazebo>
  <gazebo reference="caster_link"><material>Gazebo/Black</material></gazebo>

  <!-- ========== DIFFERENTIAL DRIVE PLUGIN ========== -->
  <gazebo>
    <plugin name="diff_drive" filename="libgazebo_ros_diff_drive.so">
      <ros>
        <namespace>/agv</namespace>
      </ros>
      <update_rate>50</update_rate>
      <left_joint>joint_left_wheel</left_joint>
      <right_joint>joint_right_wheel</right_joint>
      <wheel_separation>0.21</wheel_separation>
      <wheel_diameter>0.08</wheel_diameter>
      <max_wheel_torque>5.0</max_wheel_torque>
      <max_wheel_acceleration>5.0</max_wheel_acceleration>
      <command_topic>cmd_vel</command_topic>
      <publish_odom>true</publish_odom>
      <publish_odom_tf>true</publish_odom_tf>
      <publish_wheel_tf>true</publish_wheel_tf>
      <odometry_topic>odom</odometry_topic>
      <odometry_frame>odom</odometry_frame>
      <robot_base_frame>base_footprint</robot_base_frame>
    </plugin>
  </gazebo>

  <!-- ========== JOINT STATE PUBLISHER ========== -->
  <gazebo>
    <plugin name="joint_states" filename="libgazebo_ros_joint_state_publisher.so">
      <ros><namespace>/agv</namespace><remapping>~/out:=joint_states</remapping></ros>
      <update_rate>50</update_rate>
      <joint_name>joint_left_wheel</joint_name>
      <joint_name>joint_right_wheel</joint_name>
    </plugin>
  </gazebo>

  <!-- ========== IMU PLUGIN ========== -->
  <gazebo reference="imu_link">
    <sensor name="imu" type="imu">
      <update_rate>100</update_rate>
      <always_on>true</always_on>
      <plugin name="imu_plugin" filename="libgazebo_ros_imu_sensor.so">
        <ros>
          <namespace>/agv</namespace>
          <remapping>~/out:=imu</remapping>
        </ros>
        <frame_name>imu_link</frame_name>
      </plugin>
    </sensor>
  </gazebo>

</robot>
```

Save and exit.

---

## 📋 Step 3 — Create RViz Config

```bash
nano ~/agv_ws/src/agv_robot/rviz/view.rviz
```

Paste:

```yaml
Panels:
  - Class: rviz_common/Displays
    Name: Displays
Visualization Manager:
  Class: ""
  Displays:
    - Class: rviz_default_plugins/Grid
      Name: Grid
      Reference Frame: <Fixed Frame>
      Enabled: true
    - Class: rviz_default_plugins/RobotModel
      Name: RobotModel
      Description Topic: {Value: /robot_description}
      Enabled: true
    - Class: rviz_default_plugins/TF
      Name: TF
      Show Names: true
      Enabled: true
  Global Options:
    Fixed Frame: odom
    Background Color: 48; 48; 48
  Tools:
    - Class: rviz_default_plugins/Interact
    - Class: rviz_default_plugins/MoveCamera
  Views:
    Current:
      Class: rviz_default_plugins/Orbit
      Distance: 3
      Pitch: 0.5
Window Geometry: {Height: 700, Width: 1100}
```

---

## 📋 Step 4 — Create the Spawn Launch File

```bash
nano ~/agv_ws/src/agv_robot/launch/spawn.launch.py
```

Paste:

```python
#!/usr/bin/env python3
"""spawn.launch.py - Launches Gazebo + AGV + RViz together."""

import os
from launch import LaunchDescription
from launch.actions import ExecuteProcess
from launch.substitutions import Command
from launch_ros.actions import Node
from ament_index_python.packages import get_package_share_directory


def generate_launch_description():
    pkg_world = get_package_share_directory('agv_world')
    pkg_robot = get_package_share_directory('agv_robot')

    world_file = os.path.join(pkg_world, 'worlds', 'warehouse.world')
    urdf_file  = os.path.join(pkg_robot, 'urdf', 'agv.urdf.xacro')
    rviz_file  = os.path.join(pkg_robot, 'rviz', 'view.rviz')

    robot_description = Command(['xacro ', urdf_file])

    gazebo = ExecuteProcess(
        cmd=['gazebo', '--verbose', world_file,
             '-s', 'libgazebo_ros_init.so',
             '-s', 'libgazebo_ros_factory.so'],
        output='screen'
    )

    rsp = Node(
        package='robot_state_publisher',
        executable='robot_state_publisher',
        output='screen',
        parameters=[{'use_sim_time': True,
                     'robot_description': robot_description}]
    )

    spawn = Node(
        package='gazebo_ros',
        executable='spawn_entity.py',
        arguments=['-entity', 'agv',
                   '-topic', 'robot_description',
                   '-x', '-2.0', '-y', '0.0', '-z', '0.05',
                   '-Y', '0.0'],
        output='screen'
    )

    rviz = Node(
        package='rviz2',
        executable='rviz2',
        arguments=['-d', rviz_file],
        output='screen',
        parameters=[{'use_sim_time': True}]
    )

    return LaunchDescription([gazebo, rsp, spawn, rviz])
```

---

## 📋 Step 5 — Update `setup.py` for `agv_robot`

```bash
nano ~/agv_ws/src/agv_robot/setup.py
```

Replace with:

```python
from setuptools import setup
from glob import glob
import os

package_name = 'agv_robot'

setup(
    name=package_name,
    version='0.1.0',
    packages=[package_name],
    data_files=[
        ('share/ament_index/resource_index/packages',
            ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
        (os.path.join('share', package_name, 'urdf'),   glob('urdf/*.xacro')),
        (os.path.join('share', package_name, 'launch'), glob('launch/*.py')),
        (os.path.join('share', package_name, 'rviz'),   glob('rviz/*.rviz')),
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    maintainer='you',
    maintainer_email='you@example.com',
    description='AGV robot URDF + spawn',
    license='MIT',
    entry_points={'console_scripts': []},
)
```

---

## 📋 Step 6 — Update `package.xml` for `agv_robot`

```bash
nano ~/agv_ws/src/agv_robot/package.xml
```

Replace with:

```xml
<?xml version="1.0"?>
<package format="3">
  <name>agv_robot</name>
  <version>0.1.0</version>
  <description>AGV URDF and spawn launch</description>
  <maintainer email="you@example.com">you</maintainer>
  <license>MIT</license>

  <buildtool_depend>ament_python</buildtool_depend>

  <exec_depend>robot_state_publisher</exec_depend>
  <exec_depend>xacro</exec_depend>
  <exec_depend>gazebo_ros</exec_depend>
  <exec_depend>rviz2</exec_depend>

  <export><build_type>ament_python</build_type></export>
</package>
```

---

## 📋 Step 7 — Build

```bash
cd ~/agv_ws
colcon build --symlink-install --packages-skip agv_msgs
source install/setup.bash
```

✅ **Test:** `Summary: 4 packages finished` (we skipped `agv_msgs` because it's empty until Stage 4).

---

## 📋 Step 8 — Launch & Verify

```bash
ros2 launch agv_robot spawn.launch.py
```

✅ **Test:** Within ~10 seconds you should see:
- Gazebo opens with the warehouse
- A small **gray AGV with an orange tray** appears at the green HOME zone
- 8 tiny **blue boxes** visible at the front of the AGV (the IR sensor placeholders)
- RViz opens showing the robot model with TF frames

Don't close anything yet.

---

## 📋 Step 9 — Test Manual Driving (Teleop)

Open a **new terminal**:

```bash
source ~/agv_ws/install/setup.bash
ros2 run teleop_twist_keyboard teleop_twist_keyboard \
    --ros-args -r cmd_vel:=/agv/cmd_vel
```

You'll see keyboard controls. Press:
- **`i`** = forward
- **`,`** = backward
- **`j`** / **`l`** = turn left/right
- **`k`** = stop
- **`Ctrl+C`** = quit

✅ **Test:** AGV moves around in Gazebo as you press keys.

---

## 🎉 Stage 2 Done!

You now have:
- ✅ A complete AGV robot in URDF
- ✅ AGV spawns at HOME in the warehouse
- ✅ Manual driving works
- ✅ Odometry publishes on `/agv/odom`
- ✅ Robot is visible in both Gazebo and RViz

### What's Next?

`STAGE_3_Driving.md` — make the AGV follow the line autonomously.

---

## 🆘 Troubleshooting

| Problem | Fix |
|---|---|
| AGV spawns but can't be driven | Topic mismatch. Confirm: `ros2 topic list \| grep cmd_vel`. Should show `/agv/cmd_vel`. |
| AGV falls through floor | The URDF's `z=0.05` spawn height isn't enough. Try `z=0.1`. |
| AGV won't move with teleop | Run `ros2 topic hz /agv/cmd_vel` while pressing keys. Should show ~10Hz. If 0Hz, teleop topic remap is wrong. |
| RViz: "No tf data" | Wait 5 seconds. Or set Fixed Frame to `base_footprint`. |
| `xacro: command not found` | `sudo apt install ros-humble-xacro` |
| `libgazebo_ros_diff_drive.so` not found | `sudo apt install ros-humble-gazebo-ros-pkgs` |
| AGV is huge/tiny | Check URDF — the `<size>` values must be in **meters**. |
| Build error: "package agv_msgs not found" | `--packages-skip agv_msgs` flag missing on the build command |
