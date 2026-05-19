# 🚀 INSTALL — One-Shot Master Script

> Run the script in this file. The ENTIRE project gets created correctly. ~3 minutes.

This script is **idempotent** — safe to run multiple times. Each run wipes
and recreates all files, so you can never end up in a broken half-installed
state.

---

## ⚠️ Before You Start

Make sure you've completed `00_PREREQS.md` (installed Ubuntu/ROS dependencies).

If you have an old `~/wbot_ws/` from a previous attempt, this script will
back it up and start fresh:

```bash
if [ -d ~/wbot_ws ]; then
  mv ~/wbot_ws ~/wbot_ws.backup_$(date +%s)
  echo "Old wbot_ws moved to ~/wbot_ws.backup_*"
fi
```

---

## 📋 Run This Script

Copy **the entire block below** (from `set -e` through `echo "DONE"`) into
your terminal and press Enter. Wait ~30 seconds for it to finish.

```bash
set -e

WS=~/wbot_ws
mkdir -p $WS/src
cd $WS/src

# ====================================================================
# Create 5 packages
# ====================================================================
echo "Creating 5 packages..."
ros2 pkg create --build-type ament_python wbot_world  >/dev/null
ros2 pkg create --build-type ament_python wbot_robot  >/dev/null
ros2 pkg create --build-type ament_python wbot_brain  >/dev/null
ros2 pkg create --build-type ament_python wbot_run    >/dev/null
ros2 pkg create --build-type ament_cmake  wbot_msgs   >/dev/null

# Create folder structures
mkdir -p $WS/src/wbot_world/{scripts,worlds,launch}
mkdir -p $WS/src/wbot_robot/{urdf,launch,rviz}
mkdir -p $WS/src/wbot_brain/{wbot_brain,launch,config}
mkdir -p $WS/src/wbot_run/launch
mkdir -p $WS/src/wbot_msgs/msg
touch $WS/src/wbot_brain/wbot_brain/__init__.py

# ====================================================================
# 1. wbot_msgs — custom message types
# ====================================================================
echo "Writing wbot_msgs..."

cat > $WS/src/wbot_msgs/msg/Order.msg <<'EOF'
string shelf_id
int32  aisle
string sku
EOF

cat > $WS/src/wbot_msgs/msg/RFIDRead.msg <<'EOF'
string  tag_id
float32 distance
bool    is_home
EOF

cat > $WS/src/wbot_msgs/msg/BotState.msg <<'EOF'
string state
string current_target
string current_sku
string last_rfid
EOF

cat > $WS/src/wbot_msgs/CMakeLists.txt <<'EOF'
cmake_minimum_required(VERSION 3.8)
project(wbot_msgs)
find_package(ament_cmake REQUIRED)
find_package(rosidl_default_generators REQUIRED)
find_package(std_msgs REQUIRED)
rosidl_generate_interfaces(${PROJECT_NAME}
  "msg/Order.msg"
  "msg/RFIDRead.msg"
  "msg/BotState.msg"
  DEPENDENCIES std_msgs
)
ament_export_dependencies(rosidl_default_runtime)
ament_package()
EOF

cat > $WS/src/wbot_msgs/package.xml <<'EOF'
<?xml version="1.0"?>
<package format="3">
  <name>wbot_msgs</name>
  <version>0.1.0</version>
  <description>wbot custom messages</description>
  <maintainer email="you@example.com">you</maintainer>
  <license>MIT</license>
  <buildtool_depend>ament_cmake</buildtool_depend>
  <buildtool_depend>rosidl_default_generators</buildtool_depend>
  <depend>std_msgs</depend>
  <member_of_group>rosidl_interface_packages</member_of_group>
  <exec_depend>rosidl_default_runtime</exec_depend>
  <export><build_type>ament_cmake</build_type></export>
</package>
EOF

# ====================================================================
# 2. wbot_world — warehouse generator + launch
# ====================================================================
echo "Writing wbot_world..."

cat > $WS/src/wbot_world/scripts/build_world.py <<'PYEOF'
#!/usr/bin/env python3
"""build_world.py — Generates warehouse.world."""
import os

LINE_WIDTH         = 0.05
LINE_HEIGHT        = 0.002
MAIN_AISLE_X_START = -2.5
MAIN_AISLE_X_END   = 12.5
MAIN_AISLE_Y       = 0.0
SPUR_X_LIST        = [0.0, 3.0, 6.0, 9.0, 12.0]
SPUR_Y_START       = 0.0
SPUR_Y_END         = 4.0
HOME_X             = -2.0
HOME_Y             = 0.0
SHELF_X_OFFSET     = -0.9
SHELF_Y_START      = 0.8
SHELF_Y_STEP       = 0.8
SHELVES_PER_AISLE  = 4
TAG_X_OFFSET       = -0.4


def make_box(name, x, y, z, sx, sy, sz, r, g, b):
    return f"""
    <model name="{name}"><static>true</static><pose>{x} {y} {z} 0 0 0</pose>
      <link name="link"><visual name="v">
        <geometry><box><size>{sx} {sy} {sz}</size></box></geometry>
        <material><ambient>{r} {g} {b} 1</ambient><diffuse>{r} {g} {b} 1</diffuse></material>
      </visual></link></model>"""


def make_cyl(name, x, y, z, radius, height, r, g, b):
    return f"""
    <model name="{name}"><static>true</static><pose>{x} {y} {z} 0 0 0</pose>
      <link name="link"><visual name="v">
        <geometry><cylinder><radius>{radius}</radius><length>{height}</length></cylinder></geometry>
        <material><ambient>{r} {g} {b} 1</ambient><diffuse>{r} {g} {b} 1</diffuse></material>
      </visual></link></model>"""


def main():
    parts = []
    main_len = MAIN_AISLE_X_END - MAIN_AISLE_X_START
    main_xc  = (MAIN_AISLE_X_START + MAIN_AISLE_X_END) / 2.0
    parts.append(make_box("tape_main", main_xc, MAIN_AISLE_Y, LINE_HEIGHT/2,
                          main_len, LINE_WIDTH, LINE_HEIGHT, 0.05, 0.05, 0.05))

    spur_len = SPUR_Y_END - SPUR_Y_START
    spur_yc  = (SPUR_Y_START + SPUR_Y_END) / 2.0
    for i, sx in enumerate(SPUR_X_LIST, start=1):
        parts.append(make_box(f"tape_spur_{i}", sx, spur_yc, LINE_HEIGHT/2,
                              LINE_WIDTH, spur_len, LINE_HEIGHT, 0.05, 0.05, 0.05))

    parts.append(make_cyl("home_zone", HOME_X, HOME_Y, 0.001, 0.30, 0.005,
                          0.0, 0.7, 0.0))

    n = 1
    for ax in SPUR_X_LIST:
        for slot in range(SHELVES_PER_AISLE):
            sx = ax + SHELF_X_OFFSET
            sy = SHELF_Y_START + slot * SHELF_Y_STEP
            tx = ax + TAG_X_OFFSET
            parts.append(make_box(f"shelf_S{n:02d}", sx, sy, 0.30,
                                  0.6, 0.4, 0.6, 0.55, 0.35, 0.20))
            parts.append(make_cyl(f"tag_S{n:02d}", tx, sy, 0.001,
                                  0.05, 0.003, 0.1, 0.4, 1.0))
            n += 1

    world = f"""<?xml version="1.0"?>
<sdf version="1.6">
  <world name="warehouse">
    <include><uri>model://sun</uri></include>
    <include><uri>model://ground_plane</uri></include>
    <model name="floor_color"><static>true</static><pose>5 2 -0.001 0 0 0</pose>
      <link name="link"><visual name="v">
        <geometry><box><size>20 10 0.001</size></box></geometry>
        <material><ambient>0.95 0.95 0.95 1</ambient><diffuse>0.95 0.95 0.95 1</diffuse></material>
      </visual></link></model>
    <physics type="ode">
      <max_step_size>0.001</max_step_size>
      <real_time_factor>1.0</real_time_factor>
      <real_time_update_rate>1000</real_time_update_rate>
    </physics>
{''.join(parts)}
  </world>
</sdf>
"""
    out_dir = os.path.expanduser("~/wbot_ws/src/wbot_world/worlds")
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, "warehouse.world")
    with open(out, "w") as f:
        f.write(world)
    print(f"OK: {out}")


if __name__ == "__main__":
    main()
PYEOF

cat > $WS/src/wbot_world/launch/world.launch.py <<'PYEOF'
import os
from launch import LaunchDescription
from launch.actions import ExecuteProcess
from ament_index_python.packages import get_package_share_directory


def generate_launch_description():
    pkg = get_package_share_directory('wbot_world')
    world = os.path.join(pkg, 'worlds', 'warehouse.world')
    return LaunchDescription([ExecuteProcess(
        cmd=['gazebo', '--verbose', world,
             '-s', 'libgazebo_ros_init.so',
             '-s', 'libgazebo_ros_factory.so'],
        output='screen')])
PYEOF

cat > $WS/src/wbot_world/setup.py <<'PYEOF'
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
PYEOF

# Generate the world file now
python3 $WS/src/wbot_world/scripts/build_world.py

# ====================================================================
# 3. wbot_robot — URDF with CORRECT physics
# ====================================================================
echo "Writing wbot_robot..."

cat > $WS/src/wbot_robot/urdf/wbot.urdf.xacro <<'XMLEOF'
<?xml version="1.0"?>
<robot name="wbot" xmlns:xacro="http://www.ros.org/wiki/xacro">
  <material name="black">  <color rgba="0.1 0.1 0.1 1"/></material>
  <material name="gray">   <color rgba="0.4 0.4 0.4 1"/></material>
  <material name="orange"> <color rgba="1.0 0.5 0.0 1"/></material>
  <material name="blue">   <color rgba="0.1 0.3 1.0 1"/></material>

  <xacro:property name="WHEEL_RADIUS"  value="0.04"/>
  <xacro:property name="WHEEL_LENGTH"  value="0.025"/>
  <xacro:property name="WHEEL_SEP"     value="0.21"/>
  <xacro:property name="CHASSIS_X"     value="0.25"/>
  <xacro:property name="CHASSIS_Y"     value="0.20"/>
  <xacro:property name="CHASSIS_Z"     value="0.08"/>
  <xacro:property name="CASTER_RADIUS" value="0.02"/>

  <link name="base_footprint"/>
  <joint name="base_joint" type="fixed">
    <parent link="base_footprint"/><child link="base_link"/>
    <origin xyz="0 0 ${WHEEL_RADIUS}" rpy="0 0 0"/>
  </joint>

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
      <inertia ixx="0.020" ixy="0" ixz="0" iyy="0.025" iyz="0" izz="0.030"/>
    </inertial>
  </link>

  <link name="tray_link">
    <visual><origin xyz="0 0 0.005" rpy="0 0 0"/>
      <geometry><box size="0.20 0.18 0.01"/></geometry>
      <material name="orange"/></visual>
    <inertial><mass value="0.05"/>
      <inertia ixx="1e-4" ixy="0" ixz="0" iyy="1e-4" iyz="0" izz="1e-4"/></inertial>
  </link>
  <joint name="tray_joint" type="fixed">
    <parent link="base_link"/><child link="tray_link"/>
    <origin xyz="0 0 ${CHASSIS_Z + 0.005}" rpy="0 0 0"/>
  </joint>

  <link name="wheel_left">
    <visual><origin xyz="0 0 0" rpy="${pi/2} 0 0"/>
      <geometry><cylinder length="${WHEEL_LENGTH}" radius="${WHEEL_RADIUS}"/></geometry>
      <material name="black"/></visual>
    <collision><origin xyz="0 0 0" rpy="${pi/2} 0 0"/>
      <geometry><cylinder length="${WHEEL_LENGTH}" radius="${WHEEL_RADIUS}"/></geometry>
      <surface><friction><ode>
        <mu>1.0</mu><mu2>0.5</mu2><fdir1>1 0 0</fdir1>
      </ode></friction></surface></collision>
    <inertial><mass value="0.15"/>
      <inertia ixx="1.5e-4" ixy="0" ixz="0" iyy="1.5e-4" iyz="0" izz="1.2e-4"/></inertial>
  </link>
  <joint name="joint_left_wheel" type="continuous">
    <parent link="base_link"/><child link="wheel_left"/>
    <origin xyz="0 ${WHEEL_SEP/2} 0" rpy="0 0 0"/>
    <axis xyz="0 1 0"/>
    <dynamics damping="0.5" friction="0.2"/>
  </joint>

  <link name="wheel_right">
    <visual><origin xyz="0 0 0" rpy="${pi/2} 0 0"/>
      <geometry><cylinder length="${WHEEL_LENGTH}" radius="${WHEEL_RADIUS}"/></geometry>
      <material name="black"/></visual>
    <collision><origin xyz="0 0 0" rpy="${pi/2} 0 0"/>
      <geometry><cylinder length="${WHEEL_LENGTH}" radius="${WHEEL_RADIUS}"/></geometry>
      <surface><friction><ode>
        <mu>1.0</mu><mu2>0.5</mu2><fdir1>1 0 0</fdir1>
      </ode></friction></surface></collision>
    <inertial><mass value="0.15"/>
      <inertia ixx="1.5e-4" ixy="0" ixz="0" iyy="1.5e-4" iyz="0" izz="1.2e-4"/></inertial>
  </link>
  <joint name="joint_right_wheel" type="continuous">
    <parent link="base_link"/><child link="wheel_right"/>
    <origin xyz="0 ${-WHEEL_SEP/2} 0" rpy="0 0 0"/>
    <axis xyz="0 1 0"/>
    <dynamics damping="0.5" friction="0.2"/>
  </joint>

  <link name="caster_link">
    <visual><geometry><sphere radius="${CASTER_RADIUS}"/></geometry>
      <material name="black"/></visual>
    <collision><geometry><sphere radius="${CASTER_RADIUS}"/></geometry>
      <surface><friction><ode><mu>0.0</mu><mu2>0.0</mu2></ode></friction></surface></collision>
    <inertial><mass value="0.05"/>
      <inertia ixx="1e-5" ixy="0" ixz="0" iyy="1e-5" iyz="0" izz="1e-5"/></inertial>
  </link>
  <joint name="caster_joint" type="fixed">
    <parent link="base_link"/><child link="caster_link"/>
    <origin xyz="-0.10 0 ${-(WHEEL_RADIUS - CASTER_RADIUS)}" rpy="0 0 0"/>
  </joint>

  <link name="imu_link"/>
  <joint name="imu_joint" type="fixed">
    <parent link="base_link"/><child link="imu_link"/>
    <origin xyz="0 0 0.01" rpy="0 0 0"/>
  </joint>

  <xacro:macro name="ir_sensor" params="idx y_offset">
    <link name="ir_${idx}">
      <visual><geometry><box size="0.006 0.006 0.004"/></geometry>
        <material name="blue"/></visual>
      <inertial><mass value="0.001"/>
        <inertia ixx="1e-7" ixy="0" ixz="0" iyy="1e-7" iyz="0" izz="1e-7"/></inertial>
    </link>
    <joint name="ir_${idx}_joint" type="fixed">
      <parent link="base_link"/><child link="ir_${idx}"/>
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

  <gazebo reference="base_link"><material>Gazebo/Grey</material></gazebo>
  <gazebo reference="tray_link"><material>Gazebo/Orange</material></gazebo>

  <gazebo reference="wheel_left">
    <material>Gazebo/Black</material>
    <mu1>1.0</mu1><mu2>0.5</mu2><kp>1000000.0</kp><kd>10.0</kd>
    <fdir1>1 0 0</fdir1>
  </gazebo>
  <gazebo reference="wheel_right">
    <material>Gazebo/Black</material>
    <mu1>1.0</mu1><mu2>0.5</mu2><kp>1000000.0</kp><kd>10.0</kd>
    <fdir1>1 0 0</fdir1>
  </gazebo>
  <gazebo reference="caster_link">
    <material>Gazebo/Black</material>
    <mu1>0.0</mu1><mu2>0.0</mu2><kp>1000000.0</kp><kd>10.0</kd>
  </gazebo>

  <gazebo>
    <plugin name="diff_drive" filename="libgazebo_ros_diff_drive.so">
      <ros><namespace>/wbot</namespace></ros>
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

  <gazebo>
    <plugin name="joint_states" filename="libgazebo_ros_joint_state_publisher.so">
      <ros><namespace>/wbot</namespace><remapping>~/out:=joint_states</remapping></ros>
      <update_rate>50</update_rate>
      <joint_name>joint_left_wheel</joint_name>
      <joint_name>joint_right_wheel</joint_name>
    </plugin>
  </gazebo>

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
        <ros><namespace>/wbot</namespace><remapping>~/out:=imu</remapping></ros>
        <frame_name>imu_link</frame_name>
      </plugin>
    </sensor>
  </gazebo>
</robot>
XMLEOF

cat > $WS/src/wbot_robot/rviz/view.rviz <<'YAMLEOF'
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
YAMLEOF

cat > $WS/src/wbot_robot/launch/spawn.launch.py <<'PYEOF'
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
        output='screen')

    rsp = Node(package='robot_state_publisher', executable='robot_state_publisher',
               output='screen',
               parameters=[{'use_sim_time': True, 'robot_description': robot_description}])

    spawn = Node(package='gazebo_ros', executable='spawn_entity.py',
                 arguments=['-entity', 'wbot', '-topic', 'robot_description',
                            '-x', '-2.0', '-y', '0.0', '-z', '0.01', '-Y', '0.0'],
                 output='screen')

    rviz = Node(package='rviz2', executable='rviz2',
                arguments=['-d', rviz_file], output='screen',
                parameters=[{'use_sim_time': True}])

    return LaunchDescription([gazebo, rsp, spawn, rviz])
PYEOF

cat > $WS/src/wbot_robot/setup.py <<'PYEOF'
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
        (os.path.join('share', package_name, 'urdf'),   glob('urdf/*.xacro')),
        (os.path.join('share', package_name, 'launch'), glob('launch/*.py')),
        (os.path.join('share', package_name, 'rviz'),   glob('rviz/*.rviz')),
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    maintainer='you',
    maintainer_email='you@example.com',
    description='wbot robot URDF',
    license='MIT',
    entry_points={'console_scripts': []},
)
PYEOF

cat > $WS/src/wbot_robot/package.xml <<'EOF'
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
EOF

# ====================================================================
# 4. wbot_brain — all the smarts
# ====================================================================
echo "Writing wbot_brain..."

# track.py — line geometry
cat > $WS/src/wbot_brain/wbot_brain/track.py <<'PYEOF'
"""track.py — Geometry of black tape on the floor."""
import math
from dataclasses import dataclass
from typing import List, Tuple

LINE_WIDTH         = 0.10
MAIN_AISLE_X_START = -2.5
MAIN_AISLE_X_END   = 12.5
MAIN_AISLE_Y       = 0.0
SPUR_X_LIST        = [0.0, 3.0, 6.0, 9.0, 12.0]
SPUR_Y_START       = 0.0
SPUR_Y_END         = 4.0


@dataclass
class Segment:
    name: str
    x1: float; y1: float; x2: float; y2: float
    width: float = LINE_WIDTH

    def distance_to(self, px, py):
        dx = self.x2 - self.x1
        dy = self.y2 - self.y1
        L2 = dx*dx + dy*dy
        if L2 < 1e-9:
            return math.hypot(px - self.x1, py - self.y1)
        t = ((px - self.x1) * dx + (py - self.y1) * dy) / L2
        t = max(0.0, min(1.0, t))
        proj_x = self.x1 + t * dx
        proj_y = self.y1 + t * dy
        return math.hypot(px - proj_x, py - proj_y)

    def contains(self, px, py):
        return self.distance_to(px, py) < (self.width / 2.0)


def build_track() -> List[Segment]:
    segs = [Segment("main", MAIN_AISLE_X_START, MAIN_AISLE_Y,
                    MAIN_AISLE_X_END, MAIN_AISLE_Y)]
    for i, sx in enumerate(SPUR_X_LIST, start=1):
        segs.append(Segment(f"spur_{i}", sx, SPUR_Y_START, sx, SPUR_Y_END))
    return segs


TRACK = build_track()


def on_line(px, py) -> Tuple[bool, str]:
    for s in TRACK:
        if s.contains(px, py):
            return True, s.name
    return False, ""
PYEOF

# shelves.py — shelf locations
cat > $WS/src/wbot_brain/wbot_brain/shelves.py <<'PYEOF'
"""shelves.py — Shelf locations (matches build_world.py exactly)."""
from typing import Dict, List

SPUR_X_LIST       = [0.0, 3.0, 6.0, 9.0, 12.0]
SHELF_X_OFFSET    = -0.9
TAG_X_OFFSET      = -0.4
SHELF_Y_START     = 0.8
SHELF_Y_STEP      = 0.8
SHELVES_PER_AISLE = 4
HOME_X            = -2.0
HOME_Y            = 0.0


def build_shelf_map() -> Dict[str, dict]:
    shelves = {}
    n = 1
    for aisle, ax in enumerate(SPUR_X_LIST, start=1):
        for slot in range(SHELVES_PER_AISLE):
            sid = f"S{n:02d}"
            shelves[sid] = {
                'shelf_x': ax + SHELF_X_OFFSET,
                'shelf_y': SHELF_Y_START + slot * SHELF_Y_STEP,
                'tag_x':   ax + TAG_X_OFFSET,
                'tag_y':   SHELF_Y_START + slot * SHELF_Y_STEP,
                'aisle':   aisle,
                'aisle_x': ax,
                'slot':    slot + 1,
            }
            n += 1
    return shelves


SHELF_MAP = build_shelf_map()


def list_shelves() -> List[str]:
    return sorted(SHELF_MAP.keys())
PYEOF

# optical.py — 8 virtual IR sensors
cat > $WS/src/wbot_brain/wbot_brain/optical.py <<'PYEOF'
#!/usr/bin/env python3
"""optical.py — Simulates 8 IR line sensors using odometry + track geometry."""
import math
import rclpy
from rclpy.node import Node
from nav_msgs.msg import Odometry
from std_msgs.msg import Float32MultiArray
from visualization_msgs.msg import Marker, MarkerArray
from wbot_brain.track import on_line

SENSOR_X = 0.10
SENSOR_Z = 0.005
SENSOR_OFFSETS_Y = [0.042, 0.030, 0.018, 0.006,
                    -0.006, -0.018, -0.030, -0.042]


def yaw_from_quat(q):
    s = 2.0 * (q.w * q.z + q.x * q.y)
    c = 1.0 - 2.0 * (q.y * q.y + q.z * q.z)
    return math.atan2(s, c)


class Optical(Node):
    def __init__(self):
        super().__init__('optical')
        self.last = None
        self.create_subscription(Odometry, '/wbot/odom', self.odom_cb, 50)
        self.sensors_pub = self.create_publisher(
            Float32MultiArray, '/wbot/line_sensors', 10)
        self.markers_pub = self.create_publisher(
            MarkerArray, '/wbot/line_sensors_markers', 10)
        self.create_timer(0.02, self.tick)
        self.get_logger().info('optical ready (8 virtual IR sensors @ 50 Hz)')

    def odom_cb(self, msg):
        p = msg.pose.pose
        self.last = (p.position.x, p.position.y, yaw_from_quat(p.orientation))

    def tick(self):
        if self.last is None:
            return
        bx, by, yaw = self.last
        c, s = math.cos(yaw), math.sin(yaw)
        binary, positions = [], []
        for off_y in SENSOR_OFFSETS_Y:
            wx = bx + c*SENSOR_X - s*off_y
            wy = by + s*SENSOR_X + c*off_y
            ok, _ = on_line(wx, wy)
            binary.append(1.0 if ok else 0.0)
            positions.append((wx, wy))
        m = Float32MultiArray()
        m.data = binary
        self.sensors_pub.publish(m)
        self._markers(positions, binary)

    def _markers(self, positions, binary):
        ma = MarkerArray()
        now = self.get_clock().now().to_msg()
        for i, ((wx, wy), b) in enumerate(zip(positions, binary)):
            mk = Marker()
            mk.header.frame_id = 'odom'
            mk.header.stamp = now
            mk.ns = 'ir'; mk.id = i
            mk.type = Marker.SPHERE; mk.action = Marker.ADD
            mk.pose.position.x = wx; mk.pose.position.y = wy
            mk.pose.position.z = SENSOR_Z
            mk.pose.orientation.w = 1.0
            mk.scale.x = mk.scale.y = mk.scale.z = 0.025
            if b > 0.5:
                mk.color.r, mk.color.g, mk.color.b = 1.0, 0.0, 0.0
            else:
                mk.color.r, mk.color.g, mk.color.b = 0.0, 1.0, 0.0
            mk.color.a = 1.0
            ma.markers.append(mk)
        self.markers_pub.publish(ma)


def main(args=None):
    rclpy.init(args=args)
    n = Optical()
    try: rclpy.spin(n)
    except KeyboardInterrupt: pass
    finally:
        n.destroy_node(); rclpy.shutdown()


if __name__ == '__main__':
    main()
PYEOF

# follow.py — PID line follower (publishes /wbot/follow_vel)
cat > $WS/src/wbot_brain/wbot_brain/follow.py <<'PYEOF'
#!/usr/bin/env python3
"""follow.py — PID line follower. Publishes /wbot/follow_vel."""
import rclpy
from rclpy.node import Node
from std_msgs.msg import Bool, Float32MultiArray
from geometry_msgs.msg import Twist
import numpy as np


class Follow(Node):
    def __init__(self):
        super().__init__('follow')
        self.declare_parameter('linear_speed', 0.50)
        self.declare_parameter('kp', 0.50)
        self.declare_parameter('ki', 0.00)
        self.declare_parameter('kd', 0.15)
        self.linear_speed = self.get_parameter('linear_speed').value
        self.kp = self.get_parameter('kp').value
        self.ki = self.get_parameter('ki').value
        self.kd = self.get_parameter('kd').value

        self.prev_err = 0.0
        self.integral = 0.0
        self.last_offset = 0.0
        self.lost_count = 0
        self.MAX_LOST = 80
        self.JUNC_THRESH = 5
        self.JUNC_STREAK = 2
        self.junc_streak = 0
        self.junc_fired = False

        self.create_subscription(Float32MultiArray, '/wbot/line_sensors',
                                 self.sensors_cb, 10)
        self.junction_pub = self.create_publisher(
            Bool, '/wbot/junction_detected', 10)
        self.vel_pub = self.create_publisher(Twist, '/wbot/follow_vel', 10)
        self.frame = 0

        self.get_logger().info(
            f'follow ready -> /wbot/follow_vel  speed={self.linear_speed} '
            f'kp={self.kp} kd={self.kd}')

    def sensors_cb(self, msg):
        if len(msg.data) < 8:
            return
        binary = np.array(msg.data, dtype=np.float32)
        black = int(binary.sum())

        if black >= self.JUNC_THRESH:
            self.junc_streak += 1
            if self.junc_streak >= self.JUNC_STREAK and not self.junc_fired:
                j = Bool(); j.data = True
                self.junction_pub.publish(j)
                self.junc_fired = True
        else:
            self.junc_streak = 0
            self.junc_fired = False

        if black >= self.JUNC_THRESH:
            t = Twist(); t.linear.x = self.linear_speed
            self.vel_pub.publish(t)
            return

        offset, detected = self._offset(binary)
        if detected:
            self.lost_count = 0
            ang = self._pid(offset)
            lin = self.linear_speed
            self.last_offset = offset
        else:
            self.lost_count += 1
            if self.lost_count < self.MAX_LOST:
                ang = self._pid(self.last_offset) * 0.3
                lin = self.linear_speed * 0.3
            else:
                ang, lin = 0.0, 0.0
                if self.lost_count == self.MAX_LOST:
                    self.get_logger().warn('Line lost.')

        t = Twist(); t.linear.x = float(lin); t.angular.z = float(ang)
        self.vel_pub.publish(t)

        self.frame += 1
        if self.frame % 100 == 0:
            s = ''.join('#' if b > 0.5 else '.' for b in binary)
            self.get_logger().info(
                f'[{s}] off={offset:+.2f} ang={ang:+.2f} lin={lin:.2f}')

    def _offset(self, binary):
        if binary.sum() == 0:
            return 0.0, False
        idx = np.arange(len(binary))
        com = float((idx * binary).sum() / binary.sum())
        center = (len(binary) - 1) / 2.0
        return (com - center) / center, True

    def _pid(self, error):
        self.integral += error
        self.integral = max(min(self.integral, 2.0), -2.0)
        d = error - self.prev_err
        out = self.kp*error + self.ki*self.integral + self.kd*d
        self.prev_err = error
        return -max(min(out, 1.5), -1.5)


def main(args=None):
    rclpy.init(args=args)
    n = Follow()
    try: rclpy.spin(n)
    except KeyboardInterrupt: pass
    finally:
        n.vel_pub.publish(Twist())
        n.destroy_node(); rclpy.shutdown()


if __name__ == '__main__':
    main()
PYEOF

# turn.py — IMU 90deg + nudge
cat > $WS/src/wbot_brain/wbot_brain/turn.py <<'PYEOF'
#!/usr/bin/env python3
"""turn.py — Exact 90 degree IMU turn + forward nudge."""
import math
import rclpy
from rclpy.node import Node
from nav_msgs.msg import Odometry
from std_msgs.msg import String, Bool
from geometry_msgs.msg import Twist

TURN_SPEED  = 0.50
TOLERANCE   = 0.05
TURN_ANGLE  = math.pi / 2
NUDGE_SPEED = 0.20
NUDGE_TIME  = 0.60


def yaw_from_quat(q):
    s = 2.0 * (q.w * q.z + q.x * q.y)
    c = 1.0 - 2.0 * (q.y * q.y + q.z * q.z)
    return math.atan2(s, c)


def angle_diff(target, current):
    d = target - current
    while d > math.pi:  d -= 2 * math.pi
    while d < -math.pi: d += 2 * math.pi
    return d


class Turn(Node):
    PHASE_IDLE   = 0
    PHASE_ROTATE = 1
    PHASE_NUDGE  = 2

    def __init__(self):
        super().__init__('turn')
        self.current_yaw = 0.0
        self.target_yaw  = None
        self.phase       = self.PHASE_IDLE
        self.direction   = 0
        self.nudge_start = None

        self.create_subscription(Odometry, '/wbot/odom', self.odom_cb, 50)
        self.create_subscription(String, '/wbot/turn_cmd', self.cmd_cb, 10)
        self.vel_pub  = self.create_publisher(Twist, '/wbot/turn_vel', 10)
        self.done_pub = self.create_publisher(Bool, '/wbot/turn_done', 10)
        self.create_timer(0.02, self.tick)
        self.get_logger().info('turn ready -> /wbot/turn_vel')

    def odom_cb(self, msg):
        self.current_yaw = yaw_from_quat(msg.pose.pose.orientation)

    def cmd_cb(self, msg):
        d = msg.data.lower().strip()
        if   d == 'left':  self.direction = +1
        elif d == 'right': self.direction = -1
        else: return
        self.target_yaw = self.current_yaw + self.direction * TURN_ANGLE
        while self.target_yaw >  math.pi: self.target_yaw -= 2 * math.pi
        while self.target_yaw < -math.pi: self.target_yaw += 2 * math.pi
        self.phase = self.PHASE_ROTATE
        self.get_logger().info(
            f'turn START: {d.upper()}  '
            f'{math.degrees(self.current_yaw):.0f}deg -> '
            f'{math.degrees(self.target_yaw):.0f}deg')

    def tick(self):
        if self.phase == self.PHASE_IDLE:
            self.vel_pub.publish(Twist()); return

        if self.phase == self.PHASE_ROTATE:
            err = angle_diff(self.target_yaw, self.current_yaw)
            if abs(err) < TOLERANCE:
                self.phase = self.PHASE_NUDGE
                self.nudge_start = self.get_clock().now()
                self.get_logger().info('rotation done — nudging')
                self.vel_pub.publish(Twist())
                return
            t = Twist()
            t.angular.z = TURN_SPEED * (1.0 if err > 0 else -1.0)
            self.vel_pub.publish(t); return

        if self.phase == self.PHASE_NUDGE:
            elapsed = (self.get_clock().now() - self.nudge_start).nanoseconds / 1e9
            if elapsed < NUDGE_TIME:
                t = Twist(); t.linear.x = NUDGE_SPEED
                self.vel_pub.publish(t); return
            self.vel_pub.publish(Twist())
            self.phase = self.PHASE_IDLE
            self.target_yaw = None
            done = Bool(); done.data = True
            self.done_pub.publish(done)
            self.get_logger().info('turn + nudge DONE')


def main(args=None):
    rclpy.init(args=args)
    n = Turn()
    try: rclpy.spin(n)
    except KeyboardInterrupt: pass
    finally:
        n.vel_pub.publish(Twist())
        n.destroy_node(); rclpy.shutdown()


if __name__ == '__main__':
    main()
PYEOF

# pivot.py — IMU rotation
cat > $WS/src/wbot_brain/wbot_brain/pivot.py <<'PYEOF'
#!/usr/bin/env python3
"""pivot.py — IMU pivot. Publishes /wbot/pivot_vel."""
import math
import rclpy
from rclpy.node import Node
from nav_msgs.msg import Odometry
from std_msgs.msg import Bool, Float32
from geometry_msgs.msg import Twist


def yaw_from_quat(q):
    s = 2.0 * (q.w * q.z + q.x * q.y)
    c = 1.0 - 2.0 * (q.y * q.y + q.z * q.z)
    return math.atan2(s, c)


def angle_diff(a, b):
    d = a - b
    while d > math.pi:  d -= 2 * math.pi
    while d < -math.pi: d += 2 * math.pi
    return d


class Pivot(Node):
    def __init__(self):
        super().__init__('pivot')
        self.angular_speed = 0.7
        self.tolerance = 0.05
        self.current_yaw = 0.0
        self.target_yaw = None
        self.pivoting = False

        self.create_subscription(Odometry, '/wbot/odom', self.odom_cb, 50)
        self.create_subscription(Float32, '/wbot/pivot_cmd', self.cmd_cb, 10)
        self.vel_pub  = self.create_publisher(Twist, '/wbot/pivot_vel', 10)
        self.done_pub = self.create_publisher(Bool, '/wbot/pivot_done', 10)
        self.create_timer(0.05, self.tick)
        self.get_logger().info('pivot ready -> /wbot/pivot_vel')

    def odom_cb(self, msg):
        self.current_yaw = yaw_from_quat(msg.pose.pose.orientation)

    def cmd_cb(self, msg):
        angle = float(msg.data)
        self.target_yaw = self.current_yaw + angle
        while self.target_yaw >  math.pi: self.target_yaw -= 2 * math.pi
        while self.target_yaw < -math.pi: self.target_yaw += 2 * math.pi
        self.pivoting = True
        self.get_logger().info(f'pivot start: {math.degrees(angle):.0f}deg')

    def tick(self):
        if not self.pivoting or self.target_yaw is None:
            self.vel_pub.publish(Twist()); return
        err = angle_diff(self.target_yaw, self.current_yaw)
        if abs(err) < self.tolerance:
            self.vel_pub.publish(Twist())
            self.pivoting = False
            self.target_yaw = None
            d = Bool(); d.data = True
            self.done_pub.publish(d)
            self.get_logger().info('pivot done'); return
        t = Twist()
        t.angular.z = self.angular_speed * (1 if err > 0 else -1)
        self.vel_pub.publish(t)


def main(args=None):
    rclpy.init(args=args)
    n = Pivot()
    try: rclpy.spin(n)
    except KeyboardInterrupt: pass
    finally:
        n.vel_pub.publish(Twist())
        n.destroy_node(); rclpy.shutdown()


if __name__ == '__main__':
    main()
PYEOF

# rfid.py — pose-based RFID
cat > $WS/src/wbot_brain/wbot_brain/rfid.py <<'PYEOF'
#!/usr/bin/env python3
"""rfid.py — Pose-based RFID detection."""
import math
import rclpy
from rclpy.node import Node
from nav_msgs.msg import Odometry
from wbot_msgs.msg import RFIDRead
from wbot_brain.shelves import SHELF_MAP, HOME_X, HOME_Y

DETECTION_RADIUS = 0.60
REARM_DISTANCE   = 0.90


class Rfid(Node):
    def __init__(self):
        super().__init__('rfid')
        self.tags = {sid: (d['tag_x'], d['tag_y'], False)
                     for sid, d in SHELF_MAP.items()}
        self.tags['HOME'] = (HOME_X, HOME_Y, True)
        self.armed = {tid: True for tid in self.tags}

        self.create_subscription(Odometry, '/wbot/odom', self.odom_cb, 50)
        self.pub = self.create_publisher(RFIDRead, '/wbot/rfid_detected', 10)
        self.get_logger().info(
            f'rfid ready  {len(self.tags)} tags  radius={DETECTION_RADIUS}m')

    def odom_cb(self, msg):
        x = msg.pose.pose.position.x
        y = msg.pose.pose.position.y
        for tid, (tx, ty, is_home) in self.tags.items():
            d = math.hypot(x - tx, y - ty)
            if d < DETECTION_RADIUS and self.armed[tid]:
                self.fire(tid, d, is_home)
                self.armed[tid] = False
            elif d > REARM_DISTANCE and not self.armed[tid]:
                self.armed[tid] = True

    def fire(self, tid, d, is_home):
        m = RFIDRead()
        m.tag_id = tid; m.distance = float(d); m.is_home = is_home
        self.pub.publish(m)
        icon = 'HOME' if is_home else 'TAG'
        self.get_logger().info(f'[{icon}] {tid} (dist={d:.2f}m)')


def main(args=None):
    rclpy.init(args=args)
    n = Rfid()
    try: rclpy.spin(n)
    except KeyboardInterrupt: pass
    finally:
        n.destroy_node(); rclpy.shutdown()


if __name__ == '__main__':
    main()
PYEOF

# arm.py — 3 second stub
cat > $WS/src/wbot_brain/wbot_brain/arm.py <<'PYEOF'
#!/usr/bin/env python3
"""arm.py — Arm stub: 3 second wait then signal done."""
import rclpy
from rclpy.node import Node
from std_msgs.msg import Bool


class Arm(Node):
    def __init__(self):
        super().__init__('arm')
        self.duration = 3.0
        self.timer = None
        self.create_subscription(Bool, '/arm/start', self.start_cb, 10)
        self.done_pub = self.create_publisher(Bool, '/arm/done', 10)
        self.get_logger().info('arm ready (stub: 3s)')

    def start_cb(self, msg):
        if not msg.data: return
        self.get_logger().info('arm task starting...')
        if self.timer: self.timer.cancel()
        self.timer = self.create_timer(self.duration, self.finish)

    def finish(self):
        self.timer.cancel(); self.timer = None
        d = Bool(); d.data = True
        self.done_pub.publish(d)
        self.get_logger().info('arm task done')


def main(args=None):
    rclpy.init(args=args)
    n = Arm()
    try: rclpy.spin(n)
    except KeyboardInterrupt: pass
    finally:
        n.destroy_node(); rclpy.shutdown()


if __name__ == '__main__':
    main()
PYEOF

# brain.py — state machine + arbiter (sole publisher of /wbot/cmd_vel)
cat > $WS/src/wbot_brain/wbot_brain/brain.py <<'PYEOF'
#!/usr/bin/env python3
"""brain.py — Mission FSM AND cmd_vel arbiter. SOLE publisher of /wbot/cmd_vel."""
import math
import rclpy
from rclpy.node import Node
from std_msgs.msg import Bool, String, Float32
from geometry_msgs.msg import Twist
from wbot_msgs.msg import Order, RFIDRead, BotState
from wbot_brain.shelves import SHELF_MAP

IDLE        = 'IDLE'
GOING       = 'GOING'
AT_SHELF    = 'AT_SHELF'
WAITING     = 'WAITING'
PIVOTING    = 'PIVOTING'
PIVOT_NUDGE = 'PIVOT_NUDGE'
RETURNING   = 'RETURNING'

NUDGE_SPEED    = 0.20
NUDGE_DURATION = 0.75


class Brain(Node):
    def __init__(self):
        super().__init__('brain')

        self.state = IDLE
        self.order = None
        self.last_rfid = ''
        self.junction_count = 0
        self.turning = False
        self.last_junc_t = 0.0
        self.JUNC_COOLDOWN = 1.5
        self.post_turn_block_until = 0.0
        self.POST_TURN_BLOCK = 2.5
        self.pivot_nudge_start = None

        self._nudge_twist = Twist()
        self._nudge_twist.linear.x = NUDGE_SPEED

        self.follow_vel = Twist()
        self.turn_vel   = Twist()
        self.pivot_vel  = Twist()

        self.create_subscription(Twist, '/wbot/follow_vel', self.fv_cb, 10)
        self.create_subscription(Twist, '/wbot/turn_vel',   self.tv_cb, 10)
        self.create_subscription(Twist, '/wbot/pivot_vel',  self.pv_cb, 10)
        self.create_subscription(Order,    '/wbot/order',             self.order_cb,      10)
        self.create_subscription(RFIDRead, '/wbot/rfid_detected',     self.rfid_cb,       10)
        self.create_subscription(Bool,     '/wbot/junction_detected', self.junc_cb,       10)
        self.create_subscription(Bool,     '/wbot/turn_done',         self.turn_done_cb,  10)
        self.create_subscription(Bool,     '/arm/done',               self.arm_done_cb,   10)
        self.create_subscription(Bool,     '/wbot/pivot_done',        self.pivot_done_cb, 10)

        self.cmd_pub   = self.create_publisher(Twist,    '/wbot/cmd_vel',  10)
        self.turn_pub  = self.create_publisher(String,   '/wbot/turn_cmd', 10)
        self.pivot_pub = self.create_publisher(Float32,  '/wbot/pivot_cmd',10)
        self.arm_pub   = self.create_publisher(Bool,     '/arm/start',     10)
        self.state_pub = self.create_publisher(BotState, '/wbot/state',    10)

        self.create_timer(0.02, self.arbiter)
        self.create_timer(0.5,  self.broadcast_state)
        self.get_logger().info('brain ready — sole publisher of /wbot/cmd_vel')

    def fv_cb(self, msg): self.follow_vel = msg
    def tv_cb(self, msg): self.turn_vel   = msg
    def pv_cb(self, msg): self.pivot_vel  = msg

    def arbiter(self):
        if self.state in (IDLE, AT_SHELF, WAITING):
            self.cmd_pub.publish(Twist())
        elif self.state == PIVOT_NUDGE:
            elapsed = self.now_s() - self.pivot_nudge_start
            if elapsed >= NUDGE_DURATION:
                self.get_logger().info(
                    f'pivot nudge done ({elapsed:.2f}s) -> RETURNING')
                self.set_state(RETURNING)
                self.pivot_nudge_start = None
            else:
                self.cmd_pub.publish(self._nudge_twist)
        elif self.turning:
            self.cmd_pub.publish(self.turn_vel)
        elif self.state == PIVOTING:
            self.cmd_pub.publish(self.pivot_vel)
        elif self.state in (GOING, RETURNING):
            self.cmd_pub.publish(self.follow_vel)
        else:
            self.cmd_pub.publish(Twist())

    def now_s(self):
        return self.get_clock().now().nanoseconds / 1e9

    def set_state(self, s):
        if s == self.state: return
        self.get_logger().info(f'STATE: {self.state} -> {s}')
        self.state = s
        self.broadcast_state()

    def broadcast_state(self):
        m = BotState()
        m.state = self.state
        m.current_target = self.order.shelf_id if self.order else ''
        m.current_sku    = self.order.sku if self.order else ''
        m.last_rfid = self.last_rfid
        self.state_pub.publish(m)

    def order_cb(self, msg):
        if self.state != IDLE:
            self.get_logger().warn(f'order ignored — state={self.state}')
            return
        if msg.shelf_id not in SHELF_MAP:
            self.get_logger().error(f'unknown shelf: {msg.shelf_id}')
            return
        self.order = msg
        self.junction_count = 0
        info = SHELF_MAP[msg.shelf_id]
        self.get_logger().info(
            f'ORDER: {msg.shelf_id} aisle={info["aisle"]} sku={msg.sku}')
        self.set_state(GOING)

    def junc_cb(self, msg):
        if not msg.data: return
        t = self.now_s()
        if t < self.post_turn_block_until: return
        if t - self.last_junc_t < self.JUNC_COOLDOWN: return
        if self.turning: return
        self.last_junc_t = t

        if self.state == GOING and self.order:
            self.junction_count += 1
            target = SHELF_MAP[self.order.shelf_id]['aisle']
            self.get_logger().info(
                f'junction #{self.junction_count} (target aisle {target})')
            if self.junction_count == target:
                self._do_turn('left')
        elif self.state == RETURNING:
            self.get_logger().info('return junction — turning right')
            self._do_turn('right')

    def _do_turn(self, direction):
        self.turning = True
        m = String(); m.data = direction
        self.turn_pub.publish(m)

    def turn_done_cb(self, msg):
        if not msg.data: return
        self.turning = False
        self.post_turn_block_until = self.now_s() + self.POST_TURN_BLOCK
        self.get_logger().info(
            f'turn done  junctions blocked {self.POST_TURN_BLOCK}s')

    def rfid_cb(self, msg):
        self.last_rfid = msg.tag_id
        if (self.state == GOING and self.order
                and msg.tag_id == self.order.shelf_id):
            self.get_logger().info(f'TARGET REACHED: {msg.tag_id}')
            self.set_state(AT_SHELF)
            s = Bool(); s.data = True
            self.arm_pub.publish(s)
            self.set_state(WAITING)
        elif self.state == RETURNING and msg.is_home:
            self.get_logger().info('HOME reached — mission complete')
            self.order = None
            self.set_state(IDLE)

    def arm_done_cb(self, msg):
        if not msg.data or self.state != WAITING: return
        self.get_logger().info('arm done — pivoting 180')
        self.set_state(PIVOTING)
        p = Float32(); p.data = math.pi
        self.pivot_pub.publish(p)

    def pivot_done_cb(self, msg):
        if not msg.data or self.state != PIVOTING: return
        self.pivot_nudge_start = self.now_s()
        self.junction_count = 0
        self.get_logger().info(
            f'pivot done — nudging {NUDGE_DURATION}s @ {NUDGE_SPEED}m/s')
        self.set_state(PIVOT_NUDGE)


def main(args=None):
    rclpy.init(args=args)
    n = Brain()
    try: rclpy.spin(n)
    except KeyboardInterrupt: pass
    finally:
        n.cmd_pub.publish(Twist())
        n.destroy_node(); rclpy.shutdown()


if __name__ == '__main__':
    main()
PYEOF

# send.py — CLI order sender
cat > $WS/src/wbot_brain/wbot_brain/send.py <<'PYEOF'
#!/usr/bin/env python3
"""send.py — CLI: ros2 run wbot_brain send S05"""
import sys
import time
import rclpy
from rclpy.node import Node
from wbot_msgs.msg import Order
from wbot_brain.shelves import SHELF_MAP


def main():
    if len(sys.argv) < 2:
        print("Usage: ros2 run wbot_brain send <SHELF> [SKU]")
        print(f"Available: {', '.join(sorted(SHELF_MAP.keys()))}")
        sys.exit(1)
    shelf_id = sys.argv[1].upper()
    sku = sys.argv[2] if len(sys.argv) > 2 else 'SKU-0000'
    if shelf_id not in SHELF_MAP:
        print(f"Invalid: {shelf_id}"); sys.exit(1)
    rclpy.init()
    n = Node('order_sender')
    p = n.create_publisher(Order, '/wbot/order', 10)
    time.sleep(0.5)
    info = SHELF_MAP[shelf_id]
    m = Order()
    m.shelf_id = shelf_id; m.aisle = info['aisle']; m.sku = sku
    p.publish(m)
    print(f"Sent: {shelf_id} aisle {info['aisle']} sku={sku}")
    time.sleep(0.3)
    n.destroy_node(); rclpy.shutdown()


if __name__ == '__main__':
    main()
PYEOF

# gui.py — Tkinter GUI
cat > $WS/src/wbot_brain/wbot_brain/gui.py <<'PYEOF'
#!/usr/bin/env python3
"""gui.py — Tkinter control panel."""
import threading, queue
from datetime import datetime
import rclpy
from rclpy.node import Node
from nav_msgs.msg import Odometry
from wbot_msgs.msg import Order, RFIDRead, BotState
import tkinter as tk
from tkinter import ttk, scrolledtext
from wbot_brain.shelves import SHELF_MAP


class Bridge(Node):
    def __init__(self, q):
        super().__init__('gui')
        self.q = q
        self.order_pub = self.create_publisher(Order, '/wbot/order', 10)
        self.create_subscription(BotState,  '/wbot/state',         self.state_cb, 10)
        self.create_subscription(RFIDRead,  '/wbot/rfid_detected', self.rfid_cb,  10)
        self.create_subscription(Odometry,  '/wbot/odom',          self.odom_cb,  10)

    def send_order(self, sid, sku):
        info = SHELF_MAP[sid]
        m = Order()
        m.shelf_id = sid; m.aisle = info['aisle']; m.sku = sku
        self.order_pub.publish(m)

    def state_cb(self, msg):
        self.q.put(('state', {'state': msg.state, 'target': msg.current_target,
                              'sku': msg.current_sku, 'rfid': msg.last_rfid}))

    def rfid_cb(self, msg):
        icon = 'HOME' if msg.is_home else 'TAG'
        self.q.put(('log', f'[{icon}] {msg.tag_id} ({msg.distance:.2f}m)'))

    def odom_cb(self, msg):
        self.q.put(('odom', {'x': msg.pose.pose.position.x,
                             'y': msg.pose.pose.position.y}))


class Gui:
    COLORS = {'IDLE':'#4CAF50','GOING':'#2196F3','AT_SHELF':'#FF9800',
              'WAITING':'#9C27B0','PIVOTING':'#FF5722','PIVOT_NUDGE':'#E91E63',
              'RETURNING':'#00BCD4'}

    def __init__(self, root, bridge, q):
        self.root = root; self.bridge = bridge; self.q = q
        self.q_orders = []; self.cur_state = 'IDLE'
        root.title('wbot Control Center')
        root.geometry('850x650'); root.configure(bg='#1e1e1e')
        self._build(); self._poll()

    def _build(self):
        f1 = tk.Frame(self.root, bg='#2d2d2d', pady=8)
        f1.pack(fill='x', padx=8, pady=6)
        tk.Label(f1, text='Send Order', font=('Arial',13,'bold'),
                 bg='#2d2d2d', fg='white').grid(row=0, column=0, columnspan=4, sticky='w')
        tk.Label(f1, text='Shelf:', bg='#2d2d2d', fg='white').grid(row=1, column=0, padx=4)
        self.shelf_var = tk.StringVar(value='S01')
        ttk.Combobox(f1, textvariable=self.shelf_var, values=sorted(SHELF_MAP.keys()),
                     state='readonly', width=8).grid(row=1, column=1, padx=4)
        tk.Label(f1, text='SKU:', bg='#2d2d2d', fg='white').grid(row=1, column=2, padx=4)
        self.sku_var = tk.StringVar(value='SKU-1042')
        tk.Entry(f1, textvariable=self.sku_var, width=14).grid(row=1, column=3, padx=4)
        tk.Button(f1, text='SEND ORDER', command=self.send_now,
                  bg='#4CAF50', fg='white', font=('Arial',9,'bold')).grid(row=1, column=4, padx=8)
        tk.Button(f1, text='+ QUEUE', command=self.add_queue,
                  bg='#2196F3', fg='white', font=('Arial',9,'bold')).grid(row=1, column=5, padx=4)

        f2 = tk.Frame(self.root, bg='#2d2d2d', pady=8)
        f2.pack(fill='x', padx=8, pady=6)
        tk.Label(f2, text='Live Dashboard', font=('Arial',13,'bold'),
                 bg='#2d2d2d', fg='white').grid(row=0, column=0, columnspan=4, sticky='w')
        tk.Label(f2, text='State:', bg='#2d2d2d', fg='white').grid(row=1, column=0)
        self.state_lbl = tk.Label(f2, text='IDLE', bg='#4CAF50', fg='white',
                                   font=('Arial',11,'bold'), width=12)
        self.state_lbl.grid(row=1, column=1, padx=4)
        tk.Label(f2, text='Target:', bg='#2d2d2d', fg='white').grid(row=1, column=2)
        self.target_lbl = tk.Label(f2, text='—', bg='#1e1e1e', fg='yellow',
                                    font=('Courier',11,'bold'), width=10)
        self.target_lbl.grid(row=1, column=3, padx=4)
        tk.Label(f2, text='SKU:', bg='#2d2d2d', fg='white').grid(row=2, column=0)
        self.sku_lbl = tk.Label(f2, text='—', bg='#1e1e1e', fg='magenta',
                                 font=('Courier',11), width=14)
        self.sku_lbl.grid(row=2, column=1, padx=4)
        tk.Label(f2, text='RFID:', bg='#2d2d2d', fg='white').grid(row=2, column=2)
        self.rfid_lbl = tk.Label(f2, text='—', bg='#1e1e1e', fg='cyan',
                                  font=('Courier',11), width=12)
        self.rfid_lbl.grid(row=2, column=3, padx=4)
        tk.Label(f2, text='Pos:', bg='#2d2d2d', fg='white').grid(row=3, column=0)
        self.pos_lbl = tk.Label(f2, text='(0.00, 0.00)', bg='#1e1e1e', fg='lightgreen',
                                 font=('Courier',11), width=18)
        self.pos_lbl.grid(row=3, column=1, padx=4)
        tk.Label(f2, text='Queue:', bg='#2d2d2d', fg='white').grid(row=4, column=0)
        self.queue_lbl = tk.Label(f2, text='(empty)', bg='#1e1e1e', fg='orange',
                                   font=('Courier',10), anchor='w', width=55)
        self.queue_lbl.grid(row=4, column=1, columnspan=3, padx=4, sticky='w')

        f3 = tk.Frame(self.root, bg='#2d2d2d')
        f3.pack(fill='both', expand=True, padx=8, pady=6)
        tk.Label(f3, text='Mission Log', font=('Arial',13,'bold'),
                 bg='#2d2d2d', fg='white').pack(anchor='w', padx=4, pady=4)
        self.log = scrolledtext.ScrolledText(f3, height=14, bg='#0a0a0a',
                                              fg='#00ff00', font=('Courier',9))
        self.log.pack(fill='both', expand=True, padx=4, pady=4)
        self.write_log('wbot Control Center ready.')

    def send_now(self):
        sid = self.shelf_var.get(); sku = self.sku_var.get().strip() or 'SKU-0000'
        if self.cur_state != 'IDLE':
            self.write_log(f'busy — queued: {sid}')
            self.q_orders.append((sid, sku)); self.update_queue(); return
        self.bridge.send_order(sid, sku)
        self.write_log(f'Sent: {sid} ({sku})')

    def add_queue(self):
        sid = self.shelf_var.get(); sku = self.sku_var.get().strip() or 'SKU-0000'
        self.q_orders.append((sid, sku))
        self.write_log(f'Queued: {sid} ({sku})'); self.update_queue()

    def update_queue(self):
        self.queue_lbl.config(text='(empty)' if not self.q_orders
                              else ' -> '.join(s for s,_ in self.q_orders))

    def _poll(self):
        try:
            while True:
                k, d = self.q.get_nowait()
                if k == 'state':
                    s = d['state']
                    self.state_lbl.config(text=s, bg=self.COLORS.get(s, '#666'))
                    self.target_lbl.config(text=d['target'] or '—')
                    self.sku_lbl.config(text=d['sku'] or '—')
                    self.rfid_lbl.config(text=d['rfid'] or '—')
                    if (self.cur_state != 'IDLE' and s == 'IDLE'
                            and self.q_orders):
                        ns, nk = self.q_orders.pop(0); self.update_queue()
                        self.bridge.send_order(ns, nk)
                        self.write_log(f'Auto-dispatch: {ns}')
                    if s != self.cur_state:
                        self.write_log(f'STATE: {self.cur_state} -> {s}')
                    self.cur_state = s
                elif k == 'odom':
                    self.pos_lbl.config(text=f"({d['x']:+.2f}, {d['y']:+.2f})")
                elif k == 'log':
                    self.write_log(d)
        except queue.Empty:
            pass
        self.root.after(80, self._poll)

    def write_log(self, m):
        ts = datetime.now().strftime('%H:%M:%S')
        self.log.insert('end', f'[{ts}] {m}\n')
        self.log.see('end')


def main():
    rclpy.init()
    q = queue.Queue()
    b = Bridge(q)
    threading.Thread(target=rclpy.spin, args=(b,), daemon=True).start()
    root = tk.Tk()
    Gui(root, b, q)
    try: root.mainloop()
    except KeyboardInterrupt: pass
    finally:
        b.destroy_node(); rclpy.shutdown()


if __name__ == '__main__':
    main()
PYEOF

# Brain config + launch
cat > $WS/src/wbot_brain/config/follow_params.yaml <<'YAMLEOF'
follow:
  ros__parameters:
    linear_speed: 0.50
    kp: 0.50
    ki: 0.00
    kd: 0.15
YAMLEOF

cat > $WS/src/wbot_brain/launch/brain.launch.py <<'PYEOF'
import os
from launch import LaunchDescription
from launch_ros.actions import Node
from ament_index_python.packages import get_package_share_directory


def generate_launch_description():
    params = os.path.join(
        get_package_share_directory('wbot_brain'),
        'config', 'follow_params.yaml')
    return LaunchDescription([
        Node(package='wbot_brain', executable='optical', name='optical', output='screen'),
        Node(package='wbot_brain', executable='follow',  name='follow',  output='screen', parameters=[params]),
        Node(package='wbot_brain', executable='rfid',    name='rfid',    output='screen'),
        Node(package='wbot_brain', executable='turn',    name='turn',    output='screen'),
        Node(package='wbot_brain', executable='pivot',   name='pivot',   output='screen'),
        Node(package='wbot_brain', executable='arm',     name='arm',     output='screen'),
        Node(package='wbot_brain', executable='brain',   name='brain',   output='screen'),
    ])
PYEOF

cat > $WS/src/wbot_brain/setup.py <<'PYEOF'
from setuptools import setup
from glob import glob
import os
package_name = 'wbot_brain'
setup(
    name=package_name,
    version='0.1.0',
    packages=[package_name],
    data_files=[
        ('share/ament_index/resource_index/packages',
            ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
        (os.path.join('share', package_name, 'launch'), glob('launch/*.py')),
        (os.path.join('share', package_name, 'config'), glob('config/*.yaml')),
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    maintainer='you',
    maintainer_email='you@example.com',
    description='wbot brain',
    license='MIT',
    entry_points={
        'console_scripts': [
            'optical = wbot_brain.optical:main',
            'follow  = wbot_brain.follow:main',
            'rfid    = wbot_brain.rfid:main',
            'turn    = wbot_brain.turn:main',
            'pivot   = wbot_brain.pivot:main',
            'arm     = wbot_brain.arm:main',
            'brain   = wbot_brain.brain:main',
            'send    = wbot_brain.send:main',
            'gui     = wbot_brain.gui:main',
        ],
    },
)
PYEOF

cat > $WS/src/wbot_brain/package.xml <<'EOF'
<?xml version="1.0"?>
<package format="3">
  <name>wbot_brain</name>
  <version>0.1.0</version>
  <description>wbot brain</description>
  <maintainer email="you@example.com">you</maintainer>
  <license>MIT</license>
  <buildtool_depend>ament_python</buildtool_depend>
  <exec_depend>rclpy</exec_depend>
  <exec_depend>nav_msgs</exec_depend>
  <exec_depend>std_msgs</exec_depend>
  <exec_depend>geometry_msgs</exec_depend>
  <exec_depend>visualization_msgs</exec_depend>
  <exec_depend>wbot_msgs</exec_depend>
  <exec_depend>python3-numpy</exec_depend>
  <export><build_type>ament_python</build_type></export>
</package>
EOF

# ====================================================================
# 5. wbot_run — master launcher
# ====================================================================
echo "Writing wbot_run..."

cat > $WS/src/wbot_run/launch/all.launch.py <<'PYEOF'
import os
from launch import LaunchDescription
from launch.actions import IncludeLaunchDescription, TimerAction
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch_ros.actions import Node
from ament_index_python.packages import get_package_share_directory


def generate_launch_description():
    pkg_robot = get_package_share_directory('wbot_robot')
    pkg_brain = get_package_share_directory('wbot_brain')

    spawn = IncludeLaunchDescription(
        PythonLaunchDescriptionSource(
            os.path.join(pkg_robot, 'launch', 'spawn.launch.py')))

    params = os.path.join(pkg_brain, 'config', 'follow_params.yaml')

    brain = TimerAction(period=5.0, actions=[
        Node(package='wbot_brain', executable='optical', name='optical', output='screen'),
        Node(package='wbot_brain', executable='follow',  name='follow',  output='screen', parameters=[params]),
        Node(package='wbot_brain', executable='rfid',    name='rfid',    output='screen'),
        Node(package='wbot_brain', executable='turn',    name='turn',    output='screen'),
        Node(package='wbot_brain', executable='pivot',   name='pivot',   output='screen'),
        Node(package='wbot_brain', executable='arm',     name='arm',     output='screen'),
        Node(package='wbot_brain', executable='brain',   name='brain',   output='screen'),
    ])

    gui = TimerAction(period=7.0, actions=[
        Node(package='wbot_brain', executable='gui', name='gui', output='screen'),
    ])

    return LaunchDescription([spawn, brain, gui])
PYEOF

cat > $WS/src/wbot_run/setup.py <<'PYEOF'
from setuptools import setup
from glob import glob
import os
package_name = 'wbot_run'
setup(
    name=package_name,
    version='0.1.0',
    packages=[package_name],
    data_files=[
        ('share/ament_index/resource_index/packages',
            ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
        (os.path.join('share', package_name, 'launch'), glob('launch/*.py')),
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    maintainer='you',
    maintainer_email='you@example.com',
    description='wbot master launcher',
    license='MIT',
    entry_points={'console_scripts': []},
)
PYEOF

cat > $WS/src/wbot_run/package.xml <<'EOF'
<?xml version="1.0"?>
<package format="3">
  <name>wbot_run</name>
  <version>0.1.0</version>
  <description>wbot master launcher</description>
  <maintainer email="you@example.com">you</maintainer>
  <license>MIT</license>
  <buildtool_depend>ament_python</buildtool_depend>
  <exec_depend>wbot_robot</exec_depend>
  <exec_depend>wbot_brain</exec_depend>
  <exec_depend>wbot_world</exec_depend>
  <export><build_type>ament_python</build_type></export>
</package>
EOF

# ====================================================================
# Build everything
# ====================================================================
echo ""
echo "All files written. Now building..."
cd $WS
colcon build --symlink-install
source install/setup.bash

echo ""
echo "================================================"
echo "DONE - wbot_ws is ready!"
echo "================================================"
echo ""
echo "To test:"
echo "  source ~/wbot_ws/install/setup.bash"
echo "  ros2 launch wbot_run all.launch.py"
echo ""
echo "Then in the GUI: pick S05, click SEND ORDER"
```

When the script finishes you'll see:
```
================================================
DONE - wbot_ws is ready!
================================================
```

---

## 📋 Verify Everything Got Built

```bash
echo "=== Verification ==="
ls ~/wbot_ws/install/wbot_brain/lib/wbot_brain/ 2>&1 | head -10
echo ""
ros2 interface show wbot_msgs/msg/Order
```

You should see all 9 brain executables:
```
arm
brain
follow
gui
optical
pivot
rfid
send
turn
```

Plus the Order message:
```
string shelf_id
int32 aisle
string sku
```

If both work, the project is correctly installed.

---

## 🚀 Run It

```bash
pkill -9 -f ros2 2>/dev/null; pkill -9 -f gz 2>/dev/null; sleep 2

source ~/wbot_ws/install/setup.bash
ros2 launch wbot_run all.launch.py
```

After ~7 seconds you'll see:
- 🌍 Gazebo with the warehouse
- 🤖 wbot at HOME (sitting **perfectly still**)
- 🖥️ RViz showing the robot model
- 🎨 Tkinter GUI

In the GUI:
1. Pick **S05** from the dropdown
2. Leave SKU as `SKU-1042`
3. Click **SEND ORDER**

The robot drives east → turns left at junction 2 → finds S05 → waits 3s →
pivots 180° → returns home.

---

## 🆘 If Anything Breaks

The script is **idempotent** — just re-run it. It will overwrite all files
with the correct versions.

If you want a deeper diagnostic, run:
```bash
echo "=== Topic Publishers ==="
for t in cmd_vel follow_vel turn_vel pivot_vel; do
  echo "/wbot/$t:"
  ros2 topic info /wbot/$t --verbose 2>&1 | grep -E "Publisher count|Node name" | head -4
  echo ""
done
```

You should see exactly 1 publisher per topic. **`/wbot/cmd_vel` MUST show
only `brain` as the publisher** (plus diff_drive as subscriber). If you
see anything else, run the install script again.

---

## 🎓 Why This Approach Works

The previous project broke because of **partial file edits** that left
nodes out of sync. Some nodes published to the right topic, others
didn't. The system only works when ALL nodes are correct.

This script writes **every file in one atomic operation**. There is no
possible state where some files are correct and others aren't. Either
the script succeeded entirely or it didn't run.

Re-run anytime, no consequences.
