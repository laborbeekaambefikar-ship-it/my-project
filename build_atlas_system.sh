#!/usr/bin/env bash
# ============================================================================
# ATLAS_FLEET — Complete Warehouse AGV Simulation
# Ubuntu 22.04 + ROS 2 Humble + Gazebo Classic
# Single-command bootstrap: ./build_atlas_system.sh
# ============================================================================
set -e

WS="${HOME}/atlas_ws"
SRC="${WS}/src"
ROS_DISTRO="${ROS_DISTRO:-humble}"

RED='\033[0;31m'; GRN='\033[0;32m'; CYN='\033[0;36m'; RST='\033[0m'
info() { echo -e "${CYN}[ATLAS]${RST} $*"; }
ok()   { echo -e "${GRN}[  OK ]${RST} $*"; }
err()  { echo -e "${RED}[FAIL]${RST} $*"; exit 1; }

# ── Phase 1: Dependencies ─────────────────────────────────────────────────
info "Phase 1: Installing system dependencies"
sudo apt-get update -y >/dev/null 2>&1
sudo apt-get install -y \
  python3-pip python3-colcon-common-extensions \
  ros-${ROS_DISTRO}-gazebo-ros-pkgs \
  ros-${ROS_DISTRO}-xacro \
  ros-${ROS_DISTRO}-robot-state-publisher \
  ros-${ROS_DISTRO}-joint-state-publisher \
  ros-${ROS_DISTRO}-rviz2 \
  ros-${ROS_DISTRO}-tf-transformations \
  ros-${ROS_DISTRO}-rosidl-default-generators \
  python3-pyqt5 >/dev/null 2>&1
pip3 install --user --quiet transforms3d numpy >/dev/null 2>&1
ok "Dependencies installed"

# ── Phase 2: Workspace ────────────────────────────────────────────────────
info "Phase 2: Creating workspace at ${WS}"
rm -rf "${WS}"
mkdir -p "${SRC}"
ok "Workspace created"


# ── Phase 3: atlas_interfaces (custom messages) ──────────────────────────
info "Phase 3: atlas_interfaces"
mkdir -p "${SRC}/atlas_interfaces/msg"

cat > "${SRC}/atlas_interfaces/package.xml" << 'EOF'
<?xml version="1.0"?>
<package format="3">
  <name>atlas_interfaces</name>
  <version>1.0.0</version>
  <description>ATLAS Fleet custom message definitions</description>
  <maintainer email="atlas@dev.local">atlas</maintainer>
  <license>MIT</license>
  <buildtool_depend>ament_cmake</buildtool_depend>
  <buildtool_depend>rosidl_default_generators</buildtool_depend>
  <depend>std_msgs</depend>
  <depend>geometry_msgs</depend>
  <exec_depend>rosidl_default_runtime</exec_depend>
  <member_of_group>rosidl_interface_packages</member_of_group>
  <export><build_type>ament_cmake</build_type></export>
</package>
EOF

cat > "${SRC}/atlas_interfaces/CMakeLists.txt" << 'EOF'
cmake_minimum_required(VERSION 3.8)
project(atlas_interfaces)
find_package(ament_cmake REQUIRED)
find_package(std_msgs REQUIRED)
find_package(geometry_msgs REQUIRED)
find_package(rosidl_default_generators REQUIRED)
rosidl_generate_interfaces(${PROJECT_NAME}
  "msg/FleetMission.msg"
  "msg/RobotState.msg"
  "msg/ShelfTag.msg"
  DEPENDENCIES std_msgs geometry_msgs
)
ament_export_dependencies(rosidl_default_runtime)
ament_package()
EOF

cat > "${SRC}/atlas_interfaces/msg/FleetMission.msg" << 'EOF'
string mission_id
string target_shelf
string sku
uint8 priority
uint8 status
# status: 0=QUEUED,1=NAVIGATING,2=AT_SHELF,3=PICKUP,4=RETURNING,5=COMPLETE,6=ERROR
EOF

cat > "${SRC}/atlas_interfaces/msg/RobotState.msg" << 'EOF'
string state
string mission_id
string target_shelf
string current_sku
string last_tag
bool carrying_load
float32 battery_percent
geometry_msgs/Pose2D pose
EOF

cat > "${SRC}/atlas_interfaces/msg/ShelfTag.msg" << 'EOF'
string tag_id
string shelf_id
float32 distance
bool is_home
builtin_interfaces/Time stamp
EOF
ok "atlas_interfaces created"


# ── Phase 4: atlas_description (URDF) ─────────────────────────────────────
info "Phase 4: atlas_description"
mkdir -p "${SRC}/atlas_description/urdf"
mkdir -p "${SRC}/atlas_description/launch"
mkdir -p "${SRC}/atlas_description/rviz"

cat > "${SRC}/atlas_description/package.xml" << 'EOF'
<?xml version="1.0"?>
<package format="3">
  <name>atlas_description</name>
  <version>1.0.0</version>
  <description>ATLAS AGV robot description</description>
  <maintainer email="atlas@dev.local">atlas</maintainer>
  <license>MIT</license>
  <buildtool_depend>ament_cmake</buildtool_depend>
  <exec_depend>robot_state_publisher</exec_depend>
  <exec_depend>joint_state_publisher</exec_depend>
  <exec_depend>xacro</exec_depend>
  <exec_depend>gazebo_ros</exec_depend>
  <export><build_type>ament_cmake</build_type></export>
</package>
EOF

cat > "${SRC}/atlas_description/CMakeLists.txt" << 'EOF'
cmake_minimum_required(VERSION 3.8)
project(atlas_description)
find_package(ament_cmake REQUIRED)
install(DIRECTORY urdf launch rviz DESTINATION share/${PROJECT_NAME})
ament_package()
EOF

cat > "${SRC}/atlas_description/urdf/atlas_agv.urdf.xacro" << 'EOF'
<?xml version="1.0"?>
<robot name="atlas_agv" xmlns:xacro="http://www.ros.org/wiki/xacro">
  <xacro:property name="WR" value="0.05"/>
  <xacro:property name="WT" value="0.04"/>
  <xacro:property name="WS" value="0.30"/>
  <xacro:property name="BX" value="0.30"/>
  <xacro:property name="BY" value="0.25"/>
  <xacro:property name="BZ" value="0.10"/>
  <xacro:property name="BM" value="2.5"/>
  <xacro:property name="WM" value="0.2"/>
  <xacro:property name="CR" value="0.025"/>
  <xacro:property name="PI" value="3.14159265359"/>

  <link name="base_footprint"/>
  <joint name="base_joint" type="fixed">
    <parent link="base_footprint"/>
    <child link="base_link"/>
    <origin xyz="0 0 ${WR}" rpy="0 0 0"/>
  </joint>

  <link name="base_link">
    <visual>
      <origin xyz="0 0 ${BZ/2}"/>
      <geometry><box size="${BX} ${BY} ${BZ}"/></geometry>
      <material name="blue"><color rgba="0.1 0.2 0.6 1"/></material>
    </visual>
    <collision>
      <origin xyz="0 0 ${BZ/2}"/>
      <geometry><box size="${BX} ${BY} ${BZ}"/></geometry>
    </collision>
    <inertial>
      <mass value="${BM}"/>
      <inertia ixx="${BM*(BY*BY+BZ*BZ)/12}" ixy="0" ixz="0"
               iyy="${BM*(BX*BX+BZ*BZ)/12}" iyz="0"
               izz="${BM*(BX*BX+BY*BY)/12}"/>
    </inertial>
  </link>

  <xacro:macro name="wheel" params="name y_sign">
    <link name="${name}_wheel">
      <visual>
        <origin rpy="${PI/2} 0 0"/>
        <geometry><cylinder radius="${WR}" length="${WT}"/></geometry>
        <material name="black"><color rgba="0.1 0.1 0.1 1"/></material>
      </visual>
      <collision>
        <origin rpy="${PI/2} 0 0"/>
        <geometry><cylinder radius="${WR}" length="${WT}"/></geometry>
      </collision>
      <inertial>
        <mass value="${WM}"/>
        <inertia ixx="${WM*(3*WR*WR+WT*WT)/12}" ixy="0" ixz="0"
                 iyy="${WM*(3*WR*WR+WT*WT)/12}" iyz="0"
                 izz="${WM*WR*WR/2}"/>
      </inertial>
    </link>
    <joint name="${name}_wheel_joint" type="continuous">
      <parent link="base_link"/>
      <child link="${name}_wheel"/>
      <origin xyz="0 ${y_sign*WS/2} 0"/>
      <axis xyz="0 1 0"/>
      <dynamics damping="0.5" friction="0.3"/>
    </joint>
    <gazebo reference="${name}_wheel">
      <mu1>1.5</mu1><mu2>1.0</mu2>
      <kp>1e6</kp><kd>10</kd>
      <minDepth>0.001</minDepth>
    </gazebo>
  </xacro:macro>

  <xacro:wheel name="left" y_sign="1"/>
  <xacro:wheel name="right" y_sign="-1"/>

  <link name="caster_wheel">
    <visual><geometry><sphere radius="${CR}"/></geometry></visual>
    <collision><geometry><sphere radius="${CR}"/></geometry></collision>
    <inertial>
      <mass value="0.05"/>
      <inertia ixx="1e-5" ixy="0" ixz="0" iyy="1e-5" iyz="0" izz="1e-5"/>
    </inertial>
  </link>
  <joint name="caster_joint" type="fixed">
    <parent link="base_link"/>
    <child link="caster_wheel"/>
    <origin xyz="0.12 0 ${CR-WR}"/>
  </joint>
  <gazebo reference="caster_wheel">
    <mu1>0.0</mu1><mu2>0.0</mu2>
  </gazebo>

  <!-- IMU -->
  <link name="imu_link"/>
  <joint name="imu_joint" type="fixed">
    <parent link="base_link"/><child link="imu_link"/>
    <origin xyz="0 0 ${BZ/2}"/>
  </joint>
  <gazebo reference="imu_link">
    <sensor name="atlas_imu" type="imu">
      <always_on>true</always_on>
      <update_rate>100</update_rate>
      <plugin name="imu_plugin" filename="libgazebo_ros_imu_sensor.so">
        <ros><namespace>/atlas</namespace>
        <remapping>~/out:=imu</remapping></ros>
        <frame_name>imu_link</frame_name>
      </plugin>
    </sensor>
  </gazebo>

  <!-- Diff drive -->
  <gazebo>
    <plugin name="atlas_drive" filename="libgazebo_ros_diff_drive.so">
      <ros><namespace>/atlas</namespace></ros>
      <update_rate>50</update_rate>
      <left_joint>left_wheel_joint</left_joint>
      <right_joint>right_wheel_joint</right_joint>
      <wheel_separation>${WS}</wheel_separation>
      <wheel_diameter>${2*WR}</wheel_diameter>
      <max_wheel_torque>5.0</max_wheel_torque>
      <max_wheel_acceleration>2.0</max_wheel_acceleration>
      <publish_odom>true</publish_odom>
      <publish_odom_tf>true</publish_odom_tf>
      <publish_wheel_tf>true</publish_wheel_tf>
      <odometry_frame>odom</odometry_frame>
      <robot_base_frame>base_footprint</robot_base_frame>
      <command_topic>cmd_vel</command_topic>
      <odometry_topic>odom</odometry_topic>
    </plugin>
  </gazebo>

  <gazebo reference="base_link">
    <material>Gazebo/Blue</material>
  </gazebo>
</robot>
EOF
ok "atlas_description created"


# ── Phase 5: atlas_gazebo (world) ─────────────────────────────────────────
info "Phase 5: atlas_gazebo"
mkdir -p "${SRC}/atlas_gazebo/worlds"
mkdir -p "${SRC}/atlas_gazebo/launch"

cat > "${SRC}/atlas_gazebo/package.xml" << 'EOF'
<?xml version="1.0"?>
<package format="3">
  <name>atlas_gazebo</name>
  <version>1.0.0</version>
  <description>ATLAS warehouse world</description>
  <maintainer email="atlas@dev.local">atlas</maintainer>
  <license>MIT</license>
  <buildtool_depend>ament_cmake</buildtool_depend>
  <exec_depend>gazebo_ros</exec_depend>
  <export><build_type>ament_cmake</build_type></export>
</package>
EOF

cat > "${SRC}/atlas_gazebo/CMakeLists.txt" << 'EOF'
cmake_minimum_required(VERSION 3.8)
project(atlas_gazebo)
find_package(ament_cmake REQUIRED)
install(DIRECTORY worlds launch DESTINATION share/${PROJECT_NAME})
ament_package()
EOF

# Generate warehouse world with Python
python3 - "${SRC}/atlas_gazebo/worlds/warehouse.world" << 'PYGEN'
import sys
out = sys.argv[1]

# Layout: Home dock at (0,0), spine runs +Y, aisles branch +X at y=2,4,6,8,10
lines = []
def box(name, x, y, z, sx, sy, sz, r, g, b):
    lines.append(f"""
    <model name='{name}'><static>true</static>
      <pose>{x} {y} {z} 0 0 0</pose>
      <link name='link'>
        <collision name='c'><geometry><box><size>{sx} {sy} {sz}</size></box></geometry></collision>
        <visual name='v'><geometry><box><size>{sx} {sy} {sz}</size></box></geometry>
          <material><ambient>{r} {g} {b} 1</ambient><diffuse>{r} {g} {b} 1</diffuse></material>
        </visual>
      </link>
    </model>""")

# Floor
box("floor", 5, 6, -0.005, 14, 14, 0.01, 0.9, 0.9, 0.9)

# Guide lines (black tape on floor) - 5cm wide, 2mm tall
# Spine: x=0, y=0 to y=12
box("spine_line", 0, 6, 0.001, 0.05, 12, 0.002, 0.05, 0.05, 0.05)

# Aisles at y=2,4,6,8,10 running from x=0 to x=5
for i, ay in enumerate([2, 4, 6, 8, 10]):
    box(f"aisle_{i+1}", 2.5, ay, 0.001, 5, 0.05, 0.002, 0.05, 0.05, 0.05)

# HOME dock marker (green)
box("home_dock", 0, 0, 0.001, 0.6, 0.6, 0.002, 0.1, 0.8, 0.2)

# Shelves (brown blocks)
shelf_x = [1.0, 2.0, 3.0, 4.0]
aisle_y = [2, 4, 6, 8, 10]
for ai, ay in enumerate(aisle_y):
    for si, sx in enumerate(shelf_x):
        sid = ai * 4 + si + 1
        box(f"shelf_S{sid:02d}", sx, ay + 0.4, 0.25, 0.4, 0.3, 0.5, 0.5, 0.35, 0.15)

# Walls
box("wall_n", 5, 13, 0.5, 14, 0.1, 1.0, 0.7, 0.7, 0.7)
box("wall_s", 5, -1, 0.5, 14, 0.1, 1.0, 0.7, 0.7, 0.7)
box("wall_e", 12, 6, 0.5, 0.1, 14, 1.0, 0.7, 0.7, 0.7)
box("wall_w", -2, 6, 0.5, 0.1, 14, 1.0, 0.7, 0.7, 0.7)

world = f"""<?xml version='1.0'?>
<sdf version='1.6'>
<world name='atlas_warehouse'>
  <gravity>0 0 -9.81</gravity>
  <physics type='ode'>
    <max_step_size>0.001</max_step_size>
    <real_time_factor>1.0</real_time_factor>
    <real_time_update_rate>1000</real_time_update_rate>
  </physics>
  <scene><ambient>0.5 0.5 0.5 1</ambient><background>0.7 0.8 0.9 1</background></scene>
  <include><uri>model://sun</uri></include>
  <include><uri>model://ground_plane</uri></include>
{''.join(lines)}
</world>
</sdf>
"""
with open(out, 'w') as f:
    f.write(world)
print(f"[ATLAS] Generated {out}")
PYGEN
ok "atlas_gazebo created"


# ── Phase 6: atlas_navigation (sensors + line follower + turn) ────────────
info "Phase 6: atlas_navigation"
mkdir -p "${SRC}/atlas_navigation/atlas_navigation"
touch "${SRC}/atlas_navigation/atlas_navigation/__init__.py"
mkdir -p "${SRC}/atlas_navigation/resource"
touch "${SRC}/atlas_navigation/resource/atlas_navigation"

cat > "${SRC}/atlas_navigation/package.xml" << 'EOF'
<?xml version="1.0"?>
<package format="3">
  <name>atlas_navigation</name>
  <version>1.0.0</version>
  <description>ATLAS navigation nodes</description>
  <maintainer email="atlas@dev.local">atlas</maintainer>
  <license>MIT</license>
  <buildtool_depend>ament_python</buildtool_depend>
  <depend>rclpy</depend>
  <depend>std_msgs</depend>
  <depend>geometry_msgs</depend>
  <depend>nav_msgs</depend>
  <depend>sensor_msgs</depend>
  <depend>atlas_interfaces</depend>
  <export><build_type>ament_python</build_type></export>
</package>
EOF

cat > "${SRC}/atlas_navigation/setup.cfg" << 'EOF'
[develop]
script_dir=$base/lib/atlas_navigation
[install]
install_scripts=$base/lib/atlas_navigation
EOF

cat > "${SRC}/atlas_navigation/setup.py" << 'EOF'
from setuptools import setup
setup(
    name='atlas_navigation',
    version='1.0.0',
    packages=['atlas_navigation'],
    data_files=[
        ('share/ament_index/resource_index/packages', ['resource/atlas_navigation']),
        ('share/atlas_navigation', ['package.xml']),
    ],
    install_requires=['setuptools'],
    entry_points={'console_scripts': [
        'line_sensor    = atlas_navigation.line_sensor:main',
        'line_follower  = atlas_navigation.line_follower:main',
        'turn_controller = atlas_navigation.turn_controller:main',
        'tag_detector   = atlas_navigation.tag_detector:main',
    ]},
)
EOF

# ── line_sensor.py ────────────────────────────────────────────────────────
cat > "${SRC}/atlas_navigation/atlas_navigation/line_sensor.py" << 'PYEOF'
"""
Virtual line sensor — 8 IR elements at 50Hz.
Uses odom directly as world coordinates (no transform needed).
The diff_drive plugin odom frame IS the world frame in this project because
the robot spawns at world (0,0,yaw=pi/2) and the plugin initializes odom
at the spawn pose.

KEY DESIGN: odom position IS world position. No odom_to_world conversion.
"""
import math
import rclpy
from rclpy.node import Node
from nav_msgs.msg import Odometry
from std_msgs.msg import Int8MultiArray, Float32MultiArray, Empty

# World geometry — matches atlas_gazebo/worlds/warehouse.world exactly
SPINE = ((0.0, 0.0), (0.0, 12.0))  # x=0, y from 0 to 12
AISLES = [((0.0, y), (5.0, y)) for y in [2, 4, 6, 8, 10]]
ALL_LINES = [SPINE] + AISLES

# Sensor config
LINE_WIDTH = 0.08  # detection width (half=0.04m)
SENSOR_FWD = 0.10  # 10cm ahead of base_footprint
SENSOR_OFFSETS = [0.07, 0.05, 0.03, 0.01, -0.01, -0.03, -0.05, -0.07]
JUNC_THRESH = 5
JUNC_CONFIRM = 3
JUNC_COOLDOWN = 2.0


def _quat_to_yaw(q):
    return math.atan2(2*(q.w*q.z + q.x*q.y), 1 - 2*(q.y*q.y + q.z*q.z))


def _dist_to_seg(px, py, x1, y1, x2, y2):
    dx, dy = x2-x1, y2-y1
    if dx == 0 and dy == 0:
        return math.hypot(px-x1, py-y1)
    t = max(0.0, min(1.0, ((px-x1)*dx+(py-y1)*dy)/(dx*dx+dy*dy)))
    return math.hypot(px-(x1+t*dx), py-(y1+t*dy))


def _min_line_dist(px, py):
    return min(_dist_to_seg(px, py, s[0][0], s[0][1], s[1][0], s[1][1])
               for s in ALL_LINES)


class LineSensor(Node):
    def __init__(self):
        super().__init__('atlas_line_sensor')
        self.create_subscription(Odometry, '/atlas/odom', self._odom_cb, 10)
        self.pub_bin = self.create_publisher(Int8MultiArray, '/atlas/line_sensors', 10)
        self.pub_raw = self.create_publisher(Float32MultiArray, '/atlas/line_raw', 10)
        self.pub_junc = self.create_publisher(Empty, '/atlas/junction', 10)
        self.create_timer(1/50.0, self._tick)
        self._x = self._y = self._yaw = 0.0
        self._have_odom = False
        self._streak = 0
        self._last_junc = 0.0
        self.get_logger().info('LineSensor ready (8ch, 50Hz)')

    def _odom_cb(self, msg):
        # ODOM IS WORLD — no transform needed
        self._x = msg.pose.pose.position.x
        self._y = msg.pose.pose.position.y
        self._yaw = _quat_to_yaw(msg.pose.pose.orientation)
        self._have_odom = True

    def _tick(self):
        if not self._have_odom:
            return
        cs, sn = math.cos(self._yaw), math.sin(self._yaw)
        half = LINE_WIDTH / 2.0
        bits, raws = [], []
        for off in SENSOR_OFFSETS:
            sx = self._x + cs*SENSOR_FWD - sn*off
            sy = self._y + sn*SENSOR_FWD + cs*off
            d = _min_line_dist(sx, sy)
            raws.append(float(d))
            bits.append(1 if d <= half else 0)

        m = Int8MultiArray(); m.data = bits
        self.pub_bin.publish(m)
        r = Float32MultiArray(); r.data = raws
        self.pub_raw.publish(r)

        # Junction detection
        now = self.get_clock().now().nanoseconds * 1e-9
        self._streak = self._streak + 1 if sum(bits) >= JUNC_THRESH else 0
        if self._streak >= JUNC_CONFIRM and (now - self._last_junc) > JUNC_COOLDOWN:
            self._last_junc = now
            self._streak = 0
            self.pub_junc.publish(Empty())
            self.get_logger().info(f'JUNCTION at ({self._x:.2f}, {self._y:.2f})')


def main():
    rclpy.init()
    rclpy.spin(LineSensor())
    rclpy.shutdown()
PYEOF


# ── line_follower.py ──────────────────────────────────────────────────────
cat > "${SRC}/atlas_navigation/atlas_navigation/line_follower.py" << 'PYEOF'
"""PID line follower. Publishes to /atlas/nav_vel (not cmd_vel directly)."""
import rclpy
from rclpy.node import Node
from std_msgs.msg import Int8MultiArray
from geometry_msgs.msg import Twist

SPEED = 0.4
KP, KI, KD = 0.6, 0.0, 0.2
WEIGHTS = [1.0, 0.71, 0.43, 0.14, -0.14, -0.43, -0.71, -1.0]
GRACE = 60


class LineFollower(Node):
    def __init__(self):
        super().__init__('atlas_line_follower')
        self.create_subscription(Int8MultiArray, '/atlas/line_sensors', self._cb, 10)
        self.pub = self.create_publisher(Twist, '/atlas/nav_vel', 10)
        self.create_timer(1/50.0, self._tick)
        self._err = self._prev = self._intg = 0.0
        self._lost = GRACE + 1
        self._tw = Twist()

    def _cb(self, msg):
        bits = list(msg.data)
        total = sum(bits)
        if total == 0:
            self._lost += 1
            return
        self._err = sum(WEIGHTS[i]*bits[i] for i in range(8)) / total
        d = self._err - self._prev
        self._prev = self._err
        self._intg = max(-1, min(1, self._intg + self._err/50))
        ang = KP*self._err + KI*self._intg + KD*d
        tw = Twist()
        tw.linear.x = SPEED
        tw.angular.z = ang
        self._tw = tw
        self._lost = 0

    def _tick(self):
        if self._lost > GRACE:
            self.pub.publish(Twist())
        else:
            self.pub.publish(self._tw)


def main():
    rclpy.init()
    rclpy.spin(LineFollower())
    rclpy.shutdown()
PYEOF

# ── turn_controller.py ───────────────────────────────────────────────────
cat > "${SRC}/atlas_navigation/atlas_navigation/turn_controller.py" << 'PYEOF'
"""IMU-based turn controller. Publishes to /atlas/turn_vel."""
import math
import rclpy
from rclpy.node import Node
from sensor_msgs.msg import Imu
from std_msgs.msg import Float32, Empty
from geometry_msgs.msg import Twist

SPEED = 0.4
TOL = math.radians(3.0)


def _yaw(q):
    return math.atan2(2*(q.w*q.z+q.x*q.y), 1-2*(q.y*q.y+q.z*q.z))


def _wrap(a):
    return math.atan2(math.sin(a), math.cos(a))


class TurnController(Node):
    def __init__(self):
        super().__init__('atlas_turn_controller')
        self.create_subscription(Imu, '/atlas/imu', self._imu, 10)
        self.create_subscription(Float32, '/atlas/turn_cmd', self._cmd, 10)
        self.pub = self.create_publisher(Twist, '/atlas/turn_vel', 10)
        self.pub_done = self.create_publisher(Empty, '/atlas/turn_done', 10)
        self.create_timer(1/50.0, self._tick)
        self._yaw = 0.0
        self._target = 0.0
        self._dir = 0.0
        self._active = False
        self._have_imu = False

    def _imu(self, msg):
        self._yaw = _yaw(msg.orientation)
        self._have_imu = True

    def _cmd(self, msg):
        if not self._have_imu:
            return
        delta = msg.data
        self._target = _wrap(self._yaw + delta)
        self._dir = 1.0 if delta > 0 else -1.0
        self._active = True

    def _tick(self):
        tw = Twist()
        if self._active and self._have_imu:
            err = _wrap(self._target - self._yaw)
            if abs(err) < TOL:
                self._active = False
                self.pub.publish(Twist())
                self.pub_done.publish(Empty())
                return
            tw.angular.z = self._dir * SPEED
        self.pub.publish(tw)


def main():
    rclpy.init()
    rclpy.spin(TurnController())
    rclpy.shutdown()
PYEOF

# ── tag_detector.py ──────────────────────────────────────────────────────
cat > "${SRC}/atlas_navigation/atlas_navigation/tag_detector.py" << 'PYEOF'
"""Simulated RFID tag detector."""
import math
import rclpy
from rclpy.node import Node
from nav_msgs.msg import Odometry
from atlas_interfaces.msg import ShelfTag

DETECT_R = 0.5
REARM_R = 0.8
HOME = {'id': 'TAG-HOME', 'shelf': '', 'x': 0.0, 'y': 0.0, 'home': True}
AISLE_Y = [2, 4, 6, 8, 10]
SHELF_X = [1.0, 2.0, 3.0, 4.0]
TAGS = [HOME]
_i = 1
for ay in AISLE_Y:
    for sx in SHELF_X:
        TAGS.append({'id': f'TAG-S{_i:02d}', 'shelf': f'S{_i:02d}',
                     'x': sx, 'y': float(ay), 'home': False})
        _i += 1


class TagDetector(Node):
    def __init__(self):
        super().__init__('atlas_tag_detector')
        self.create_subscription(Odometry, '/atlas/odom', self._odom, 10)
        self.pub = self.create_publisher(ShelfTag, '/atlas/tag_event', 10)
        self.create_timer(1/50.0, self._tick)
        self._x = self._y = 0.0
        self._armed = {t['id']: True for t in TAGS}
        self._have = False

    def _odom(self, msg):
        self._x = msg.pose.pose.position.x
        self._y = msg.pose.pose.position.y
        self._have = True

    def _tick(self):
        if not self._have:
            return
        for t in TAGS:
            d = math.hypot(self._x - t['x'], self._y - t['y'])
            if self._armed[t['id']] and d <= DETECT_R:
                m = ShelfTag()
                m.tag_id = t['id']
                m.shelf_id = t['shelf']
                m.distance = float(d)
                m.is_home = t['home']
                m.stamp = self.get_clock().now().to_msg()
                self.pub.publish(m)
                self._armed[t['id']] = False
            elif not self._armed[t['id']] and d > REARM_R:
                self._armed[t['id']] = True


def main():
    rclpy.init()
    rclpy.spin(TagDetector())
    rclpy.shutdown()
PYEOF
ok "atlas_navigation created"


# ── Phase 7: atlas_mission_manager ────────────────────────────────────────
info "Phase 7: atlas_mission_manager"
mkdir -p "${SRC}/atlas_mission_manager/atlas_mission_manager"
touch "${SRC}/atlas_mission_manager/atlas_mission_manager/__init__.py"
mkdir -p "${SRC}/atlas_mission_manager/resource"
touch "${SRC}/atlas_mission_manager/resource/atlas_mission_manager"

cat > "${SRC}/atlas_mission_manager/package.xml" << 'EOF'
<?xml version="1.0"?>
<package format="3">
  <name>atlas_mission_manager</name>
  <version>1.0.0</version>
  <description>ATLAS mission FSM and velocity arbiter</description>
  <maintainer email="atlas@dev.local">atlas</maintainer>
  <license>MIT</license>
  <buildtool_depend>ament_python</buildtool_depend>
  <depend>rclpy</depend>
  <depend>std_msgs</depend>
  <depend>geometry_msgs</depend>
  <depend>nav_msgs</depend>
  <depend>atlas_interfaces</depend>
  <export><build_type>ament_python</build_type></export>
</package>
EOF

cat > "${SRC}/atlas_mission_manager/setup.cfg" << 'EOF'
[develop]
script_dir=$base/lib/atlas_mission_manager
[install]
install_scripts=$base/lib/atlas_mission_manager
EOF

cat > "${SRC}/atlas_mission_manager/setup.py" << 'EOF'
from setuptools import setup
setup(
    name='atlas_mission_manager',
    version='1.0.0',
    packages=['atlas_mission_manager'],
    data_files=[
        ('share/ament_index/resource_index/packages', ['resource/atlas_mission_manager']),
        ('share/atlas_mission_manager', ['package.xml']),
    ],
    install_requires=['setuptools'],
    entry_points={'console_scripts': [
        'mission_node = atlas_mission_manager.mission_node:main',
        'send_mission = atlas_mission_manager.send_mission:main',
    ]},
)
EOF

cat > "${SRC}/atlas_mission_manager/atlas_mission_manager/mission_node.py" << 'PYEOF'
"""
ATLAS Mission Manager — sole publisher on /atlas/cmd_vel.
NEVER modifies robot pose. Movement ONLY through cmd_vel.
"""
import math, uuid
import rclpy
from rclpy.node import Node
from std_msgs.msg import Empty, Float32, String
from geometry_msgs.msg import Twist
from nav_msgs.msg import Odometry
from atlas_interfaces.msg import FleetMission, RobotState, ShelfTag

# Shelf catalog
AISLE_Y = [2, 4, 6, 8, 10]
SHELF_X = [1.0, 2.0, 3.0, 4.0]
SHELVES = {}
_i = 1
for ay in AISLE_Y:
    for sx in SHELF_X:
        SHELVES[f'S{_i:02d}'] = (sx, float(ay), (AISLE_Y.index(ay)+1))
        _i += 1

S_IDLE, S_NAV_SPINE, S_TURNING, S_NAV_AISLE = 'IDLE', 'NAV_SPINE', 'TURNING', 'NAV_AISLE'
S_AT_SHELF, S_PICKUP, S_PIVOT, S_RET_AISLE, S_RET_TURN, S_RET_SPINE = \
    'AT_SHELF', 'PICKUP', 'PIVOT', 'RET_AISLE', 'RET_TURN', 'RET_SPINE'
S_DOCKED, S_ERROR = 'DOCKED', 'ERROR'


class MissionManager(Node):
    def __init__(self):
        super().__init__('atlas_mission_manager')
        # Velocity inputs from sub-controllers
        self.create_subscription(Twist, '/atlas/nav_vel', self._nav_cb, 10)
        self.create_subscription(Twist, '/atlas/turn_vel', self._turn_cb, 10)
        self.create_subscription(Empty, '/atlas/turn_done', self._turn_done, 10)
        self.create_subscription(Empty, '/atlas/junction', self._junction, 10)
        self.create_subscription(ShelfTag, '/atlas/tag_event', self._tag, 10)
        self.create_subscription(Odometry, '/atlas/odom', self._odom, 10)
        # Mission input
        self.create_subscription(FleetMission, '/atlas/mission_cmd', self._mission_in, 10)
        self.create_subscription(Empty, '/atlas/estop', self._estop, 10)
        self.create_subscription(Empty, '/atlas/reset', self._reset_cmd, 10)
        # Output — SOLE cmd_vel publisher
        self.pub_cmd = self.create_publisher(Twist, '/atlas/cmd_vel', 10)
        self.pub_turn = self.create_publisher(Float32, '/atlas/turn_cmd', 10)
        self.pub_state = self.create_publisher(RobotState, '/atlas/robot_state', 10)
        self.pub_log = self.create_publisher(String, '/atlas/log', 50)
        # Timer
        self.create_timer(1/50.0, self._tick)
        self.create_timer(1/10.0, self._pub_status)
        # State
        self.state = S_IDLE
        self.queue = []
        self.active = None
        self.nav_tw = Twist()
        self.turn_tw = Twist()
        self.junc_count = 0
        self.x = self.y = 0.0
        self.battery = 100.0
        self.carrying = False
        self.last_tag = ''
        self.estopped = False
        self.state_t = self._now()
        self.get_logger().info('MissionManager ready — sole /atlas/cmd_vel writer')

    def _now(self):
        return self.get_clock().now().nanoseconds * 1e-9

    def _log(self, s):
        self.get_logger().info(s)
        m = String(); m.data = s; self.pub_log.publish(m)

    def _go(self, ns):
        if ns != self.state:
            self._log(f'STATE {self.state} -> {ns}')
            self.state = ns
            self.state_t = self._now()

    def _nav_cb(self, msg): self.nav_tw = msg
    def _turn_cb(self, msg): self.turn_tw = msg
    def _odom(self, msg):
        self.x = msg.pose.pose.position.x
        self.y = msg.pose.pose.position.y

    def _mission_in(self, msg):
        if msg.target_shelf not in SHELVES:
            self._log(f'Rejected unknown shelf {msg.target_shelf}'); return
        if not msg.mission_id:
            msg.mission_id = f'm-{uuid.uuid4().hex[:6]}'
        self.queue.append(msg)
        self._log(f'Queued {msg.mission_id} -> {msg.target_shelf}')

    def _estop(self, _):
        self.estopped = True; self._go(S_ERROR)
    def _reset_cmd(self, _):
        self.estopped = False; self.queue = []; self.active = None
        self.carrying = False; self._go(S_IDLE)

    def _junction(self, _):
        if self.state == S_NAV_SPINE:
            self.junc_count += 1
            target_aisle = SHELVES[self.active.target_shelf][2]
            self._log(f'Junction #{self.junc_count}/{target_aisle}')
            if self.junc_count >= target_aisle:
                m = Float32(); m.data = -math.pi/2  # turn right
                self.pub_turn.publish(m)
                self._go(S_TURNING)
        elif self.state == S_RET_AISLE:
            m = Float32(); m.data = -math.pi/2  # turn right onto spine
            self.pub_turn.publish(m)
            self._go(S_RET_TURN)

    def _turn_done(self, _):
        if self.state == S_TURNING:
            self._go(S_NAV_AISLE)
        elif self.state == S_RET_TURN:
            self._go(S_RET_SPINE)
        elif self.state == S_PIVOT:
            self._go(S_RET_AISLE)

    def _tag(self, ev):
        self.last_tag = ev.tag_id
        if self.state == S_NAV_AISLE and not ev.is_home:
            if ev.shelf_id == self.active.target_shelf:
                self._go(S_AT_SHELF)
        elif self.state == S_RET_SPINE and ev.is_home:
            self._go(S_DOCKED)

    def _tick(self):
        now = self._now()
        dt = now - self.state_t

        if self.state == S_IDLE and self.queue and not self.estopped:
            self.active = self.queue.pop(0)
            self.junc_count = 0
            self._go(S_NAV_SPINE)
        elif self.state == S_AT_SHELF and dt > 0.5:
            self._go(S_PICKUP)
        elif self.state == S_PICKUP and dt > 2.0:
            self.carrying = True
            m = Float32(); m.data = math.pi  # 180 pivot
            self.pub_turn.publish(m)
            self._go(S_PIVOT)
        elif self.state == S_DOCKED and dt > 1.0:
            self.carrying = False
            self.battery = 100.0
            self.active = None
            self._go(S_IDLE)
            self._log('Mission complete')

        # Velocity arbiter
        out = Twist()
        if self.state in (S_NAV_SPINE, S_NAV_AISLE, S_RET_AISLE, S_RET_SPINE):
            out = self.nav_tw
        elif self.state in (S_TURNING, S_PIVOT, S_RET_TURN):
            out = self.turn_tw
        if self.estopped:
            out = Twist()
        self.pub_cmd.publish(out)

    def _pub_status(self):
        s = RobotState()
        s.state = self.state
        s.mission_id = self.active.mission_id if self.active else ''
        s.target_shelf = self.active.target_shelf if self.active else ''
        s.last_tag = self.last_tag
        s.carrying_load = self.carrying
        s.battery_percent = self.battery
        s.pose.x = self.x; s.pose.y = self.y
        self.pub_state.publish(s)


def main():
    rclpy.init()
    rclpy.spin(MissionManager())
    rclpy.shutdown()
PYEOF

cat > "${SRC}/atlas_mission_manager/atlas_mission_manager/send_mission.py" << 'PYEOF'
"""CLI: ros2 run atlas_mission_manager send_mission S05"""
import sys, uuid, time
import rclpy
from atlas_interfaces.msg import FleetMission

def main():
    rclpy.init()
    node = rclpy.create_node('atlas_send_mission')
    pub = node.create_publisher(FleetMission, '/atlas/mission_cmd', 10)
    shelf = sys.argv[1] if len(sys.argv) > 1 else 'S01'
    time.sleep(0.5)
    m = FleetMission()
    m.mission_id = f'cli-{uuid.uuid4().hex[:6]}'
    m.target_shelf = shelf.upper()
    m.sku = 'SKU-001'
    m.priority = 1
    pub.publish(m)
    print(f'Sent mission {m.mission_id} -> {m.target_shelf}')
    time.sleep(0.5)
    node.destroy_node()
    rclpy.shutdown()
PYEOF
ok "atlas_mission_manager created"


# ── Phase 8: atlas_bringup (master launch) ────────────────────────────────
info "Phase 8: atlas_bringup"
mkdir -p "${SRC}/atlas_bringup/launch"

cat > "${SRC}/atlas_bringup/package.xml" << 'EOF'
<?xml version="1.0"?>
<package format="3">
  <name>atlas_bringup</name>
  <version>1.0.0</version>
  <description>ATLAS master launch</description>
  <maintainer email="atlas@dev.local">atlas</maintainer>
  <license>MIT</license>
  <buildtool_depend>ament_cmake</buildtool_depend>
  <exec_depend>atlas_description</exec_depend>
  <exec_depend>atlas_gazebo</exec_depend>
  <exec_depend>atlas_navigation</exec_depend>
  <exec_depend>atlas_mission_manager</exec_depend>
  <exec_depend>atlas_interfaces</exec_depend>
  <exec_depend>gazebo_ros</exec_depend>
  <exec_depend>robot_state_publisher</exec_depend>
  <exec_depend>xacro</exec_depend>
  <exec_depend>rviz2</exec_depend>
  <export><build_type>ament_cmake</build_type></export>
</package>
EOF

cat > "${SRC}/atlas_bringup/CMakeLists.txt" << 'EOF'
cmake_minimum_required(VERSION 3.8)
project(atlas_bringup)
find_package(ament_cmake REQUIRED)
install(DIRECTORY launch DESTINATION share/${PROJECT_NAME})
ament_package()
EOF

cat > "${SRC}/atlas_bringup/launch/atlas_full.launch.py" << 'PYEOF'
"""
ATLAS_FLEET full system launch.

Spawn sequence:
  t=0:  Gazebo (init plugin ONLY — no factory → no auto-spawn)
        + robot_state_publisher (provides URDF on topic + TF)
  t=4:  spawn_entity.py (reads URDF from /atlas/robot_description,
        spawns at HOME_DOCK via /spawn_entity service)
  t=8:  All runtime nodes (sensors, controllers, mission manager)
  t=10: RViz

The robot is spawned ONCE at (0, 0, 0.01, yaw=pi/2) facing +Y.
The diff_drive plugin initializes odom at the spawn pose.
Therefore odom frame origin = world origin = (0,0).
odom position IS world position. No transform correction needed.
"""
import os
from launch import LaunchDescription
from launch.actions import ExecuteProcess, TimerAction
from launch.substitutions import Command
from launch_ros.actions import Node
from launch_ros.parameter_descriptions import ParameterValue
from ament_index_python.packages import get_package_share_directory


def generate_launch_description():
    desc_pkg = get_package_share_directory('atlas_description')
    gz_pkg   = get_package_share_directory('atlas_gazebo')

    world = os.path.join(gz_pkg, 'worlds', 'warehouse.world')
    xacro = os.path.join(desc_pkg, 'urdf', 'atlas_agv.urdf.xacro')

    # ── Gazebo (no factory plugin) ──
    gazebo = ExecuteProcess(
        cmd=['gazebo', '--verbose', world, '-s', 'libgazebo_ros_init.so'],
        output='screen',
    )

    # ── Robot State Publisher (immediate — needed by spawn_entity) ──
    robot_desc = Command(['xacro ', xacro])
    rsp = Node(
        package='robot_state_publisher',
        executable='robot_state_publisher',
        namespace='atlas',
        output='screen',
        parameters=[{
            'use_sim_time': True,
            'robot_description': ParameterValue(robot_desc, value_type=str),
        }],
    )

    # ── Spawn at HOME_DOCK (0, 0, yaw=pi/2 = facing +Y) ──
    spawn = Node(
        package='gazebo_ros',
        executable='spawn_entity.py',
        output='screen',
        arguments=[
            '-entity', 'atlas_agv',
            '-topic', '/atlas/robot_description',
            '-x', '0.0', '-y', '0.0', '-z', '0.01',
            '-Y', '1.5708',
        ],
    )
    spawn_t = TimerAction(period=4.0, actions=[spawn])

    # ── Navigation + Mission nodes ──
    nodes = [
        Node(package='atlas_navigation', executable='line_sensor',
             name='atlas_line_sensor', output='screen'),
        Node(package='atlas_navigation', executable='line_follower',
             name='atlas_line_follower', output='screen'),
        Node(package='atlas_navigation', executable='turn_controller',
             name='atlas_turn_ctrl', output='screen'),
        Node(package='atlas_navigation', executable='tag_detector',
             name='atlas_tag_detect', output='screen'),
        Node(package='atlas_mission_manager', executable='mission_node',
             name='atlas_mission_mgr', output='screen'),
    ]
    stack_t = TimerAction(period=8.0, actions=nodes)

    # ── RViz ──
    rviz = Node(
        package='rviz2', executable='rviz2', name='atlas_rviz',
        output='log', parameters=[{'use_sim_time': True}],
    )
    rviz_t = TimerAction(period=10.0, actions=[rviz])

    return LaunchDescription([gazebo, rsp, spawn_t, stack_t, rviz_t])
PYEOF
ok "atlas_bringup created"


# ── Phase 9: Build ────────────────────────────────────────────────────────
info "Phase 9: Building workspace"
cd "${WS}"
source "/opt/ros/${ROS_DISTRO}/setup.bash"

info "Building atlas_interfaces first..."
colcon build --packages-select atlas_interfaces --symlink-install 2>&1 | tail -5
source "${WS}/install/setup.bash"

info "Building remaining packages..."
colcon build --packages-skip atlas_interfaces --symlink-install 2>&1 | tail -5
source "${WS}/install/setup.bash"
ok "Build complete"

# ── Phase 10: Validation ─────────────────────────────────────────────────
info "Phase 10: Validation"

# Verify packages
for pkg in atlas_interfaces atlas_description atlas_gazebo atlas_navigation atlas_mission_manager atlas_bringup; do
    ros2 pkg prefix "${pkg}" >/dev/null 2>&1 && ok "  ${pkg} installed" || err "  ${pkg} MISSING"
done

# Verify interfaces
ros2 interface show atlas_interfaces/msg/FleetMission >/dev/null 2>&1 && ok "  FleetMission interface" || err "FleetMission missing"
ros2 interface show atlas_interfaces/msg/RobotState >/dev/null 2>&1 && ok "  RobotState interface" || err "RobotState missing"
ros2 interface show atlas_interfaces/msg/ShelfTag >/dev/null 2>&1 && ok "  ShelfTag interface" || err "ShelfTag missing"

# Verify executables
for exe in line_sensor line_follower turn_controller tag_detector; do
    ros2 pkg executables atlas_navigation 2>/dev/null | grep -q "${exe}" && ok "  ${exe}" || err "  ${exe} missing"
done
ros2 pkg executables atlas_mission_manager 2>/dev/null | grep -q "mission_node" && ok "  mission_node" || err "mission_node missing"

# Verify URDF
xacro "${SRC}/atlas_description/urdf/atlas_agv.urdf.xacro" >/dev/null 2>&1 && ok "  URDF parses" || err "URDF broken"

# Verify world
test -s "${SRC}/atlas_gazebo/worlds/warehouse.world" && ok "  World file exists" || err "World missing"

# Python import test
python3 -c "from atlas_navigation.line_sensor import LineSensor; print('  import OK')" 2>/dev/null && ok "  Python imports" || err "Import failure"

echo ""
echo "============================================================"
echo "  ATLAS_FLEET build complete!"
echo "============================================================"
echo ""
echo "  To launch:"
echo "    source ~/atlas_ws/install/setup.bash"
echo "    ros2 launch atlas_bringup atlas_full.launch.py"
echo ""
echo "  To send a mission:"
echo "    ros2 run atlas_mission_manager send_mission S05"
echo ""
echo "  Verification commands:"
echo "    ros2 topic echo /atlas/odom --once"
echo "    ros2 topic echo /atlas/line_sensors --once"
echo "    ros2 topic echo /atlas/robot_state --once"
echo "    ros2 topic echo /atlas/cmd_vel"
echo ""
echo "  TF validation:"
echo "    ros2 run tf2_ros tf2_echo odom base_footprint"
echo ""
echo "============================================================"

# ── Phase 11: Auto-launch ────────────────────────────────────────────────
info "Phase 11: Launching ATLAS_FLEET..."
exec ros2 launch atlas_bringup atlas_full.launch.py
