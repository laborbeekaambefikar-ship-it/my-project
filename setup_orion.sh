#!/usr/bin/env bash
###############################################################################
#  ORION WAREHOUSE AGV — Complete One-Shot Installer
#  Platform: Ubuntu 22.04 + ROS 2 Humble + Gazebo Classic 11
#
#  Usage:
#      bash setup_orion.sh              # install + build + launch
#      bash setup_orion.sh --no-launch  # install + build only
#      bash setup_orion.sh --rebuild    # wipe build artifacts and rebuild
#      bash setup_orion.sh --clean      # remove ~/orion_ws entirely
#
#  This single script generates the ENTIRE project from scratch.
###############################################################################
set -Eeuo pipefail

ORION_WS="${ORION_WS:-$HOME/orion_ws}"
ORION_SRC="$ORION_WS/src"
ROS_DISTRO_TARGET="humble"

C_RST=$'\033[0m'; C_BLD=$'\033[1m'; C_RED=$'\033[31m'
C_GRN=$'\033[32m'; C_YLW=$'\033[33m'; C_BLU=$'\033[34m'
C_MAG=$'\033[35m'; C_CYN=$'\033[36m'

log_info()  { printf "%s[orion]%s %s\n" "$C_CYN" "$C_RST" "$*"; }
log_ok()    { printf "%s[  ok ]%s %s\n" "$C_GRN" "$C_RST" "$*"; }
log_warn()  { printf "%s[warn ]%s %s\n" "$C_YLW" "$C_RST" "$*"; }
log_err()   { printf "%s[ err ]%s %s\n" "$C_RED" "$C_RST" "$*" >&2; }
log_phase() { printf "\n%s%s══ %s ══%s\n" "$C_BLD" "$C_MAG" "$*" "$C_RST"; }

trap 'log_err "FAILED at line $LINENO"; exit 1' ERR

DO_LAUNCH=1; DO_REBUILD=0; DO_CLEAN=0
for a in "$@"; do
  case "$a" in
    --no-launch) DO_LAUNCH=0;; --rebuild) DO_REBUILD=1;;
    --clean) DO_CLEAN=1;; *) log_warn "Unknown flag: $a";;
  esac
done
[[ $DO_CLEAN -eq 1 ]] && { rm -rf "$ORION_WS"; log_ok "Cleaned."; exit 0; }


###############################################################################
# PHASE 0 — Preflight
###############################################################################
log_phase "PHASE 0 — Preflight"
if [[ ! -d "/opt/ros/$ROS_DISTRO_TARGET" ]]; then
  log_err "ROS 2 $ROS_DISTRO_TARGET not found. Install it first."; exit 1
fi
source "/opt/ros/$ROS_DISTRO_TARGET/setup.bash"
log_ok "ROS 2 $ROS_DISTRO_TARGET sourced"

###############################################################################
# PHASE 1 — Dependencies
###############################################################################
log_phase "PHASE 1 — Dependencies"
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  build-essential cmake python3-pip python3-colcon-common-extensions \
  python3-rosdep python3-pyqt5 python3-numpy python3-yaml \
  ros-humble-rclpy ros-humble-std-msgs ros-humble-geometry-msgs \
  ros-humble-sensor-msgs ros-humble-nav-msgs ros-humble-tf2-ros \
  ros-humble-tf-transformations ros-humble-xacro ros-humble-rviz2 \
  ros-humble-robot-state-publisher ros-humble-joint-state-publisher \
  ros-humble-gazebo-ros-pkgs ros-humble-gazebo-ros2-control \
  ros-humble-rosidl-default-generators ros-humble-rosidl-default-runtime
sudo rosdep init 2>/dev/null || true
rosdep update || true
pip3 install --quiet --user transforms3d
log_ok "Dependencies installed"


###############################################################################
# PHASE 2 — Workspace Setup
###############################################################################
log_phase "PHASE 2 — Workspace"
[[ $DO_REBUILD -eq 1 ]] && rm -rf "$ORION_WS/build" "$ORION_WS/install" "$ORION_WS/log"
mkdir -p "$ORION_SRC"

###############################################################################
# PHASE 3 — orion_msgs (Custom Messages)
###############################################################################
log_phase "PHASE 3 — orion_msgs"
MSGS_DIR="$ORION_SRC/orion_msgs"
mkdir -p "$MSGS_DIR/msg"

cat > "$MSGS_DIR/package.xml" <<'EOF'
<?xml version="1.0"?>
<package format="3">
  <name>orion_msgs</name>
  <version>1.0.0</version>
  <description>Orion AGV custom messages</description>
  <maintainer email="dev@orion.io">Orion</maintainer>
  <license>Apache-2.0</license>
  <buildtool_depend>ament_cmake</buildtool_depend>
  <build_depend>rosidl_default_generators</build_depend>
  <exec_depend>rosidl_default_runtime</exec_depend>
  <depend>std_msgs</depend>
  <depend>builtin_interfaces</depend>
  <member_of_group>rosidl_interface_packages</member_of_group>
  <export><build_type>ament_cmake</build_type></export>
</package>
EOF

cat > "$MSGS_DIR/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.8)
project(orion_msgs)
find_package(ament_cmake REQUIRED)
find_package(rosidl_default_generators REQUIRED)
find_package(std_msgs REQUIRED)
find_package(builtin_interfaces REQUIRED)
rosidl_generate_interfaces(${PROJECT_NAME}
  "msg/Mission.msg"
  "msg/RFIDEvent.msg"
  "msg/RobotStatus.msg"
  DEPENDENCIES std_msgs builtin_interfaces
)
ament_export_dependencies(rosidl_default_runtime)
ament_package()
EOF

cat > "$MSGS_DIR/msg/Mission.msg" <<'EOF'
string mission_id
string action
string target_shelf
string sku
uint32 priority
EOF

cat > "$MSGS_DIR/msg/RFIDEvent.msg" <<'EOF'
string tag_id
string event
string shelf_id
float32 distance
builtin_interfaces/Time stamp
EOF

cat > "$MSGS_DIR/msg/RobotStatus.msg" <<'EOF'
string state
string mission_id
string target_shelf
string current_sku
string last_rfid
bool carrying_load
float32 battery_percent
EOF
log_ok "orion_msgs generated"


###############################################################################
# PHASE 4 — orion_robot (URDF + Gazebo model)
###############################################################################
log_phase "PHASE 4 — orion_robot"
ROBOT_DIR="$ORION_SRC/orion_robot"
mkdir -p "$ROBOT_DIR"/{urdf,meshes,config,launch}
mkdir -p "$ROBOT_DIR/orion_robot"

cat > "$ROBOT_DIR/package.xml" <<'EOF'
<?xml version="1.0"?>
<package format="3">
  <name>orion_robot</name>
  <version>1.0.0</version>
  <description>Orion AGV robot model</description>
  <maintainer email="dev@orion.io">Orion</maintainer>
  <license>Apache-2.0</license>
  <buildtool_depend>ament_python</buildtool_depend>
  <depend>rclpy</depend>
  <depend>xacro</depend>
  <depend>robot_state_publisher</depend>
  <depend>joint_state_publisher</depend>
  <depend>gazebo_ros</depend>
  <export><build_type>ament_python</build_type></export>
</package>
EOF

cat > "$ROBOT_DIR/setup.py" <<'EOF'
from setuptools import setup
import os
from glob import glob

package_name = 'orion_robot'
setup(
    name=package_name,
    version='1.0.0',
    packages=[package_name],
    data_files=[
        ('share/ament_index/resource_index/packages', ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
        (os.path.join('share', package_name, 'urdf'), glob('urdf/*')),
        (os.path.join('share', package_name, 'config'), glob('config/*')),
        (os.path.join('share', package_name, 'launch'), glob('launch/*')),
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    entry_points={'console_scripts': []},
)
EOF

cat > "$ROBOT_DIR/setup.cfg" <<'EOF'
[develop]
script_dir=$base/lib/orion_robot
[install]
install_scripts=$base/lib/orion_robot
EOF

mkdir -p "$ROBOT_DIR/resource"
touch "$ROBOT_DIR/resource/orion_robot"
cat > "$ROBOT_DIR/orion_robot/__init__.py" <<'EOF'
EOF


# --- URDF: Differential-drive AGV with stable physics ---
cat > "$ROBOT_DIR/urdf/orion_agv.urdf.xacro" <<'EOF'
<?xml version="1.0"?>
<robot xmlns:xacro="http://www.ros.org/wiki/xacro" name="orion_agv">

  <!-- Properties -->
  <xacro:property name="chassis_mass" value="25.0"/>
  <xacro:property name="chassis_x" value="0.50"/>
  <xacro:property name="chassis_y" value="0.40"/>
  <xacro:property name="chassis_z" value="0.15"/>
  <xacro:property name="wheel_radius" value="0.075"/>
  <xacro:property name="wheel_width" value="0.04"/>
  <xacro:property name="wheel_mass" value="1.5"/>
  <xacro:property name="wheel_separation" value="0.44"/>
  <xacro:property name="caster_radius" value="0.035"/>
  <xacro:property name="caster_mass" value="0.3"/>

  <!-- Inertia macros -->
  <xacro:macro name="box_inertia" params="m x y z">
    <inertial>
      <mass value="${m}"/>
      <inertia ixx="${m*(y*y+z*z)/12}" ixy="0" ixz="0"
               iyy="${m*(x*x+z*z)/12}" iyz="0"
               izz="${m*(x*x+y*y)/12}"/>
    </inertial>
  </xacro:macro>

  <xacro:macro name="cylinder_inertia" params="m r h">
    <inertial>
      <mass value="${m}"/>
      <inertia ixx="${m*(3*r*r+h*h)/12}" ixy="0" ixz="0"
               iyy="${m*(3*r*r+h*h)/12}" iyz="0"
               izz="${m*r*r/2}"/>
    </inertial>
  </xacro:macro>

  <xacro:macro name="sphere_inertia" params="m r">
    <inertial>
      <mass value="${m}"/>
      <inertia ixx="${2*m*r*r/5}" ixy="0" ixz="0"
               iyy="${2*m*r*r/5}" iyz="0"
               izz="${2*m*r*r/5}"/>
    </inertial>
  </xacro:macro>

  <!-- Base footprint (ground plane reference) -->
  <link name="base_footprint"/>

  <!-- Chassis -->
  <link name="base_link">
    <xacro:box_inertia m="${chassis_mass}" x="${chassis_x}" y="${chassis_y}" z="${chassis_z}"/>
    <visual>
      <geometry><box size="${chassis_x} ${chassis_y} ${chassis_z}"/></geometry>
      <material name="orange"><color rgba="0.9 0.5 0.1 1.0"/></material>
    </visual>
    <collision>
      <geometry><box size="${chassis_x} ${chassis_y} ${chassis_z}"/></geometry>
    </collision>
  </link>

  <joint name="base_footprint_joint" type="fixed">
    <parent link="base_footprint"/>
    <child link="base_link"/>
    <origin xyz="0 0 ${wheel_radius + 0.01}" rpy="0 0 0"/>
  </joint>

  <!-- Wheel macro -->
  <xacro:macro name="drive_wheel" params="prefix y_offset">
    <link name="${prefix}_wheel">
      <xacro:cylinder_inertia m="${wheel_mass}" r="${wheel_radius}" h="${wheel_width}"/>
      <visual>
        <geometry><cylinder radius="${wheel_radius}" length="${wheel_width}"/></geometry>
        <material name="dark"><color rgba="0.2 0.2 0.2 1.0"/></material>
      </visual>
      <collision>
        <geometry><cylinder radius="${wheel_radius}" length="${wheel_width}"/></geometry>
        <surface>
          <friction>
            <ode><mu>1.2</mu><mu2>1.2</mu2></ode>
          </friction>
          <contact>
            <ode>
              <kp>1000000.0</kp><kd>100.0</kd>
              <min_depth>0.001</min_depth><max_vel>0.1</max_vel>
            </ode>
          </contact>
        </surface>
      </collision>
    </link>
    <joint name="${prefix}_wheel_joint" type="continuous">
      <parent link="base_link"/>
      <child link="${prefix}_wheel"/>
      <origin xyz="0 ${y_offset} ${-0.01}" rpy="${-pi/2} 0 0"/>
      <axis xyz="0 0 1"/>
      <dynamics damping="0.7" friction="1.0"/>
    </joint>
  </xacro:macro>

  <xacro:drive_wheel prefix="left" y_offset="${wheel_separation/2}"/>
  <xacro:drive_wheel prefix="right" y_offset="${-wheel_separation/2}"/>

  <!-- Caster macro -->
  <xacro:macro name="caster_wheel" params="prefix x_offset">
    <link name="${prefix}_caster">
      <xacro:sphere_inertia m="${caster_mass}" r="${caster_radius}"/>
      <visual>
        <geometry><sphere radius="${caster_radius}"/></geometry>
        <material name="grey"><color rgba="0.5 0.5 0.5 1.0"/></material>
      </visual>
      <collision>
        <geometry><sphere radius="${caster_radius}"/></geometry>
        <surface>
          <friction>
            <ode><mu>0.01</mu><mu2>0.01</mu2></ode>
          </friction>
          <contact>
            <ode>
              <kp>1000000.0</kp><kd>100.0</kd>
              <min_depth>0.001</min_depth><max_vel>0.1</max_vel>
            </ode>
          </contact>
        </surface>
      </collision>
    </link>
    <joint name="${prefix}_caster_joint" type="fixed">
      <parent link="base_link"/>
      <child link="${prefix}_caster"/>
      <origin xyz="${x_offset} 0 ${-(wheel_radius - caster_radius) - 0.01}" rpy="0 0 0"/>
    </joint>
  </xacro:macro>

  <xacro:caster_wheel prefix="front" x_offset="${chassis_x/2 - 0.05}"/>
  <xacro:caster_wheel prefix="rear" x_offset="${-(chassis_x/2 - 0.05)}"/>

  <!-- IMU sensor link -->
  <link name="imu_link">
    <inertial><mass value="0.01"/><inertia ixx="0.000001" ixy="0" ixz="0" iyy="0.000001" iyz="0" izz="0.000001"/></inertial>
  </link>
  <joint name="imu_joint" type="fixed">
    <parent link="base_link"/><child link="imu_link"/>
    <origin xyz="0 0 0.08" rpy="0 0 0"/>
  </joint>

  <!-- Gazebo Plugins -->
  <gazebo>
    <plugin name="diff_drive" filename="libgazebo_ros_diff_drive.so">
      <ros><namespace>/orion</namespace></ros>
      <left_joint>left_wheel_joint</left_joint>
      <right_joint>right_wheel_joint</right_joint>
      <wheel_separation>${wheel_separation}</wheel_separation>
      <wheel_diameter>${wheel_radius*2}</wheel_diameter>
      <max_wheel_torque>30.0</max_wheel_torque>
      <max_wheel_acceleration>2.0</max_wheel_acceleration>
      <command_topic>cmd_vel</command_topic>
      <odometry_topic>odom</odometry_topic>
      <odometry_frame>odom</odometry_frame>
      <robot_base_frame>base_footprint</robot_base_frame>
      <publish_odom>true</publish_odom>
      <publish_odom_tf>true</publish_odom_tf>
      <publish_wheel_tf>true</publish_wheel_tf>
      <update_rate>50.0</update_rate>
    </plugin>
  </gazebo>

  <gazebo reference="imu_link">
    <sensor name="imu_sensor" type="imu">
      <always_on>true</always_on>
      <update_rate>50</update_rate>
      <plugin name="imu_plugin" filename="libgazebo_ros_imu_sensor.so">
        <ros><namespace>/orion</namespace><remapping>~/out:=imu/data</remapping></ros>
        <frame_name>imu_link</frame_name>
        <initial_orientation_as_reference>false</initial_orientation_as_reference>
      </plugin>
    </sensor>
  </gazebo>

  <gazebo reference="base_link">
    <material>Gazebo/Orange</material>
  </gazebo>
  <gazebo reference="left_wheel"><material>Gazebo/DarkGrey</material></gazebo>
  <gazebo reference="right_wheel"><material>Gazebo/DarkGrey</material></gazebo>

</robot>
EOF
log_ok "orion_robot URDF generated"


###############################################################################
# PHASE 5 — orion_world (Warehouse world generator + world file)
###############################################################################
log_phase "PHASE 5 — orion_world"
WORLD_DIR="$ORION_SRC/orion_world"
mkdir -p "$WORLD_DIR"/{worlds,models,maps,scripts,launch}
mkdir -p "$WORLD_DIR/orion_world"

cat > "$WORLD_DIR/package.xml" <<'EOF'
<?xml version="1.0"?>
<package format="3">
  <name>orion_world</name>
  <version>1.0.0</version>
  <description>Orion warehouse world and generator</description>
  <maintainer email="dev@orion.io">Orion</maintainer>
  <license>Apache-2.0</license>
  <buildtool_depend>ament_python</buildtool_depend>
  <depend>gazebo_ros</depend>
  <export><build_type>ament_python</build_type></export>
</package>
EOF

cat > "$WORLD_DIR/setup.py" <<'EOF'
from setuptools import setup
import os
from glob import glob

package_name = 'orion_world'
setup(
    name=package_name,
    version='1.0.0',
    packages=[package_name],
    data_files=[
        ('share/ament_index/resource_index/packages', ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
        (os.path.join('share', package_name, 'worlds'), glob('worlds/*')),
        (os.path.join('share', package_name, 'models'), glob('models/**/*', recursive=True)),
        (os.path.join('share', package_name, 'launch'), glob('launch/*')),
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    entry_points={
        'console_scripts': [
            'generate_world = orion_world.generate_world:main',
        ],
    },
)
EOF

cat > "$WORLD_DIR/setup.cfg" <<'EOF'
[develop]
script_dir=$base/lib/orion_world
[install]
install_scripts=$base/lib/orion_world
EOF

mkdir -p "$WORLD_DIR/resource"
touch "$WORLD_DIR/resource/orion_world"
cat > "$WORLD_DIR/orion_world/__init__.py" <<'EOF'
EOF


# --- World Generator Script ---
cat > "$WORLD_DIR/orion_world/generate_world.py" <<'PYEOF'
#!/usr/bin/env python3
"""
Orion Warehouse World Generator
Generates a complete Gazebo .world file with:
  - HOME station
  - 5 aisles with 4 shelves each (20 total)
  - Guide paths (floor lines)
  - Junctions
  - RFID tag locations
  - Loading/return areas
"""
import os
import sys
import math


def make_box_model(name, x, y, z, sx, sy, sz, r, g, b, a=1.0):
    return f"""
    <model name="{name}">
      <static>true</static>
      <pose>{x} {y} {z} 0 0 0</pose>
      <link name="link">
        <collision name="col">
          <geometry><box><size>{sx} {sy} {sz}</size></box></geometry>
        </collision>
        <visual name="vis">
          <geometry><box><size>{sx} {sy} {sz}</size></box></geometry>
          <material>
            <ambient>{r} {g} {b} {a}</ambient>
            <diffuse>{r} {g} {b} {a}</diffuse>
          </material>
        </visual>
      </link>
    </model>"""


def make_line(name, x1, y1, x2, y2, width=0.08):
    """Floor guide line as a thin box at ground level."""
    cx = (x1 + x2) / 2.0
    cy = (y1 + y2) / 2.0
    dx = x2 - x1
    dy = y2 - y1
    length = math.sqrt(dx*dx + dy*dy)
    angle = math.atan2(dy, dx)
    return f"""
    <model name="{name}">
      <static>true</static>
      <pose>{cx} {cy} 0.001 0 0 {angle}</pose>
      <link name="link">
        <visual name="vis">
          <geometry><box><size>{length} {width} 0.002</size></box></geometry>
          <material>
            <ambient>0.0 0.0 0.0 1.0</ambient>
            <diffuse>0.0 0.0 0.0 1.0</diffuse>
          </material>
        </visual>
      </link>
    </model>"""


def generate_world(output_path):
    models = []
    lines = []
    rfid_positions = []

    # Warehouse parameters
    aisle_spacing = 3.0
    shelf_spacing = 2.0
    num_aisles = 5
    shelves_per_aisle = 4
    home_x = 0.0
    home_y = 0.0
    main_corridor_y = 0.0
    aisle_start_x = 3.0

    # HOME station marker
    models.append(make_box_model("home_station", home_x, home_y, 0.01,
                                 0.6, 0.6, 0.02, 0.0, 0.8, 0.0))

    # Main corridor guide line (horizontal)
    corridor_end_x = aisle_start_x + (num_aisles - 1) * aisle_spacing + 1.0
    lines.append(make_line("main_corridor", home_x + 0.4, main_corridor_y,
                           corridor_end_x, main_corridor_y))

    # Generate aisles and shelves
    shelf_id = 0
    for aisle_idx in range(num_aisles):
        aisle_x = aisle_start_x + aisle_idx * aisle_spacing
        aisle_letter = chr(ord('A') + aisle_idx)

        # Junction marker at corridor intersection
        models.append(make_box_model(
            f"junction_{aisle_letter}", aisle_x, main_corridor_y, 0.001,
            0.15, 0.15, 0.002, 1.0, 1.0, 0.0))

        # Aisle line going north
        aisle_end_y = (shelves_per_aisle) * shelf_spacing + 0.5
        lines.append(make_line(f"aisle_{aisle_letter}_line",
                               aisle_x, main_corridor_y + 0.2,
                               aisle_x, aisle_end_y))

        # Shelves on both sides of aisle
        for shelf_idx in range(shelves_per_aisle):
            shelf_y = (shelf_idx + 1) * shelf_spacing
            shelf_id += 1
            shelf_name_l = f"{aisle_letter}{shelf_idx*2+1}"
            shelf_name_r = f"{aisle_letter}{shelf_idx*2+2}"

            # Left shelf
            models.append(make_box_model(
                f"shelf_{shelf_name_l}",
                aisle_x - 0.8, shelf_y, 0.5,
                0.4, 0.8, 1.0, 0.4, 0.3, 0.2))

            # Right shelf
            models.append(make_box_model(
                f"shelf_{shelf_name_r}",
                aisle_x + 0.8, shelf_y, 0.5,
                0.4, 0.8, 1.0, 0.4, 0.3, 0.2))

            # RFID tags at shelf positions
            rfid_positions.append((f"RFID_{shelf_name_l}", aisle_x, shelf_y))
            rfid_positions.append((f"RFID_{shelf_name_r}", aisle_x, shelf_y))

            # Shelf floor markers
            models.append(make_box_model(
                f"marker_{shelf_name_l}", aisle_x, shelf_y, 0.001,
                0.12, 0.12, 0.002, 0.8, 0.0, 0.0))

    # Loading area
    models.append(make_box_model("loading_area",
                                 corridor_end_x + 1.5, 0.0, 0.01,
                                 1.0, 1.0, 0.02, 0.0, 0.0, 0.8))

    # Return line back to home
    lines.append(make_line("return_line", corridor_end_x, -1.0, home_x + 0.4, -1.0))
    lines.append(make_line("return_conn_start", corridor_end_x, main_corridor_y,
                           corridor_end_x, -1.0))
    lines.append(make_line("return_conn_end", home_x + 0.4, -1.0,
                           home_x + 0.4, main_corridor_y))

    # Walls
    wall_len_x = corridor_end_x + 4.0
    wall_len_y = (shelves_per_aisle + 1) * shelf_spacing + 2.0
    cx = wall_len_x / 2.0 - 1.0
    cy = wall_len_y / 2.0 - 2.0
    models.append(make_box_model("wall_north", cx, cy + wall_len_y/2, 1.0,
                                 wall_len_x, 0.1, 2.0, 0.7, 0.7, 0.7))
    models.append(make_box_model("wall_south", cx, cy - wall_len_y/2, 1.0,
                                 wall_len_x, 0.1, 2.0, 0.7, 0.7, 0.7))
    models.append(make_box_model("wall_east", cx + wall_len_x/2, cy, 1.0,
                                 0.1, wall_len_y, 2.0, 0.7, 0.7, 0.7))
    models.append(make_box_model("wall_west", cx - wall_len_x/2, cy, 1.0,
                                 0.1, wall_len_y, 2.0, 0.7, 0.7, 0.7))

    # Compose world
    world_sdf = f"""<?xml version="1.0" ?>
<sdf version="1.6">
  <world name="orion_warehouse">
    <include><uri>model://ground_plane</uri></include>
    <include><uri>model://sun</uri></include>

    <physics type="ode">
      <max_step_size>0.002</max_step_size>
      <real_time_factor>1.0</real_time_factor>
      <real_time_update_rate>500</real_time_update_rate>
      <ode>
        <solver>
          <type>quick</type>
          <iters>100</iters>
          <sor>1.3</sor>
        </solver>
        <constraints>
          <cfm>0.0</cfm>
          <erp>0.2</erp>
          <contact_max_correcting_vel>100.0</contact_max_correcting_vel>
          <contact_surface_layer>0.001</contact_surface_layer>
        </constraints>
      </ode>
    </physics>

    <scene>
      <ambient>0.6 0.6 0.6 1.0</ambient>
      <shadows>true</shadows>
    </scene>

    <!-- Floor -->
    <model name="warehouse_floor">
      <static>true</static>
      <pose>{cx} {cy} 0 0 0 0</pose>
      <link name="link">
        <collision name="col">
          <geometry><box><size>{wall_len_x} {wall_len_y} 0.01</size></box></geometry>
          <surface>
            <friction><ode><mu>1.0</mu><mu2>1.0</mu2></ode></friction>
          </surface>
        </collision>
        <visual name="vis">
          <geometry><box><size>{wall_len_x} {wall_len_y} 0.01</size></box></geometry>
          <material>
            <ambient>0.85 0.85 0.85 1.0</ambient>
            <diffuse>0.85 0.85 0.85 1.0</diffuse>
          </material>
        </visual>
      </link>
    </model>

{"".join(models)}
{"".join(lines)}

  </world>
</sdf>
"""

    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with open(output_path, 'w') as f:
        f.write(world_sdf)

    # Write RFID config
    rfid_cfg_path = os.path.join(os.path.dirname(output_path), '..', 'config', 'rfid_tags.yaml')
    os.makedirs(os.path.dirname(rfid_cfg_path), exist_ok=True)
    with open(rfid_cfg_path, 'w') as f:
        f.write("# Auto-generated RFID tag positions\nrfid_tags:\n")
        for tag_id, tx, ty in rfid_positions:
            shelf_name = tag_id.replace("RFID_", "")
            f.write(f"  - {{id: '{tag_id}', x: {tx}, y: {ty}, shelf: '{shelf_name}'}}\n")

    # Write warehouse layout config
    layout_path = os.path.join(os.path.dirname(output_path), '..', 'config', 'warehouse_layout.yaml')
    with open(layout_path, 'w') as f:
        f.write("# Auto-generated warehouse layout\n")
        f.write("warehouse:\n")
        f.write(f"  home: {{x: {home_x}, y: {home_y}}}\n")
        f.write(f"  num_aisles: {num_aisles}\n")
        f.write(f"  shelves_per_aisle: {shelves_per_aisle}\n")
        f.write(f"  aisle_spacing: {aisle_spacing}\n")
        f.write(f"  shelf_spacing: {shelf_spacing}\n")
        f.write(f"  aisle_start_x: {aisle_start_x}\n")
        f.write("  aisles:\n")
        for i in range(num_aisles):
            letter = chr(ord('A') + i)
            ax = aisle_start_x + i * aisle_spacing
            f.write(f"    - {{letter: '{letter}', x: {ax}, junction_index: {i+1}}}\n")

    print(f"World written to: {output_path}")
    print(f"RFID config: {rfid_cfg_path}")
    print(f"Layout config: {layout_path}")


def main():
    if len(sys.argv) > 1:
        out = sys.argv[1]
    else:
        out = os.path.expanduser("~/orion_ws/src/orion_world/worlds/orion_warehouse.world")
    generate_world(out)


if __name__ == '__main__':
    main()
PYEOF
log_ok "orion_world generator written"

# Run the generator now
log_info "Generating warehouse world file..."
mkdir -p "$WORLD_DIR/config"
python3 "$WORLD_DIR/orion_world/generate_world.py" "$WORLD_DIR/worlds/orion_warehouse.world"
log_ok "World file generated"


###############################################################################
# PHASE 6 — orion_core (All ROS2 nodes)
###############################################################################
log_phase "PHASE 6 — orion_core"
CORE_DIR="$ORION_SRC/orion_core"
mkdir -p "$CORE_DIR/orion_core"
mkdir -p "$CORE_DIR/config"
mkdir -p "$CORE_DIR/resource"
touch "$CORE_DIR/resource/orion_core"

cat > "$CORE_DIR/package.xml" <<'EOF'
<?xml version="1.0"?>
<package format="3">
  <name>orion_core</name>
  <version>1.0.0</version>
  <description>Orion AGV core nodes</description>
  <maintainer email="dev@orion.io">Orion</maintainer>
  <license>Apache-2.0</license>
  <buildtool_depend>ament_python</buildtool_depend>
  <depend>rclpy</depend>
  <depend>std_msgs</depend>
  <depend>geometry_msgs</depend>
  <depend>sensor_msgs</depend>
  <depend>nav_msgs</depend>
  <depend>tf2_ros</depend>
  <depend>orion_msgs</depend>
  <export><build_type>ament_python</build_type></export>
</package>
EOF

cat > "$CORE_DIR/setup.py" <<'EOF'
from setuptools import setup
import os
from glob import glob

package_name = 'orion_core'
setup(
    name=package_name,
    version='1.0.0',
    packages=[package_name],
    data_files=[
        ('share/ament_index/resource_index/packages', ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
        (os.path.join('share', package_name, 'config'), glob('config/*')),
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    entry_points={
        'console_scripts': [
            'mission_manager = orion_core.mission_manager:main',
            'line_controller = orion_core.line_controller:main',
            'turn_controller = orion_core.turn_controller:main',
            'pivot_controller = orion_core.pivot_controller:main',
            'optical_sensors = orion_core.optical_sensors:main',
            'rfid_scanner = orion_core.rfid_scanner:main',
            'send_mission = orion_core.send_mission:main',
            'monitor_node = orion_core.monitor_node:main',
            'orion_gui = orion_core.orion_gui:main',
        ],
    },
)
EOF

cat > "$CORE_DIR/setup.cfg" <<'EOF'
[develop]
script_dir=$base/lib/orion_core
[install]
install_scripts=$base/lib/orion_core
EOF

cat > "$CORE_DIR/orion_core/__init__.py" <<'EOF'
EOF


# --- optical_sensors.py: Virtual 8-IR sensor array ---
cat > "$CORE_DIR/orion_core/optical_sensors.py" <<'PYEOF'
#!/usr/bin/env python3
"""
Orion Virtual Optical Sensor Array
===================================
Simulates 8 IR line sensors using robot odometry and known line map.
No camera, no OpenCV — pure geometry.

Sensor Layout (looking from top, robot facing +X):
  Sensor indices and lateral offsets from center (meters):
    0: -0.105  (far left)
    1: -0.075
    2: -0.045
    3: -0.015  (inner left)
    4: +0.015  (inner right)
    5: +0.045
    6: +0.075
    7: +0.105  (far right)

  All sensors are mounted 0.22m forward of base_link center.
  Update rate: 50 Hz.
  Output: std_msgs/Int32MultiArray with 8 values (0=white, 1=black/line).
"""
import rclpy
from rclpy.node import Node
from std_msgs.msg import Int32MultiArray
from nav_msgs.msg import Odometry
import math
import yaml
import os


class OpticalSensors(Node):
    def __init__(self):
        super().__init__('optical_sensors', namespace='orion')

        self.sensor_pub = self.create_publisher(Int32MultiArray, 'line_sensors', 10)
        self.odom_sub = self.create_subscription(Odometry, 'odom', self.odom_cb, 10)

        self.timer = self.create_timer(1.0 / 50.0, self.update_sensors)

        # Sensor geometry
        self.sensor_forward_offset = 0.22
        self.sensor_lateral_offsets = [
            -0.105, -0.075, -0.045, -0.015,
             0.015,  0.045,  0.075,  0.105
        ]
        self.line_half_width = 0.04  # 8cm wide lines, half = 4cm

        # Robot pose from odom
        self.robot_x = 0.0
        self.robot_y = 0.0
        self.robot_yaw = 0.0
        self.odom_received = False

        # Line segments in world frame: list of (x1, y1, x2, y2)
        self.line_segments = []
        self._load_line_map()

        self.get_logger().info('Optical sensors initialized (8 virtual IR sensors @ 50Hz)')

    def _load_line_map(self):
        """Build line map from warehouse layout knowledge."""
        # Warehouse parameters (must match generate_world.py)
        home_x, home_y = 0.0, 0.0
        num_aisles = 5
        aisle_spacing = 3.0
        shelf_spacing = 2.0
        shelves_per_aisle = 4
        aisle_start_x = 3.0
        corridor_y = 0.0
        corridor_end_x = aisle_start_x + (num_aisles - 1) * aisle_spacing + 1.0

        # Main corridor
        self.line_segments.append((home_x + 0.4, corridor_y, corridor_end_x, corridor_y))

        # Aisle lines
        for i in range(num_aisles):
            ax = aisle_start_x + i * aisle_spacing
            aisle_end_y = shelves_per_aisle * shelf_spacing + 0.5
            self.line_segments.append((ax, corridor_y + 0.2, ax, aisle_end_y))

        # Return path
        self.line_segments.append((corridor_end_x, corridor_y, corridor_end_x, -1.0))
        self.line_segments.append((corridor_end_x, -1.0, home_x + 0.4, -1.0))
        self.line_segments.append((home_x + 0.4, -1.0, home_x + 0.4, corridor_y))

        self.get_logger().info(f'Loaded {len(self.line_segments)} line segments')

    def odom_cb(self, msg):
        self.robot_x = msg.pose.pose.position.x
        self.robot_y = msg.pose.pose.position.y
        q = msg.pose.pose.orientation
        siny = 2.0 * (q.w * q.z + q.x * q.y)
        cosy = 1.0 - 2.0 * (q.y * q.y + q.z * q.z)
        self.robot_yaw = math.atan2(siny, cosy)
        self.odom_received = True

    def _point_to_segment_dist(self, px, py, x1, y1, x2, y2):
        """Minimum distance from point (px,py) to segment (x1,y1)-(x2,y2)."""
        dx = x2 - x1
        dy = y2 - y1
        len_sq = dx * dx + dy * dy
        if len_sq < 1e-9:
            return math.sqrt((px - x1)**2 + (py - y1)**2)
        t = max(0.0, min(1.0, ((px - x1) * dx + (py - y1) * dy) / len_sq))
        proj_x = x1 + t * dx
        proj_y = y1 + t * dy
        return math.sqrt((px - proj_x)**2 + (py - proj_y)**2)

    def _sensor_detects_line(self, sx, sy):
        """Check if sensor at world position (sx, sy) is over a line."""
        for seg in self.line_segments:
            dist = self._point_to_segment_dist(sx, sy, *seg)
            if dist <= self.line_half_width:
                return True
        return False

    def update_sensors(self):
        if not self.odom_received:
            return

        cos_yaw = math.cos(self.robot_yaw)
        sin_yaw = math.sin(self.robot_yaw)

        readings = []
        for lat_offset in self.sensor_lateral_offsets:
            # Sensor position in robot frame: (forward_offset, lat_offset)
            # Transform to world frame
            sx = self.robot_x + cos_yaw * self.sensor_forward_offset - sin_yaw * lat_offset
            sy = self.robot_y + sin_yaw * self.sensor_forward_offset + cos_yaw * lat_offset
            readings.append(1 if self._sensor_detects_line(sx, sy) else 0)

        msg = Int32MultiArray()
        msg.data = readings
        self.sensor_pub.publish(msg)


def main(args=None):
    rclpy.init(args=args)
    node = OpticalSensors()
    rclpy.spin(node)
    node.destroy_node()
    rclpy.shutdown()


if __name__ == '__main__':
    main()
PYEOF
log_ok "optical_sensors.py written"


# --- line_controller.py: PID line follower ---
cat > "$CORE_DIR/orion_core/line_controller.py" <<'PYEOF'
#!/usr/bin/env python3
"""
Orion Line Controller
======================
PID-based line following using the 8-sensor array.
Publishes to /orion/follow_vel (NOT cmd_vel — arbiter pattern).

PID Parameters:
  linear_speed = 0.50 m/s
  Kp = 0.50
  Ki = 0.00
  Kd = 0.15

Junction Detection:
  threshold = 5 sensors active
  confirm_frames = 2
  cooldown = 1.5 seconds
"""
import rclpy
from rclpy.node import Node
from std_msgs.msg import Int32MultiArray, Bool, Int32
from geometry_msgs.msg import Twist
import time


class LineController(Node):
    def __init__(self):
        super().__init__('line_controller', namespace='orion')

        # Publishers
        self.vel_pub = self.create_publisher(Twist, 'follow_vel', 10)
        self.junction_pub = self.create_publisher(Bool, 'junction_detected', 10)
        self.junction_count_pub = self.create_publisher(Int32, 'junction_count', 10)

        # Subscribers
        self.sensor_sub = self.create_subscription(
            Int32MultiArray, 'line_sensors', self.sensor_cb, 10)

        # PID parameters
        self.linear_speed = 0.50
        self.kp = 0.50
        self.ki = 0.00
        self.kd = 0.15

        # PID state
        self.prev_error = 0.0
        self.integral = 0.0

        # Junction detection
        self.junction_threshold = 5
        self.junction_confirm_frames = 2
        self.junction_cooldown = 1.5
        self.junction_count = 0
        self.junction_confirm_counter = 0
        self.last_junction_time = 0.0

        # Enable/disable
        self.enabled = False

        # Service-like topic to enable/disable
        self.enable_sub = self.create_subscription(
            Bool, 'line_follow_enable', self.enable_cb, 10)

        # Sensor weights for error calculation (normalized positions)
        # Positions: -3.5, -2.5, -1.5, -0.5, +0.5, +1.5, +2.5, +3.5
        self.sensor_weights = [-3.5, -2.5, -1.5, -0.5, 0.5, 1.5, 2.5, 3.5]

        self.get_logger().info('Line controller ready (PID: Kp=0.50, Ki=0.00, Kd=0.15)')

    def enable_cb(self, msg):
        self.enabled = msg.data
        if not self.enabled:
            self._stop()
        self.get_logger().info(f'Line following {"ENABLED" if self.enabled else "DISABLED"}')

    def _stop(self):
        cmd = Twist()
        self.vel_pub.publish(cmd)

    def sensor_cb(self, msg):
        if not self.enabled:
            return

        sensors = list(msg.data)
        if len(sensors) != 8:
            return

        active_count = sum(sensors)
        now = time.time()

        # Junction detection
        if active_count >= self.junction_threshold:
            self.junction_confirm_counter += 1
            if (self.junction_confirm_counter >= self.junction_confirm_frames and
                    (now - self.last_junction_time) > self.junction_cooldown):
                self.junction_count += 1
                self.last_junction_time = now
                jmsg = Bool()
                jmsg.data = True
                self.junction_pub.publish(jmsg)
                cmsg = Int32()
                cmsg.data = self.junction_count
                self.junction_count_pub.publish(cmsg)
                self.get_logger().info(f'JUNCTION #{self.junction_count} detected')
        else:
            self.junction_confirm_counter = 0

        # Line error calculation (weighted average)
        if active_count == 0:
            # Lost line — use last error direction to try to recover
            error = self.prev_error * 1.5
        else:
            weighted_sum = sum(w * s for w, s in zip(self.sensor_weights, sensors))
            error = weighted_sum / active_count
            # Normalize to [-1, 1] range (max possible is 3.5)
            error = error / 3.5

        # PID computation
        self.integral += error
        derivative = error - self.prev_error
        angular_z = self.kp * error + self.ki * self.integral + self.kd * derivative
        self.prev_error = error

        # Clamp angular velocity
        angular_z = max(-1.5, min(1.5, angular_z))

        # Reduce speed in curves
        speed = self.linear_speed * (1.0 - 0.3 * abs(angular_z))

        cmd = Twist()
        cmd.linear.x = speed
        cmd.angular.z = angular_z
        self.vel_pub.publish(cmd)

    def reset_junction_count(self):
        self.junction_count = 0
        self.junction_confirm_counter = 0


def main(args=None):
    rclpy.init(args=args)
    node = LineController()
    rclpy.spin(node)
    node.destroy_node()
    rclpy.shutdown()


if __name__ == '__main__':
    main()
PYEOF
log_ok "line_controller.py written"


# --- turn_controller.py: IMU-based 90° turns ---
cat > "$CORE_DIR/orion_core/turn_controller.py" <<'PYEOF'
#!/usr/bin/env python3
"""
Orion Turn Controller
======================
IMU-based yaw-controlled 90-degree turns.
Publishes to /orion/turn_vel (arbiter pattern).

Parameters:
  angular_speed = 0.5 rad/s
  tolerance = 3 degrees (0.0523 rad)
"""
import rclpy
from rclpy.node import Node
from geometry_msgs.msg import Twist
from sensor_msgs.msg import Imu
from std_msgs.msg import Float32, Bool, String
import math


class TurnController(Node):
    def __init__(self):
        super().__init__('turn_controller', namespace='orion')

        self.vel_pub = self.create_publisher(Twist, 'turn_vel', 10)
        self.done_pub = self.create_publisher(Bool, 'turn_done', 10)

        self.imu_sub = self.create_subscription(Imu, 'imu/data', self.imu_cb, 10)
        self.cmd_sub = self.create_subscription(String, 'turn_command', self.cmd_cb, 10)

        self.angular_speed = 0.5
        self.tolerance = math.radians(3.0)

        self.current_yaw = 0.0
        self.target_yaw = None
        self.turning = False
        self.turn_direction = 1.0  # +1 = CCW (left), -1 = CW (right)

        self.timer = self.create_timer(0.02, self.control_loop)  # 50Hz

        self.get_logger().info('Turn controller ready (tol=3deg, omega=0.5rad/s)')

    def imu_cb(self, msg):
        q = msg.orientation
        siny = 2.0 * (q.w * q.z + q.x * q.y)
        cosy = 1.0 - 2.0 * (q.y * q.y + q.z * q.z)
        self.current_yaw = math.atan2(siny, cosy)

    def cmd_cb(self, msg):
        """
        Commands: "LEFT", "RIGHT", "LEFT_180", "RIGHT_180"
        LEFT  = +90 degrees (CCW)
        RIGHT = -90 degrees (CW)
        """
        cmd = msg.data.upper().strip()
        if cmd == 'LEFT':
            angle = math.pi / 2.0
            self.turn_direction = 1.0
        elif cmd == 'RIGHT':
            angle = math.pi / 2.0
            self.turn_direction = -1.0
        elif cmd in ('LEFT_180', 'PIVOT'):
            angle = math.pi
            self.turn_direction = 1.0
        elif cmd == 'RIGHT_180':
            angle = math.pi
            self.turn_direction = -1.0
        else:
            self.get_logger().warn(f'Unknown turn command: {cmd}')
            return

        self.target_yaw = self._normalize_angle(
            self.current_yaw + self.turn_direction * angle)
        self.turning = True
        self.get_logger().info(
            f'Turn started: {cmd}, target_yaw={math.degrees(self.target_yaw):.1f}°')

    def _normalize_angle(self, angle):
        while angle > math.pi:
            angle -= 2.0 * math.pi
        while angle < -math.pi:
            angle += 2.0 * math.pi
        return angle

    def control_loop(self):
        if not self.turning or self.target_yaw is None:
            return

        error = self._normalize_angle(self.target_yaw - self.current_yaw)

        if abs(error) < self.tolerance:
            # Turn complete
            cmd = Twist()
            self.vel_pub.publish(cmd)
            self.turning = False
            self.target_yaw = None

            done_msg = Bool()
            done_msg.data = True
            self.done_pub.publish(done_msg)
            self.get_logger().info('Turn COMPLETE')
            return

        # Rotate at fixed speed in correct direction
        cmd = Twist()
        cmd.angular.z = self.angular_speed * (1.0 if error > 0 else -1.0)
        self.vel_pub.publish(cmd)


def main(args=None):
    rclpy.init(args=args)
    node = TurnController()
    rclpy.spin(node)
    node.destroy_node()
    rclpy.shutdown()


if __name__ == '__main__':
    main()
PYEOF
log_ok "turn_controller.py written"


# --- pivot_controller.py: 180° pivot + nudge ---
cat > "$CORE_DIR/orion_core/pivot_controller.py" <<'PYEOF'
#!/usr/bin/env python3
"""
Orion Pivot Controller
=======================
IMU-controlled 180-degree pivot for return maneuver.
After pivot completes, drives forward ~15cm (PIVOT_NUDGE state).
Publishes to /orion/pivot_vel (arbiter pattern).
"""
import rclpy
from rclpy.node import Node
from geometry_msgs.msg import Twist
from sensor_msgs.msg import Imu
from nav_msgs.msg import Odometry
from std_msgs.msg import Bool, String
import math


class PivotController(Node):
    def __init__(self):
        super().__init__('pivot_controller', namespace='orion')

        self.vel_pub = self.create_publisher(Twist, 'pivot_vel', 10)
        self.done_pub = self.create_publisher(Bool, 'pivot_done', 10)
        self.nudge_done_pub = self.create_publisher(Bool, 'nudge_done', 10)

        self.imu_sub = self.create_subscription(Imu, 'imu/data', self.imu_cb, 10)
        self.odom_sub = self.create_subscription(Odometry, 'odom', self.odom_cb, 10)
        self.cmd_sub = self.create_subscription(String, 'pivot_command', self.cmd_cb, 10)

        self.angular_speed = 0.5
        self.tolerance = math.radians(3.0)
        self.nudge_distance = 0.15  # 15 cm
        self.nudge_speed = 0.25

        self.current_yaw = 0.0
        self.robot_x = 0.0
        self.robot_y = 0.0

        self.target_yaw = None
        self.pivoting = False
        self.nudging = False
        self.nudge_start_x = 0.0
        self.nudge_start_y = 0.0

        self.timer = self.create_timer(0.02, self.control_loop)

        self.get_logger().info('Pivot controller ready')

    def imu_cb(self, msg):
        q = msg.orientation
        siny = 2.0 * (q.w * q.z + q.x * q.y)
        cosy = 1.0 - 2.0 * (q.y * q.y + q.z * q.z)
        self.current_yaw = math.atan2(siny, cosy)

    def odom_cb(self, msg):
        self.robot_x = msg.pose.pose.position.x
        self.robot_y = msg.pose.pose.position.y

    def cmd_cb(self, msg):
        cmd = msg.data.upper().strip()
        if cmd == 'PIVOT':
            self.target_yaw = self._normalize(self.current_yaw + math.pi)
            self.pivoting = True
            self.nudging = False
            self.get_logger().info('180° PIVOT started')
        elif cmd == 'NUDGE':
            self.nudge_start_x = self.robot_x
            self.nudge_start_y = self.robot_y
            self.nudging = True
            self.pivoting = False
            self.get_logger().info('NUDGE forward started (15cm)')

    def _normalize(self, a):
        while a > math.pi:
            a -= 2.0 * math.pi
        while a < -math.pi:
            a += 2.0 * math.pi
        return a

    def control_loop(self):
        if self.pivoting:
            error = self._normalize(self.target_yaw - self.current_yaw)
            if abs(error) < self.tolerance:
                cmd = Twist()
                self.vel_pub.publish(cmd)
                self.pivoting = False
                done = Bool()
                done.data = True
                self.done_pub.publish(done)
                self.get_logger().info('PIVOT complete')
                return
            cmd = Twist()
            cmd.angular.z = self.angular_speed * (1.0 if error > 0 else -1.0)
            self.vel_pub.publish(cmd)

        elif self.nudging:
            dx = self.robot_x - self.nudge_start_x
            dy = self.robot_y - self.nudge_start_y
            dist = math.sqrt(dx*dx + dy*dy)
            if dist >= self.nudge_distance:
                cmd = Twist()
                self.vel_pub.publish(cmd)
                self.nudging = False
                done = Bool()
                done.data = True
                self.nudge_done_pub.publish(done)
                self.get_logger().info('NUDGE complete')
                return
            cmd = Twist()
            cmd.linear.x = self.nudge_speed
            self.vel_pub.publish(cmd)


def main(args=None):
    rclpy.init(args=args)
    node = PivotController()
    rclpy.spin(node)
    node.destroy_node()
    rclpy.shutdown()


if __name__ == '__main__':
    main()
PYEOF
log_ok "pivot_controller.py written"


# --- rfid_scanner.py: Simulated RFID tag detection ---
cat > "$CORE_DIR/orion_core/rfid_scanner.py" <<'PYEOF'
#!/usr/bin/env python3
"""
Orion RFID Scanner
===================
Simulates RFID shelf markers using robot position and known tag locations.

Parameters:
  detection_radius = 0.60m
  rearm_distance   = 0.90m

Publishes RFIDEvent messages to /orion/rfid_event.
Guarantees no missed tags at 0.50 m/s travel speed (50Hz check rate).
"""
import rclpy
from rclpy.node import Node
from nav_msgs.msg import Odometry
from orion_msgs.msg import RFIDEvent
from builtin_interfaces.msg import Time
import math
import yaml
import os


class RFIDScanner(Node):
    def __init__(self):
        super().__init__('rfid_scanner', namespace='orion')

        self.rfid_pub = self.create_publisher(RFIDEvent, 'rfid_event', 10)
        self.odom_sub = self.create_subscription(Odometry, 'odom', self.odom_cb, 10)

        self.detection_radius = 0.60
        self.rearm_distance = 0.90

        self.robot_x = 0.0
        self.robot_y = 0.0

        # Tag states: dict of tag_id -> {'active': bool, 'last_exit_x': float, ...}
        self.tag_states = {}
        self.tags = []  # list of {id, x, y, shelf}

        self._load_tags()

        self.timer = self.create_timer(1.0 / 50.0, self.scan_loop)
        self.get_logger().info(f'RFID scanner ready: {len(self.tags)} tags loaded')

    def _load_tags(self):
        """Load RFID tag positions from known warehouse layout."""
        # Replicate what generate_world produces
        num_aisles = 5
        aisle_spacing = 3.0
        shelf_spacing = 2.0
        shelves_per_aisle = 4
        aisle_start_x = 3.0

        for aisle_idx in range(num_aisles):
            aisle_x = aisle_start_x + aisle_idx * aisle_spacing
            aisle_letter = chr(ord('A') + aisle_idx)
            for shelf_idx in range(shelves_per_aisle):
                shelf_y = (shelf_idx + 1) * shelf_spacing
                shelf_l = f"{aisle_letter}{shelf_idx*2+1}"
                shelf_r = f"{aisle_letter}{shelf_idx*2+2}"
                self.tags.append({'id': f'RFID_{shelf_l}', 'x': aisle_x, 'y': shelf_y, 'shelf': shelf_l})
                self.tags.append({'id': f'RFID_{shelf_r}', 'x': aisle_x, 'y': shelf_y, 'shelf': shelf_r})
                self.tag_states[f'RFID_{shelf_l}'] = {'active': False, 'armed': True}
                self.tag_states[f'RFID_{shelf_r}'] = {'active': False, 'armed': True}

    def odom_cb(self, msg):
        self.robot_x = msg.pose.pose.position.x
        self.robot_y = msg.pose.pose.position.y

    def scan_loop(self):
        for tag in self.tags:
            dx = self.robot_x - tag['x']
            dy = self.robot_y - tag['y']
            dist = math.sqrt(dx*dx + dy*dy)
            state = self.tag_states[tag['id']]

            if dist <= self.detection_radius and not state['active'] and state['armed']:
                # ENTER event
                state['active'] = True
                state['armed'] = False
                self._publish_event(tag, 'ENTER', dist)
                self.get_logger().info(f"RFID ENTER: {tag['id']} (shelf={tag['shelf']})")

            elif dist > self.detection_radius and state['active']:
                # EXIT event
                state['active'] = False
                self._publish_event(tag, 'EXIT', dist)

            elif dist > self.rearm_distance and not state['armed'] and not state['active']:
                # Rearm
                state['armed'] = True

    def _publish_event(self, tag, event_type, dist):
        msg = RFIDEvent()
        msg.tag_id = tag['id']
        msg.event = event_type
        msg.shelf_id = tag['shelf']
        msg.distance = float(dist)
        now = self.get_clock().now().to_msg()
        msg.stamp = now
        self.rfid_pub.publish(msg)


def main(args=None):
    rclpy.init(args=args)
    node = RFIDScanner()
    rclpy.spin(node)
    node.destroy_node()
    rclpy.shutdown()


if __name__ == '__main__':
    main()
PYEOF
log_ok "rfid_scanner.py written"


# --- mission_manager.py: FSM + velocity arbiter (SOLE cmd_vel publisher) ---
cat > "$CORE_DIR/orion_core/mission_manager.py" <<'PYEOF'
#!/usr/bin/env python3
"""
Orion Mission Manager
======================
Central FSM controller and SOLE velocity arbiter.
Only this node publishes to /orion/cmd_vel.

States:
  IDLE -> NAVIGATING -> TURNING -> NAVIGATING -> AT_SHELF ->
  LOADING -> PIVOTING -> PIVOT_NUDGE -> RETURNING -> DOCKED -> IDLE

Transitions:
  IDLE       + mission_received    -> NAVIGATING
  NAVIGATING + junction_at_aisle   -> TURNING
  TURNING    + turn_complete       -> NAVIGATING
  NAVIGATING + rfid_shelf_reached  -> AT_SHELF
  AT_SHELF   + load_timer_done     -> LOADING
  LOADING    + load_complete       -> PIVOTING
  PIVOTING   + pivot_complete      -> PIVOT_NUDGE
  PIVOT_NUDGE + nudge_complete     -> RETURNING
  RETURNING  + home_reached        -> DOCKED
  DOCKED     + dock_timer          -> IDLE
  ANY        + estop               -> ERROR
  ERROR      + reset               -> IDLE

Velocity arbiter: subscribes to follow_vel, turn_vel, pivot_vel
  and forwards the appropriate one to cmd_vel based on current state.
"""
import rclpy
from rclpy.node import Node
from geometry_msgs.msg import Twist
from std_msgs.msg import Bool, String, Int32
from nav_msgs.msg import Odometry
from orion_msgs.msg import Mission, RFIDEvent, RobotStatus
import math
import time
import uuid
from collections import deque


class MissionManager(Node):
    # Valid states
    STATES = ['IDLE', 'NAVIGATING', 'TURNING', 'AT_SHELF',
              'LOADING', 'PIVOTING', 'PIVOT_NUDGE', 'RETURNING', 'DOCKED', 'ERROR']

    # Valid transitions: from_state -> set of allowed to_states
    TRANSITIONS = {
        'IDLE':       {'NAVIGATING', 'ERROR'},
        'NAVIGATING': {'TURNING', 'AT_SHELF', 'RETURNING', 'ERROR', 'IDLE'},
        'TURNING':    {'NAVIGATING', 'ERROR'},
        'AT_SHELF':   {'LOADING', 'ERROR'},
        'LOADING':    {'PIVOTING', 'ERROR'},
        'PIVOTING':   {'PIVOT_NUDGE', 'ERROR'},
        'PIVOT_NUDGE':{'RETURNING', 'ERROR'},
        'RETURNING':  {'DOCKED', 'ERROR', 'IDLE'},
        'DOCKED':     {'IDLE', 'ERROR'},
        'ERROR':      {'IDLE'},
    }

    def __init__(self):
        super().__init__('mission_manager', namespace='orion')

        # --- Publishers ---
        self.cmd_vel_pub = self.create_publisher(Twist, 'cmd_vel', 10)
        self.status_pub = self.create_publisher(RobotStatus, 'robot_status', 10)
        self.line_enable_pub = self.create_publisher(Bool, 'line_follow_enable', 10)
        self.turn_cmd_pub = self.create_publisher(String, 'turn_command', 10)
        self.pivot_cmd_pub = self.create_publisher(String, 'pivot_command', 10)

        # --- Subscribers (velocity inputs from sub-controllers) ---
        self.follow_vel = Twist()
        self.turn_vel = Twist()
        self.pivot_vel = Twist()

        self.create_subscription(Twist, 'follow_vel', self._follow_vel_cb, 10)
        self.create_subscription(Twist, 'turn_vel', self._turn_vel_cb, 10)
        self.create_subscription(Twist, 'pivot_vel', self._pivot_vel_cb, 10)

        # --- Subscribers (events) ---
        self.create_subscription(Mission, 'mission_input', self._mission_cb, 10)
        self.create_subscription(Bool, 'junction_detected', self._junction_cb, 10)
        self.create_subscription(Int32, 'junction_count', self._jcount_cb, 10)
        self.create_subscription(RFIDEvent, 'rfid_event', self._rfid_cb, 10)
        self.create_subscription(Bool, 'turn_done', self._turn_done_cb, 10)
        self.create_subscription(Bool, 'pivot_done', self._pivot_done_cb, 10)
        self.create_subscription(Bool, 'nudge_done', self._nudge_done_cb, 10)
        self.create_subscription(Odometry, 'odom', self._odom_cb, 10)

        # --- State ---
        self.state = 'IDLE'
        self.mission_id = ''
        self.target_shelf = ''
        self.current_sku = ''
        self.last_rfid = ''
        self.carrying_load = False
        self.battery_percent = 100.0

        self.mission_queue = deque()
        self.junction_count = 0
        self.target_aisle_junction = 0
        self.target_shelf_number = 0
        self.robot_x = 0.0
        self.robot_y = 0.0
        self.home_x = 0.0
        self.home_y = 0.0
        self.home_threshold = 0.5

        self.load_start_time = 0.0
        self.load_duration = 3.0  # seconds to simulate loading
        self.dock_start_time = 0.0
        self.dock_duration = 2.0

        self.navigating_to_aisle = True  # True = going to aisle, False = in aisle

        # Warehouse layout
        self.aisle_letters = ['A', 'B', 'C', 'D', 'E']
        self.aisle_start_x = 3.0
        self.aisle_spacing = 3.0

        # --- Timers ---
        self.arbiter_timer = self.create_timer(0.02, self._arbiter_loop)  # 50Hz
        self.status_timer = self.create_timer(0.2, self._publish_status)  # 5Hz
        self.state_timer = self.create_timer(0.1, self._state_machine_tick)

        self.get_logger().info('Mission Manager initialized — SOLE velocity authority')

    # --- Velocity callbacks ---
    def _follow_vel_cb(self, msg): self.follow_vel = msg
    def _turn_vel_cb(self, msg): self.turn_vel = msg
    def _pivot_vel_cb(self, msg): self.pivot_vel = msg

    def _odom_cb(self, msg):
        self.robot_x = msg.pose.pose.position.x
        self.robot_y = msg.pose.pose.position.y

    # --- Velocity Arbiter: forwards appropriate vel to cmd_vel ---
    def _arbiter_loop(self):
        cmd = Twist()
        if self.state == 'NAVIGATING' or self.state == 'RETURNING':
            cmd = self.follow_vel
        elif self.state == 'TURNING':
            cmd = self.turn_vel
        elif self.state in ('PIVOTING', 'PIVOT_NUDGE'):
            cmd = self.pivot_vel
        # All other states: zero velocity (stop)
        self.cmd_vel_pub.publish(cmd)

    # --- State transition with validation ---
    def _transition(self, new_state):
        if new_state not in self.TRANSITIONS.get(self.state, set()):
            self.get_logger().error(
                f'INVALID transition: {self.state} -> {new_state}')
            return False
        self.get_logger().info(f'STATE: {self.state} -> {new_state}')
        self.state = new_state
        return True

    # --- Mission input ---
    def _mission_cb(self, msg):
        if msg.action == 'ESTOP':
            self._emergency_stop()
            return
        if msg.action == 'RESET':
            self._reset()
            return
        if msg.action == 'ABORT':
            self._abort_current()
            return

        if msg.action == 'PICKUP':
            mission = {
                'id': msg.mission_id if msg.mission_id else str(uuid.uuid4())[:8],
                'shelf': msg.target_shelf,
                'sku': msg.sku,
                'priority': msg.priority,
            }
            self.mission_queue.append(mission)
            self.get_logger().info(f'Mission queued: shelf={msg.target_shelf} sku={msg.sku}')

        elif msg.action == 'RETURN':
            if self.state != 'IDLE':
                self.get_logger().warn('Cannot RETURN — not IDLE')
                return
            self._start_return()

    def _parse_shelf(self, shelf_str):
        """Parse shelf like 'A3' -> aisle_index=0, shelf_num=3"""
        if len(shelf_str) < 2:
            return None, None
        letter = shelf_str[0].upper()
        try:
            num = int(shelf_str[1:])
        except ValueError:
            return None, None
        if letter not in self.aisle_letters:
            return None, None
        aisle_idx = self.aisle_letters.index(letter)
        return aisle_idx, num

    # --- State machine tick ---
    def _state_machine_tick(self):
        if self.state == 'IDLE':
            if self.mission_queue:
                self._start_next_mission()

        elif self.state == 'LOADING':
            if time.time() - self.load_start_time >= self.load_duration:
                self.carrying_load = True
                self.get_logger().info('Loading COMPLETE — starting pivot')
                self._disable_line_follow()
                self._transition('PIVOTING')
                self._send_pivot('PIVOT')

        elif self.state == 'DOCKED':
            if time.time() - self.dock_start_time >= self.dock_duration:
                self.carrying_load = False
                self.current_sku = ''
                self.target_shelf = ''
                self.mission_id = ''
                self._transition('IDLE')
                self.get_logger().info('DOCKED complete -> IDLE')

        elif self.state == 'RETURNING':
            dist_home = math.sqrt(
                (self.robot_x - self.home_x)**2 +
                (self.robot_y - self.home_y)**2)
            if dist_home < self.home_threshold:
                self._disable_line_follow()
                self._stop_robot()
                self.dock_start_time = time.time()
                self._transition('DOCKED')
                self.get_logger().info('HOME reached — DOCKED')

    def _start_next_mission(self):
        mission = self.mission_queue.popleft()
        self.mission_id = mission['id']
        self.target_shelf = mission['shelf']
        self.current_sku = mission['sku']

        aisle_idx, shelf_num = self._parse_shelf(self.target_shelf)
        if aisle_idx is None:
            self.get_logger().error(f"Invalid shelf: {self.target_shelf}")
            return

        self.target_aisle_junction = aisle_idx + 1  # junctions are 1-indexed
        self.target_shelf_number = shelf_num
        self.junction_count = 0
        self.navigating_to_aisle = True

        self._transition('NAVIGATING')
        self._enable_line_follow()
        self.get_logger().info(
            f'Mission START: {self.mission_id} -> shelf {self.target_shelf}')

    def _start_return(self):
        self._transition('NAVIGATING')
        self.navigating_to_aisle = False
        self._enable_line_follow()

    # --- Event handlers ---
    def _junction_cb(self, msg):
        pass  # Junction count handled by _jcount_cb

    def _jcount_cb(self, msg):
        self.junction_count = msg.data
        if self.state == 'NAVIGATING' and self.navigating_to_aisle:
            if self.junction_count == self.target_aisle_junction:
                self.get_logger().info(
                    f'Target aisle junction reached (#{self.junction_count})')
                self._disable_line_follow()
                self._stop_robot()
                self._transition('TURNING')
                self._send_turn('LEFT')

    def _rfid_cb(self, msg):
        if msg.event != 'ENTER':
            return
        self.last_rfid = msg.tag_id
        target_tag = f'RFID_{self.target_shelf}'
        if self.state == 'NAVIGATING' and not self.navigating_to_aisle:
            # In aisle, check if this is our target
            if msg.tag_id == target_tag or msg.shelf_id == self.target_shelf:
                self.get_logger().info(f'TARGET SHELF REACHED: {self.target_shelf}')
                self._disable_line_follow()
                self._stop_robot()
                self._transition('AT_SHELF')
                self.load_start_time = time.time()
                self._transition('LOADING')
                self.get_logger().info('LOADING started...')

    def _turn_done_cb(self, msg):
        if msg.data and self.state == 'TURNING':
            self.get_logger().info('Turn complete -> NAVIGATING in aisle')
            self.navigating_to_aisle = False
            self._transition('NAVIGATING')
            self._enable_line_follow()

    def _pivot_done_cb(self, msg):
        if msg.data and self.state == 'PIVOTING':
            self.get_logger().info('Pivot complete -> PIVOT_NUDGE')
            self._transition('PIVOT_NUDGE')
            self._send_pivot('NUDGE')

    def _nudge_done_cb(self, msg):
        if msg.data and self.state == 'PIVOT_NUDGE':
            self.get_logger().info('Nudge complete -> RETURNING')
            self._transition('RETURNING')
            self._enable_line_follow()

    # --- Helpers ---
    def _enable_line_follow(self):
        msg = Bool()
        msg.data = True
        self.line_enable_pub.publish(msg)

    def _disable_line_follow(self):
        msg = Bool()
        msg.data = False
        self.line_enable_pub.publish(msg)

    def _stop_robot(self):
        self.cmd_vel_pub.publish(Twist())

    def _send_turn(self, direction):
        msg = String()
        msg.data = direction
        self.turn_cmd_pub.publish(msg)

    def _send_pivot(self, command):
        msg = String()
        msg.data = command
        self.pivot_cmd_pub.publish(msg)

    def _emergency_stop(self):
        self._disable_line_follow()
        self._stop_robot()
        self.state = 'ERROR'
        self.get_logger().error('EMERGENCY STOP ACTIVATED')

    def _reset(self):
        self._stop_robot()
        self._disable_line_follow()
        self.state = 'IDLE'
        self.mission_queue.clear()
        self.mission_id = ''
        self.target_shelf = ''
        self.current_sku = ''
        self.carrying_load = False
        self.junction_count = 0
        self.get_logger().info('SYSTEM RESET -> IDLE')

    def _abort_current(self):
        self._disable_line_follow()
        self._stop_robot()
        self.state = 'IDLE'
        self.mission_id = ''
        self.get_logger().warn('Mission ABORTED')

    # --- Status publisher ---
    def _publish_status(self):
        msg = RobotStatus()
        msg.state = self.state
        msg.mission_id = self.mission_id
        msg.target_shelf = self.target_shelf
        msg.current_sku = self.current_sku
        msg.last_rfid = self.last_rfid
        msg.carrying_load = self.carrying_load
        msg.battery_percent = self.battery_percent
        self.status_pub.publish(msg)

        # Simulate battery drain
        if self.state not in ('IDLE', 'DOCKED', 'ERROR'):
            self.battery_percent = max(0.0, self.battery_percent - 0.01)


def main(args=None):
    rclpy.init(args=args)
    node = MissionManager()
    rclpy.spin(node)
    node.destroy_node()
    rclpy.shutdown()


if __name__ == '__main__':
    main()
PYEOF
log_ok "mission_manager.py written"


# --- send_mission.py: CLI tool ---
cat > "$CORE_DIR/orion_core/send_mission.py" <<'PYEOF'
#!/usr/bin/env python3
"""
Orion Mission Sender (CLI)
============================
Usage:
  ros2 run orion_core send_mission A3
  ros2 run orion_core send_mission B7 --sku WIDGET-42
  ros2 run orion_core send_mission --estop
  ros2 run orion_core send_mission --reset
  ros2 run orion_core send_mission --return
"""
import sys
import uuid
import rclpy
from rclpy.node import Node
from orion_msgs.msg import Mission


VALID_AISLES = ['A', 'B', 'C', 'D', 'E']
MAX_SHELF = 8  # 4 shelves/side * 2 sides = 8 per aisle


class MissionSender(Node):
    def __init__(self):
        super().__init__('mission_sender', namespace='orion')
        self.pub = self.create_publisher(Mission, 'mission_input', 10)
        # Wait for publisher to establish
        self.create_timer(0.5, self._send_and_exit)
        self.sent = False

    def _send_and_exit(self):
        if self.sent:
            rclpy.shutdown()
            return
        self.sent = True

        args = sys.argv[1:]
        msg = Mission()

        if '--estop' in args:
            msg.action = 'ESTOP'
            msg.mission_id = 'ESTOP'
        elif '--reset' in args:
            msg.action = 'RESET'
            msg.mission_id = 'RESET'
        elif '--return' in args:
            msg.action = 'RETURN'
            msg.mission_id = 'RETURN'
        elif '--abort' in args:
            msg.action = 'ABORT'
            msg.mission_id = 'ABORT'
        elif len(args) >= 1 and not args[0].startswith('--'):
            shelf = args[0].upper()
            if not self._validate_shelf(shelf):
                self.get_logger().error(
                    f'Invalid shelf "{shelf}". Format: A1-E8 (aisles A-E, shelves 1-8)')
                rclpy.shutdown()
                return
            msg.action = 'PICKUP'
            msg.target_shelf = shelf
            msg.mission_id = str(uuid.uuid4())[:8]
            msg.sku = ''
            msg.priority = 1
            # Check for --sku flag
            if '--sku' in args:
                idx = args.index('--sku')
                if idx + 1 < len(args):
                    msg.sku = args[idx + 1]
        else:
            print("Usage: ros2 run orion_core send_mission <SHELF>")
            print("       ros2 run orion_core send_mission A3 --sku ITEM-1")
            print("       ros2 run orion_core send_mission --estop")
            print("       ros2 run orion_core send_mission --reset")
            print("       ros2 run orion_core send_mission --return")
            rclpy.shutdown()
            return

        self.pub.publish(msg)
        self.get_logger().info(f'Sent: action={msg.action} shelf={msg.target_shelf} sku={msg.sku}')
        self.create_timer(0.5, lambda: rclpy.shutdown())

    def _validate_shelf(self, shelf):
        if len(shelf) < 2:
            return False
        if shelf[0] not in VALID_AISLES:
            return False
        try:
            num = int(shelf[1:])
            return 1 <= num <= MAX_SHELF
        except ValueError:
            return False


def main(args=None):
    rclpy.init(args=args)
    node = MissionSender()
    rclpy.spin(node)
    node.destroy_node()


if __name__ == '__main__':
    main()
PYEOF
log_ok "send_mission.py written"


# --- monitor_node.py: Health monitoring ---
cat > "$CORE_DIR/orion_core/monitor_node.py" <<'PYEOF'
#!/usr/bin/env python3
"""
Orion Monitor Node
===================
Provides heartbeat monitoring, node health checks, topic verification,
mission logging, and console diagnostics.
"""
import rclpy
from rclpy.node import Node
from orion_msgs.msg import RobotStatus, RFIDEvent
from std_msgs.msg import Bool, Int32
from geometry_msgs.msg import Twist
import time


class MonitorNode(Node):
    def __init__(self):
        super().__init__('monitor_node', namespace='orion')

        # Track last message times
        self.last_status_time = 0.0
        self.last_cmd_vel_time = 0.0
        self.last_sensor_time = 0.0
        self.status_count = 0
        self.mission_log = []

        self.create_subscription(RobotStatus, 'robot_status', self._status_cb, 10)
        self.create_subscription(Twist, 'cmd_vel', self._cmdvel_cb, 10)
        self.create_subscription(RFIDEvent, 'rfid_event', self._rfid_cb, 10)

        # Heartbeat check every 5 seconds
        self.create_timer(5.0, self._heartbeat_check)
        # Diagnostic report every 30 seconds
        self.create_timer(30.0, self._diagnostic_report)

        self.current_state = 'UNKNOWN'
        self.get_logger().info('Monitor node active')

    def _status_cb(self, msg):
        self.last_status_time = time.time()
        self.status_count += 1
        if msg.state != self.current_state:
            self.current_state = msg.state
            self.get_logger().info(f'[MONITOR] State changed: {msg.state}')
            self.mission_log.append({
                'time': time.time(),
                'event': 'state_change',
                'state': msg.state,
                'mission': msg.mission_id,
                'shelf': msg.target_shelf
            })

    def _cmdvel_cb(self, msg):
        self.last_cmd_vel_time = time.time()

    def _rfid_cb(self, msg):
        self.get_logger().info(
            f'[MONITOR] RFID {msg.event}: tag={msg.tag_id} shelf={msg.shelf_id}')
        self.mission_log.append({
            'time': time.time(),
            'event': f'rfid_{msg.event.lower()}',
            'tag': msg.tag_id
        })

    def _heartbeat_check(self):
        now = time.time()
        if self.last_status_time > 0 and (now - self.last_status_time) > 3.0:
            self.get_logger().warn('[HEARTBEAT] No robot_status for >3s — mission_manager may be down')
        else:
            self.get_logger().debug('[HEARTBEAT] OK')

    def _diagnostic_report(self):
        self.get_logger().info(
            f'[DIAG] State={self.current_state} | '
            f'StatusMsgs={self.status_count} | '
            f'LogEntries={len(self.mission_log)}')


def main(args=None):
    rclpy.init(args=args)
    node = MonitorNode()
    rclpy.spin(node)
    node.destroy_node()
    rclpy.shutdown()


if __name__ == '__main__':
    main()
PYEOF
log_ok "monitor_node.py written"


# --- orion_gui.py: PyQt5 Dashboard ---
cat > "$CORE_DIR/orion_core/orion_gui.py" <<'PYEOF'
#!/usr/bin/env python3
"""
Orion AGV Dashboard (PyQt5)
=============================
Professional GUI with live ROS2 updates.
Displays: state, mission, shelf, SKU, RFID, position, battery, queue.
Buttons: Create Mission, Return Home, E-Stop, Reset, Clear Queue.
"""
import sys
import threading
import uuid

import rclpy
from rclpy.node import Node
from orion_msgs.msg import Mission, RobotStatus
from nav_msgs.msg import Odometry

from PyQt5.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
    QLabel, QLineEdit, QPushButton, QGroupBox, QGridLayout,
    QProgressBar, QTextEdit, QFrame
)
from PyQt5.QtCore import Qt, QTimer, pyqtSignal, QObject
from PyQt5.QtGui import QFont, QColor, QPalette


class RosSignals(QObject):
    status_update = pyqtSignal(object)
    odom_update = pyqtSignal(float, float)


class GuiRosNode(Node):
    def __init__(self, signals):
        super().__init__('orion_gui', namespace='orion')
        self.signals = signals
        self.mission_pub = self.create_publisher(Mission, 'mission_input', 10)
        self.create_subscription(RobotStatus, 'robot_status', self._status_cb, 10)
        self.create_subscription(Odometry, 'odom', self._odom_cb, 10)

    def _status_cb(self, msg):
        self.signals.status_update.emit(msg)

    def _odom_cb(self, msg):
        self.signals.odom_update.emit(
            msg.pose.pose.position.x, msg.pose.pose.position.y)

    def send_mission(self, action, shelf='', sku=''):
        msg = Mission()
        msg.action = action
        msg.target_shelf = shelf
        msg.sku = sku
        msg.mission_id = str(uuid.uuid4())[:8]
        msg.priority = 1
        self.mission_pub.publish(msg)


class OrionDashboard(QMainWindow):
    def __init__(self, ros_node, signals):
        super().__init__()
        self.ros_node = ros_node
        self.signals = signals
        self.setWindowTitle('ORION AGV Dashboard')
        self.setMinimumSize(800, 600)
        self._setup_ui()
        self.signals.status_update.connect(self._on_status)
        self.signals.odom_update.connect(self._on_odom)

    def _setup_ui(self):
        central = QWidget()
        self.setCentralWidget(central)
        main_layout = QVBoxLayout(central)

        # Title
        title = QLabel('ORION Warehouse AGV')
        title.setFont(QFont('Arial', 18, QFont.Bold))
        title.setAlignment(Qt.AlignCenter)
        main_layout.addWidget(title)

        # Status group
        status_group = QGroupBox('Robot Status')
        sg_layout = QGridLayout()
        self.lbl_state = QLabel('IDLE')
        self.lbl_state.setFont(QFont('Courier', 14, QFont.Bold))
        self.lbl_mission = QLabel('-')
        self.lbl_shelf = QLabel('-')
        self.lbl_sku = QLabel('-')
        self.lbl_rfid = QLabel('-')
        self.lbl_pos = QLabel('(0.00, 0.00)')
        self.lbl_load = QLabel('No')
        self.battery_bar = QProgressBar()
        self.battery_bar.setRange(0, 100)
        self.battery_bar.setValue(100)

        labels = ['State:', 'Mission:', 'Target Shelf:', 'SKU:',
                  'Last RFID:', 'Position:', 'Carrying:', 'Battery:']
        widgets = [self.lbl_state, self.lbl_mission, self.lbl_shelf,
                   self.lbl_sku, self.lbl_rfid, self.lbl_pos,
                   self.lbl_load, self.battery_bar]
        for i, (lbl, wid) in enumerate(zip(labels, widgets)):
            sg_layout.addWidget(QLabel(lbl), i, 0)
            sg_layout.addWidget(wid, i, 1)
        status_group.setLayout(sg_layout)
        main_layout.addWidget(status_group)

        # Control group
        ctrl_group = QGroupBox('Mission Control')
        ctrl_layout = QHBoxLayout()

        self.shelf_input = QLineEdit()
        self.shelf_input.setPlaceholderText('Shelf (e.g. A3)')
        self.sku_input = QLineEdit()
        self.sku_input.setPlaceholderText('SKU (optional)')

        btn_send = QPushButton('Send Mission')
        btn_send.clicked.connect(self._send_mission)
        btn_return = QPushButton('Return Home')
        btn_return.clicked.connect(self._return_home)
        btn_estop = QPushButton('E-STOP')
        btn_estop.setStyleSheet('background-color: red; color: white; font-weight: bold;')
        btn_estop.clicked.connect(self._estop)
        btn_reset = QPushButton('Reset')
        btn_reset.clicked.connect(self._reset)
        btn_clear = QPushButton('Clear Queue')
        btn_clear.clicked.connect(self._clear_queue)

        ctrl_layout.addWidget(self.shelf_input)
        ctrl_layout.addWidget(self.sku_input)
        ctrl_layout.addWidget(btn_send)
        ctrl_layout.addWidget(btn_return)
        ctrl_layout.addWidget(btn_estop)
        ctrl_layout.addWidget(btn_reset)
        ctrl_layout.addWidget(btn_clear)
        ctrl_group.setLayout(ctrl_layout)
        main_layout.addWidget(ctrl_group)

        # Log area
        log_group = QGroupBox('Activity Log')
        log_layout = QVBoxLayout()
        self.log_text = QTextEdit()
        self.log_text.setReadOnly(True)
        self.log_text.setMaximumHeight(150)
        log_layout.addWidget(self.log_text)
        log_group.setLayout(log_layout)
        main_layout.addWidget(log_group)

    def _on_status(self, msg):
        self.lbl_state.setText(msg.state)
        self.lbl_mission.setText(msg.mission_id or '-')
        self.lbl_shelf.setText(msg.target_shelf or '-')
        self.lbl_sku.setText(msg.current_sku or '-')
        self.lbl_rfid.setText(msg.last_rfid or '-')
        self.lbl_load.setText('YES' if msg.carrying_load else 'No')
        self.battery_bar.setValue(int(msg.battery_percent))

        # Color state
        colors = {
            'IDLE': 'green', 'NAVIGATING': 'blue', 'TURNING': 'orange',
            'AT_SHELF': 'purple', 'LOADING': 'darkblue', 'PIVOTING': 'orange',
            'PIVOT_NUDGE': 'orange', 'RETURNING': 'blue',
            'DOCKED': 'green', 'ERROR': 'red'
        }
        color = colors.get(msg.state, 'black')
        self.lbl_state.setStyleSheet(f'color: {color}; font-weight: bold;')

    def _on_odom(self, x, y):
        self.lbl_pos.setText(f'({x:.2f}, {y:.2f})')

    def _send_mission(self):
        shelf = self.shelf_input.text().strip().upper()
        sku = self.sku_input.text().strip()
        if not shelf:
            self._log('Error: Enter a shelf ID (e.g. A3)')
            return
        self.ros_node.send_mission('PICKUP', shelf, sku)
        self._log(f'Mission sent: shelf={shelf} sku={sku}')
        self.shelf_input.clear()
        self.sku_input.clear()

    def _return_home(self):
        self.ros_node.send_mission('RETURN')
        self._log('Return Home command sent')

    def _estop(self):
        self.ros_node.send_mission('ESTOP')
        self._log('EMERGENCY STOP sent')

    def _reset(self):
        self.ros_node.send_mission('RESET')
        self._log('System RESET sent')

    def _clear_queue(self):
        self.ros_node.send_mission('ABORT')
        self._log('Queue cleared (ABORT)')

    def _log(self, text):
        self.log_text.append(text)


def main(args=None):
    rclpy.init(args=args)
    signals = RosSignals()
    ros_node = GuiRosNode(signals)

    # Spin ROS in background thread
    spin_thread = threading.Thread(target=rclpy.spin, args=(ros_node,), daemon=True)
    spin_thread.start()

    app = QApplication(sys.argv)
    window = OrionDashboard(ros_node, signals)
    window.show()

    exit_code = app.exec_()
    ros_node.destroy_node()
    rclpy.shutdown()
    sys.exit(exit_code)


if __name__ == '__main__':
    main()
PYEOF
log_ok "orion_gui.py written"


###############################################################################
# PHASE 7 — orion_launch
###############################################################################
log_phase "PHASE 7 — orion_launch"
LAUNCH_DIR="$ORION_SRC/orion_launch"
mkdir -p "$LAUNCH_DIR"/{launch,config,rviz}
mkdir -p "$LAUNCH_DIR/orion_launch"
mkdir -p "$LAUNCH_DIR/resource"
touch "$LAUNCH_DIR/resource/orion_launch"

cat > "$LAUNCH_DIR/package.xml" <<'EOF'
<?xml version="1.0"?>
<package format="3">
  <name>orion_launch</name>
  <version>1.0.0</version>
  <description>Orion AGV launch files</description>
  <maintainer email="dev@orion.io">Orion</maintainer>
  <license>Apache-2.0</license>
  <buildtool_depend>ament_python</buildtool_depend>
  <exec_depend>orion_msgs</exec_depend>
  <exec_depend>orion_robot</exec_depend>
  <exec_depend>orion_world</exec_depend>
  <exec_depend>orion_core</exec_depend>
  <exec_depend>gazebo_ros</exec_depend>
  <exec_depend>robot_state_publisher</exec_depend>
  <exec_depend>rviz2</exec_depend>
  <exec_depend>xacro</exec_depend>
  <export><build_type>ament_python</build_type></export>
</package>
EOF

cat > "$LAUNCH_DIR/setup.py" <<'EOF'
from setuptools import setup
import os
from glob import glob

package_name = 'orion_launch'
setup(
    name=package_name,
    version='1.0.0',
    packages=[package_name],
    data_files=[
        ('share/ament_index/resource_index/packages', ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
        (os.path.join('share', package_name, 'launch'), glob('launch/*')),
        (os.path.join('share', package_name, 'config'), glob('config/*')),
        (os.path.join('share', package_name, 'rviz'), glob('rviz/*')),
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    entry_points={'console_scripts': []},
)
EOF

cat > "$LAUNCH_DIR/setup.cfg" <<'EOF'
[develop]
script_dir=$base/lib/orion_launch
[install]
install_scripts=$base/lib/orion_launch
EOF

cat > "$LAUNCH_DIR/orion_launch/__init__.py" <<'EOF'
EOF


# --- Main launch file ---
cat > "$LAUNCH_DIR/launch/warehouse.launch.py" <<'PYEOF'
#!/usr/bin/env python3
"""
Orion Warehouse — Master Launch File
Launches everything with one command:
  ros2 launch orion_launch warehouse.launch.py
"""
import os
from launch import LaunchDescription
from launch.actions import (
    DeclareLaunchArgument, ExecuteProcess, IncludeLaunchDescription,
    TimerAction, GroupAction
)
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch.substitutions import LaunchConfiguration, Command
from launch_ros.actions import Node
from ament_index_python.packages import get_package_share_directory


def generate_launch_description():
    # Package paths
    robot_pkg = get_package_share_directory('orion_robot')
    world_pkg = get_package_share_directory('orion_world')
    launch_pkg = get_package_share_directory('orion_launch')

    # Files
    urdf_file = os.path.join(robot_pkg, 'urdf', 'orion_agv.urdf.xacro')
    world_file = os.path.join(world_pkg, 'worlds', 'orion_warehouse.world')
    rviz_config = os.path.join(launch_pkg, 'rviz', 'orion.rviz')

    # Process xacro
    robot_description = Command(['xacro ', urdf_file])

    return LaunchDescription([
        # Gazebo
        ExecuteProcess(
            cmd=['gazebo', '--verbose', world_file,
                 '-s', 'libgazebo_ros_init.so',
                 '-s', 'libgazebo_ros_factory.so'],
            output='screen'
        ),

        # Robot State Publisher
        Node(
            package='robot_state_publisher',
            executable='robot_state_publisher',
            namespace='orion',
            parameters=[{'robot_description': robot_description}],
            output='screen'
        ),

        # Spawn robot in Gazebo (delayed to let Gazebo start)
        TimerAction(
            period=4.0,
            actions=[
                Node(
                    package='gazebo_ros',
                    executable='spawn_entity.py',
                    arguments=[
                        '-topic', '/orion/robot_description',
                        '-entity', 'orion_agv',
                        '-x', '0.0', '-y', '0.0', '-z', '0.01',
                        '-R', '0.0', '-P', '0.0', '-Y', '0.0'
                    ],
                    output='screen'
                ),
            ]
        ),

        # Core nodes (delayed to let robot spawn)
        TimerAction(
            period=8.0,
            actions=[
                # Optical Sensors
                Node(
                    package='orion_core',
                    executable='optical_sensors',
                    namespace='orion',
                    output='screen'
                ),
                # Line Controller
                Node(
                    package='orion_core',
                    executable='line_controller',
                    namespace='orion',
                    output='screen'
                ),
                # Turn Controller
                Node(
                    package='orion_core',
                    executable='turn_controller',
                    namespace='orion',
                    output='screen'
                ),
                # Pivot Controller
                Node(
                    package='orion_core',
                    executable='pivot_controller',
                    namespace='orion',
                    output='screen'
                ),
                # RFID Scanner
                Node(
                    package='orion_core',
                    executable='rfid_scanner',
                    namespace='orion',
                    output='screen'
                ),
                # Mission Manager
                Node(
                    package='orion_core',
                    executable='mission_manager',
                    namespace='orion',
                    output='screen'
                ),
                # Monitor
                Node(
                    package='orion_core',
                    executable='monitor_node',
                    namespace='orion',
                    output='screen'
                ),
            ]
        ),

        # RViz (delayed)
        TimerAction(
            period=6.0,
            actions=[
                Node(
                    package='rviz2',
                    executable='rviz2',
                    arguments=['-d', rviz_config],
                    output='screen'
                ),
            ]
        ),

        # GUI (delayed)
        TimerAction(
            period=10.0,
            actions=[
                Node(
                    package='orion_core',
                    executable='orion_gui',
                    namespace='orion',
                    output='screen'
                ),
            ]
        ),
    ])
PYEOF
log_ok "warehouse.launch.py written"


# --- RViz config ---
cat > "$LAUNCH_DIR/rviz/orion.rviz" <<'EOF'
Panels:
  - Class: rviz_common/Displays
    Name: Displays
Visualization Manager:
  Class: ""
  Displays:
    - Class: rviz_default_plugins/RobotModel
      Name: RobotModel
      Description Topic:
        Value: /orion/robot_description
      Enabled: true
      Robot Description Topic:
        Value: /orion/robot_description
    - Class: rviz_default_plugins/TF
      Name: TF
      Enabled: true
    - Class: rviz_default_plugins/Odometry
      Name: Odometry
      Topic:
        Value: /orion/odom
      Enabled: true
  Global Options:
    Fixed Frame: odom
  Tools:
    - Class: rviz_default_plugins/MoveCamera
  Views:
    Current:
      Class: rviz_default_plugins/Orbit
      Distance: 15
      Focal Point:
        X: 5
        Y: 3
        Z: 0
      Name: Current View
EOF

###############################################################################
# PHASE 8 — Build
###############################################################################
log_phase "PHASE 8 — Building workspace"
cd "$ORION_WS"

# Build messages first (other packages depend on them)
log_info "Building orion_msgs..."
source "/opt/ros/$ROS_DISTRO_TARGET/setup.bash"
colcon build --packages-select orion_msgs --symlink-install 2>&1 | tail -5
source "$ORION_WS/install/setup.bash"
log_ok "orion_msgs built"

# Build remaining packages
log_info "Building all remaining packages..."
colcon build --symlink-install --packages-skip orion_msgs 2>&1 | tail -10
source "$ORION_WS/install/setup.bash"
log_ok "All packages built"


###############################################################################
# PHASE 9 — Validation
###############################################################################
log_phase "PHASE 9 — Validation"

PASS=0; FAIL=0
check() {
  if eval "$2" >/dev/null 2>&1; then
    log_ok "  ✓ $1"
    ((PASS++))
  else
    log_err "  ✗ $1"
    ((FAIL++))
  fi
}

check "orion_msgs package.xml exists" "[ -f '$ORION_SRC/orion_msgs/package.xml' ]"
check "orion_core package.xml exists" "[ -f '$ORION_SRC/orion_core/package.xml' ]"
check "orion_robot package.xml exists" "[ -f '$ORION_SRC/orion_robot/package.xml' ]"
check "orion_world package.xml exists" "[ -f '$ORION_SRC/orion_world/package.xml' ]"
check "orion_launch package.xml exists" "[ -f '$ORION_SRC/orion_launch/package.xml' ]"
check "URDF exists" "[ -f '$ORION_SRC/orion_robot/urdf/orion_agv.urdf.xacro' ]"
check "World file exists" "[ -f '$ORION_SRC/orion_world/worlds/orion_warehouse.world' ]"
check "Launch file exists" "[ -f '$ORION_SRC/orion_launch/launch/warehouse.launch.py' ]"
check "Mission.msg exists" "[ -f '$ORION_SRC/orion_msgs/msg/Mission.msg' ]"
check "RFIDEvent.msg exists" "[ -f '$ORION_SRC/orion_msgs/msg/RFIDEvent.msg' ]"
check "RobotStatus.msg exists" "[ -f '$ORION_SRC/orion_msgs/msg/RobotStatus.msg' ]"
check "mission_manager.py exists" "[ -f '$ORION_SRC/orion_core/orion_core/mission_manager.py' ]"
check "line_controller.py exists" "[ -f '$ORION_SRC/orion_core/orion_core/line_controller.py' ]"
check "turn_controller.py exists" "[ -f '$ORION_SRC/orion_core/orion_core/turn_controller.py' ]"
check "pivot_controller.py exists" "[ -f '$ORION_SRC/orion_core/orion_core/pivot_controller.py' ]"
check "optical_sensors.py exists" "[ -f '$ORION_SRC/orion_core/orion_core/optical_sensors.py' ]"
check "rfid_scanner.py exists" "[ -f '$ORION_SRC/orion_core/orion_core/rfid_scanner.py' ]"
check "send_mission.py exists" "[ -f '$ORION_SRC/orion_core/orion_core/send_mission.py' ]"
check "orion_gui.py exists" "[ -f '$ORION_SRC/orion_core/orion_core/orion_gui.py' ]"
check "monitor_node.py exists" "[ -f '$ORION_SRC/orion_core/orion_core/monitor_node.py' ]"
check "install/setup.bash exists" "[ -f '$ORION_WS/install/setup.bash' ]"
check "orion_msgs installed" "[ -d '$ORION_WS/install/orion_msgs' ]"
check "orion_core installed" "[ -d '$ORION_WS/install/orion_core' ]"

log_info ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  VALIDATION: $PASS passed, $FAIL failed"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ $FAIL -gt 0 ]]; then
  log_err "Some checks failed. Review output above."
fi

###############################################################################
# PHASE 10 — Launch (optional)
###############################################################################
if [[ $DO_LAUNCH -eq 1 ]]; then
  log_phase "PHASE 10 — Launching Orion"
  log_info "Starting: ros2 launch orion_launch warehouse.launch.py"
  log_info ""
  log_info "  Send missions with:"
  log_info "    ros2 run orion_core send_mission A3"
  log_info "    ros2 run orion_core send_mission --estop"
  log_info "    ros2 run orion_core send_mission --reset"
  log_info ""
  source "$ORION_WS/install/setup.bash"
  export GAZEBO_MODEL_PATH="$ORION_WS/install/orion_world/share/orion_world/models:${GAZEBO_MODEL_PATH:-}"
  ros2 launch orion_launch warehouse.launch.py
else
  log_ok "Build complete. Launch skipped (--no-launch)."
  log_info "To launch manually:"
  log_info "  source $ORION_WS/install/setup.bash"
  log_info "  ros2 launch orion_launch warehouse.launch.py"
fi

log_phase "DONE"
log_ok "Orion AGV simulation ready."
