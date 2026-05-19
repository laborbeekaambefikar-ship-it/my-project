# 🤖 Stage 2 — The Robot

> **Goal:** Build the robot URDF with correct physics from day 1. The robot must sit perfectly still on spawn — no drift.
>
> **Time:** 20 minutes  •  **Files created:** 1 URDF, 1 RViz config, 1 launch file

---

## 🧠 The Critical Detail

The previous project had a bug where the robot would slide on its own
when spawned. It happened because the wheels were placed 5 mm below the
ground, and Gazebo's physics engine pushed them out, creating a residual
velocity that never stopped (because there was no joint damping).

In this project, the wheel placement is **mathematically exact**:

```
WHEEL_RADIUS = 0.04 m
base_link is at z = WHEEL_RADIUS = 0.04 m above ground
wheel joint origin (relative to base_link) is at z = 0
→ wheel center is at z = 0.04 (above ground)
→ wheel BOTTOM is at z = 0.04 - 0.04 = 0.00 (on ground exactly)
```

We also add **joint damping**, **friction parameters**, and **contact
stiffness** so the robot is rock-solid when no command is given.

---

## 📋 Step 1 — Create the Folder Structure

```bash
mkdir -p ~/wbot_ws/src/wbot_robot/urdf
mkdir -p ~/wbot_ws/src/wbot_robot/launch
mkdir -p ~/wbot_ws/src/wbot_robot/rviz
```

---

## 📋 Step 2 — Write the URDF (with correct physics)

```bash
nano ~/wbot_ws/src/wbot_robot/urdf/wbot.urdf.xacro
```

Paste this complete file:

```xml
<?xml version="1.0"?>
<robot name="wbot" xmlns:xacro="http://www.ros.org/wiki/xacro">

  <!-- ========== MATERIALS ========== -->
  <material name="black">  <color rgba="0.1 0.1 0.1 1"/></material>
  <material name="gray">   <color rgba="0.4 0.4 0.4 1"/></material>
  <material name="orange"> <color rgba="1.0 0.5 0.0 1"/></material>
  <material name="blue">   <color rgba="0.1 0.3 1.0 1"/></material>

  <!-- ========== EXACT-FIT CONSTANTS ========== -->
  <xacro:property name="WHEEL_RADIUS"  value="0.04"/>
  <xacro:property name="WHEEL_LENGTH"  value="0.025"/>
  <xacro:property name="WHEEL_SEP"     value="0.21"/>
  <xacro:property name="CHASSIS_X"     value="0.25"/>
  <xacro:property name="CHASSIS_Y"     value="0.20"/>
  <xacro:property name="CHASSIS_Z"     value="0.08"/>
  <xacro:property name="CASTER_RADIUS" value="0.02"/>

  <!-- ========== BASE FOOTPRINT (origin on the floor) ========== -->
  <link name="base_footprint"/>

  <!-- base_link is exactly WHEEL_RADIUS above ground -->
  <joint name="base_joint" type="fixed">
    <parent link="base_footprint"/>
    <child  link="base_link"/>
    <origin xyz="0 0 ${WHEEL_RADIUS}" rpy="0 0 0"/>
  </joint>

  <!-- ========== CHASSIS (sits ABOVE base_link) ========== -->
  <link name="base_link">
    <visual>
      <origin xyz="0 0 ${CHASSIS_Z/2}" rpy="0 0 0"/>
      <geometry><box size="${CHASSIS_X} ${CHASSIS_Y} ${CHASSIS_Z}"/></geometry>
      <material name="gray"/>
    </visual>
    <collision>
      <origin xyz="0 0 ${CHASSIS_Z/2}" rpy="0 0 0"/>
      <geometry><box size="${CHASSIS_X} ${CHASSIS_Y} ${CHASSIS_Z}"/></geometry>
    </collision>
    <inertial>
      <origin xyz="0 0 ${CHASSIS_Z/2}" rpy="0 0 0"/>
      <mass value="2.5"/>
      <inertia ixx="0.020" ixy="0" ixz="0"
               iyy="0.025" iyz="0" izz="0.030"/>
    </inertial>
  </link>

  <!-- ========== TRAY (cosmetic, on top) ========== -->
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
    <origin xyz="0 0 ${CHASSIS_Z + 0.005}" rpy="0 0 0"/>
  </joint>

  <!-- ========== LEFT WHEEL ========== -->
  <link name="wheel_left">
    <visual>
      <origin xyz="0 0 0" rpy="${pi/2} 0 0"/>
      <geometry>
        <cylinder length="${WHEEL_LENGTH}" radius="${WHEEL_RADIUS}"/>
      </geometry>
      <material name="black"/>
    </visual>
    <collision>
      <origin xyz="0 0 0" rpy="${pi/2} 0 0"/>
      <geometry>
        <cylinder length="${WHEEL_LENGTH}" radius="${WHEEL_RADIUS}"/>
      </geometry>
      <surface>
        <friction>
          <ode>
            <mu>1.0</mu>
            <mu2>0.5</mu2>
            <fdir1>1 0 0</fdir1>
          </ode>
        </friction>
      </surface>
    </collision>
    <inertial>
      <mass value="0.15"/>
      <inertia ixx="1.5e-4" ixy="0" ixz="0"
               iyy="1.5e-4" iyz="0" izz="1.2e-4"/>
    </inertial>
  </link>
  <joint name="joint_left_wheel" type="continuous">
    <parent link="base_link"/>
    <child  link="wheel_left"/>
    <origin xyz="0 ${WHEEL_SEP/2} 0" rpy="0 0 0"/>
    <axis xyz="0 1 0"/>
    <dynamics damping="0.5" friction="0.2"/>
  </joint>

  <!-- ========== RIGHT WHEEL ========== -->
  <link name="wheel_right">
    <visual>
      <origin xyz="0 0 0" rpy="${pi/2} 0 0"/>
      <geometry>
        <cylinder length="${WHEEL_LENGTH}" radius="${WHEEL_RADIUS}"/>
      </geometry>
      <material name="black"/>
    </visual>
    <collision>
      <origin xyz="0 0 0" rpy="${pi/2} 0 0"/>
      <geometry>
        <cylinder length="${WHEEL_LENGTH}" radius="${WHEEL_RADIUS}"/>
      </geometry>
      <surface>
        <friction>
          <ode>
            <mu>1.0</mu>
            <mu2>0.5</mu2>
            <fdir1>1 0 0</fdir1>
          </ode>
        </friction>
      </surface>
    </collision>
    <inertial>
      <mass value="0.15"/>
      <inertia ixx="1.5e-4" ixy="0" ixz="0"
               iyy="1.5e-4" iyz="0" izz="1.2e-4"/>
    </inertial>
  </link>
  <joint name="joint_right_wheel" type="continuous">
    <parent link="base_link"/>
    <child  link="wheel_right"/>
    <origin xyz="0 ${-WHEEL_SEP/2} 0" rpy="0 0 0"/>
    <axis xyz="0 1 0"/>
    <dynamics damping="0.5" friction="0.2"/>
  </joint>

  <!-- ========== CASTER (rear ball, frictionless) ========== -->
  <link name="caster_link">
    <visual>
      <geometry><sphere radius="${CASTER_RADIUS}"/></geometry>
      <material name="black"/>
    </visual>
    <collision>
      <geometry><sphere radius="${CASTER_RADIUS}"/></geometry>
      <surface>
        <friction>
          <ode><mu>0.0</mu><mu2>0.0</mu2></ode>
        </friction>
      </surface>
    </collision>
    <inertial>
      <mass value="0.05"/>
      <inertia ixx="1e-5" ixy="0" ixz="0" iyy="1e-5" iyz="0" izz="1e-5"/>
    </inertial>
  </link>
  <joint name="caster_joint" type="fixed">
    <parent link="base_link"/>
    <child  link="caster_link"/>
    <origin xyz="-0.10 0 ${-(WHEEL_RADIUS - CASTER_RADIUS)}" rpy="0 0 0"/>
  </joint>

  <!-- ========== IMU LINK ========== -->
  <link name="imu_link"/>
  <joint name="imu_joint" type="fixed">
    <parent link="base_link"/>
    <child  link="imu_link"/>
    <origin xyz="0 0 0.01" rpy="0 0 0"/>
  </joint>

  <!-- ========== 8 IR SENSOR LINKS (visual placeholders only) ========== -->
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

  <!-- ========== GAZEBO SURFACE PROPERTIES ========== -->
  <gazebo reference="base_link"><material>Gazebo/Grey</material></gazebo>
  <gazebo reference="tray_link"><material>Gazebo/Orange</material></gazebo>

  <gazebo reference="wheel_left">
    <material>Gazebo/Black</material>
    <mu1>1.0</mu1>
    <mu2>0.5</mu2>
    <kp>1000000.0</kp>
    <kd>10.0</kd>
    <fdir1>1 0 0</fdir1>
  </gazebo>

  <gazebo reference="wheel_right">
    <material>Gazebo/Black</material>
    <mu1>1.0</mu1>
    <mu2>0.5</mu2>
    <kp>1000000.0</kp>
    <kd>10.0</kd>
    <fdir1>1 0 0</fdir1>
  </gazebo>

  <gazebo reference="caster_link">
    <material>Gazebo/Black</material>
    <mu1>0.0</mu1>
    <mu2>0.0</mu2>
    <kp>1000000.0</kp>
    <kd>10.0</kd>
  </gazebo>

  <!-- ========== DIFFERENTIAL DRIVE PLUGIN ========== -->
  <gazebo>
    <plugin name="diff_drive" filename="libgazebo_ros_diff_drive.so">
      <ros>
        <namespace>/wbot</namespace>
      </ros>
      <update_rate>50</update_rate>
      <left_joint>joint_left_wheel</left_joint>
      <right_joint>joint_right_wheel</right_joint>
      <wheel_separation>${WHEEL_SEP}</wheel_separation>
      <wheel_diameter>${WHEEL_RADIUS*2}</wheel_diameter>
      <max_wheel_torque>20.0</max_wheel_torque>
      <max_wheel_acceleration>5.0</max_wheel_acceleration>
      <command_topic>cmd_vel</command_topic>
      <publish_odom>true</publish_odom>
      <publish_odom_tf>true</publish_odom_tf>
      <publish_wheel_tf>false</publish_wheel_tf>
      <odometry_topic>odom</odometry_topic>
      <odometry_frame>odom</odometry_frame>
      <robot_base_frame>base_footprint</robot_base_frame>
    </plugin>
  </gazebo>

  <!-- ========== JOINT STATE PUBLISHER ========== -->
  <gazebo>
    <plugin name="joint_states" filename="libgazebo_ros_joint_state_publisher.so">
      <ros>
        <namespace>/wbot</namespace>
        <remapping>~/out:=joint_states</remapping>
      </ros>
      <update_rate>50</update_rate>
      <joint_name>joint_left_wheel</joint_name>
      <joint_name>joint_right_wheel</joint_name>
    </plugin>
  </gazebo>

  <!-- ========== IMU PLUGIN (with explicit zero noise) ========== -->
  <gazebo reference="imu_link">
    <sensor name="imu" type="imu">
      <update_rate>100</update_rate>
      <always_on>true</always_on>
      <imu>
        <angular_velocity>
          <x><noise type="gaussian"><mean>0.0</mean><stddev>0.0</stddev></noise></x>
          <y><noise type="gaussian"><mean>0.0</mean><stddev>0.0</stddev></noise></y>
          <z><noise type="gaussian"><mean>0.0</mean><stddev>0.0</stddev></noise></z>
        </angular_velocity>
        <linear_acceleration>
          <x><noise type="gaussian"><mean>0.0</mean><stddev>0.0</stddev></noise></x>
          <y><noise type="gaussian"><mean>0.0</mean><stddev>0.0</stddev></noise></y>
          <z><noise type="gaussian"><mean>0.0</mean><stddev>0.0</stddev></noise></z>
        </linear_acceleration>
      </imu>
      <plugin name="imu_plugin" filename="libgazebo_ros_imu_sensor.so">
        <ros>
          <namespace>/wbot</namespace>
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
nano ~/wbot_ws/src/wbot_robot/rviz/view.rviz
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

Save and exit.

---

## 📋 Step 4 — Create the Spawn Launch File

```bash
nano ~/wbot_ws/src/wbot_robot/launch/spawn.launch.py
```

Paste:

```python
#!/usr/bin/env python3
"""spawn.launch.py — Launches Gazebo + warehouse + wbot + RViz."""

import os
from launch import LaunchDescription
from launch.actions import ExecuteProcess
from launch.substitutions import Command
from launch_ros.actions import Node
from ament_index_python.packages import get_package_share_directory


def generate_launch_description():
    pkg_world = get_package_share_directory('wbot_world')
    pkg_robot = get_package_share_directory('wbot_robot')

    world_file = os.path.join(pkg_world, 'worlds', 'warehouse.world')
    urdf_file  = os.path.join(pkg_robot, 'urdf',   'wbot.urdf.xacro')
    rviz_file  = os.path.join(pkg_robot, 'rviz',   'view.rviz')

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

    # CRITICAL: spawn at z=0.01 (just above ground, no fall)
    spawn = Node(
        package='gazebo_ros',
        executable='spawn_entity.py',
        arguments=['-entity', 'wbot',
                   '-topic', 'robot_description',
                   '-x', '-2.0', '-y', '0.0', '-z', '0.01',
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

Save and exit.

---

## 📋 Step 5 — Update `setup.py` for `wbot_robot`

```bash
nano ~/wbot_ws/src/wbot_robot/setup.py
```

Replace the entire file with:

```python
from setuptools import setup
from glob import glob
import os

package_name = 'wbot_robot'

setup(
    name=package_name,
    version='0.1.0',
    packages=[package_name],
    data_files=[
        ('share/ament_index/resource_index/packages',
            ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
        (os.path.join('share', package_name, 'urdf'),
            glob('urdf/*.xacro')),
        (os.path.join('share', package_name, 'launch'),
            glob('launch/*.py')),
        (os.path.join('share', package_name, 'rviz'),
            glob('rviz/*.rviz')),
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    maintainer='you',
    maintainer_email='you@example.com',
    description='wbot robot URDF + spawn',
    license='MIT',
    entry_points={'console_scripts': []},
)
```

---

## 📋 Step 6 — Update `package.xml` for `wbot_robot`

```bash
nano ~/wbot_ws/src/wbot_robot/package.xml
```

Replace the entire file with:

```xml
<?xml version="1.0"?>
<package format="3">
  <name>wbot_robot</name>
  <version>0.1.0</version>
  <description>wbot URDF and spawn launch</description>
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
cd ~/wbot_ws
colcon build --symlink-install
source install/setup.bash
```

Expected: `Summary: 5 packages finished` (we still skip wbot_msgs effectively since it's empty).

If it fails on `wbot_msgs` (empty package), just build the others:
```bash
colcon build --symlink-install --packages-skip wbot_msgs
```

---

## 📋 Step 8 — Launch and Verify

```bash
ros2 launch wbot_robot spawn.launch.py
```

Wait ~15 seconds.

✅ **What you should see:**
- Gazebo opens with the warehouse
- A small **gray robot with an orange tray** appears at the green HOME zone
- 8 tiny **blue boxes** at the front-bottom of the robot (IR placeholders)
- RViz opens showing the robot model + TF frames

**THE ROBOT MUST NOT MOVE.** It should sit perfectly still on the green
HOME pad.

---

## 📋 Step 9 — Verify the Robot Is Stationary

In a NEW terminal:

```bash
source ~/wbot_ws/install/setup.bash
ros2 topic echo /wbot/odom --once
```

Look for the `twist:` section. It should show ALL ZEROS:

```
twist:
  twist:
    linear:
      x: 0.0
      y: 0.0
      z: 0.0
    angular:
      x: 0.0
      y: 0.0
      z: 0.0
```

If `linear.x` or `angular.z` is non-zero, the robot is moving. Re-check
the URDF — the `<dynamics damping>`, `<mu2>`, `<kp>`, and `<kd>` values
must all be present.

---

## 📋 Step 10 — Test Manual Driving

In another new terminal:

```bash
source ~/wbot_ws/install/setup.bash
ros2 run teleop_twist_keyboard teleop_twist_keyboard \
    --ros-args -r cmd_vel:=/wbot/cmd_vel
```

Press:
- **`i`** = forward
- **`,`** = backward
- **`j`** = turn left
- **`l`** = turn right
- **`k`** = stop
- **`Ctrl+C`** = quit

✅ The robot should respond to your key presses. When you stop pressing,
it should slow down and stop within ~1 second (because of the joint
damping).

---

## 🎉 Stage 2 Complete

You now have:
- ✅ Robot URDF with mathematically exact wheel placement
- ✅ Joint damping prevents drift
- ✅ Friction parameters keep wheels gripped to floor
- ✅ Robot spawns and **stays still** at HOME
- ✅ Manual driving works
- ✅ Odometry publishes on `/wbot/odom`
- ✅ IMU publishes on `/wbot/imu` (no noise warnings)

---

## 🆘 Troubleshooting

| Problem | Fix |
|---|---|
| Robot moves on its own when spawned | Check `<dynamics damping="0.5">` is in BOTH wheel joints |
| Robot falls through floor | Check spawn line: `-z 0.01` (not 0.001) |
| Robot bounces a tiny bit then stops | Normal! That's the physics settling. As long as it stops within 1s, fine. |
| `xacro: command not found` | `sudo apt install ros-humble-xacro` |
| `libgazebo_ros_diff_drive.so` not found | `sudo apt install ros-humble-gazebo-ros-pkgs` |
| RViz: "No transform from base_footprint" | Wait 5s. If still fails, restart everything: `pkill -9 -f ros2 && pkill -9 -f gz` |
| `Sensor.cc:510 Get noise index not valid` | This is only an error if you DON'T see the `<imu><angular_velocity>...` block in the URDF. The version above has it. |
| Teleop doesn't move the robot | Wrong topic. Check it's remapping to `/wbot/cmd_vel` not `/cmd_vel` |

---

## ➡️ Next Up

`03_DRIVING.md` — Add optical sensors + line follower + turn + pivot. The
robot will start driving along the line autonomously.
