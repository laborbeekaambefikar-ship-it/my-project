# 🔁 Stage 3B — Migrating from Downward Camera → Optical (IR) Sensor Array

> **Why this exists:** The original Stage 2/3 used a downward-facing camera in Gazebo with 8-pixel sampling. In practice, this is fragile — `cv_bridge` errors, QoS mismatches, lighting flicker, frame drops at 30 Hz, and the camera rendering plugin loading inconsistently. We're replacing it with a **virtual 8-sensor IR array** that mimics a real TCRT5000 reflective array — which is *also* what you'll use when you build the hardware in Phase 6. So this change makes the sim more reliable **and** aligns it 1:1 with the real-world build.

---

## 📜 Design Philosophy — "Pose-Based IR Simulation"

In real life, a TCRT5000 IR sensor:
1. Emits IR light downward
2. Measures reflection: **white floor → high reading; black tape → low reading**
3. Outputs an analog voltage (0–3.3 V)

In Gazebo, instead of trying to render IR physics (which is unreliable), we do this:

```
For each of 8 virtual sensors:
   1. Use the AGV's odometry (we already publish /agv/odom)
   2. Compute that sensor's (x, y) position in the world,
      based on its offset from base_link
   3. Check: is (x, y) on top of a black tape line?
      → A line is just a known 1D segment in our world model
   4. Output 1 (black) or 0 (white)
```

**The output topic is identical to a real TCRT5000:** `/agv/line_sensors` carries 8 binary values at 50 Hz. Your existing PID line follower keeps working — we just replace its **input source**.

| Layer | Old (camera) | New (optical IR) |
|---|---|---|
| Sensor model | `<sensor type="camera">` in URDF | 8 small visual-only links in URDF |
| Plugin | `libgazebo_ros_camera.so` | None (pure ROS 2 node) |
| Input topic | `/agv/line_cam/image_raw` (Image) | `/agv/odom` (Odometry, already exists) |
| Processing | OpenCV pixel sampling + threshold | Geometry: point-vs-segment distance |
| Output topic | `/agv/line_sensors` (Float32MultiArray) | `/agv/line_sensors` (**unchanged**) |
| Debug viz | Annotated Image | RViz Marker array (8 dots) |
| Frame rate | ~30 Hz, jittery | **50 Hz, deterministic** |

---

## 📐 The "Track Map" — Defining Where the Black Tape Is

Your `warehouse.world` already has the tape laid out. We mirror that layout in Python (just like `shelf_map.py` mirrors the shelves). This becomes our ground truth for "is this point on a line?".

The tape layout from Stage 1:

```
Main aisle:   horizontal segment from (-2.5, 0) to (12.5, 0), width 0.05 m
Spur 1:       vertical segment from (0, 0) to (0, 4),  width 0.05 m
Spur 2:       vertical segment from (3, 0) to (3, 4),  width 0.05 m
Spur 3:       vertical segment from (6, 0) to (6, 4),  width 0.05 m
Spur 4:       vertical segment from (9, 0) to (9, 4),  width 0.05 m
Spur 5:       vertical segment from (12, 0) to (12, 4), width 0.05 m
```

> ⚠️ **You must adjust these coordinates** to match exactly what `generate_world.py` produced for your warehouse. Check that file's `MAIN_AISLE_*` and `SPUR_*` constants.

---

# 🔥 The Migration — What to Change, Delete, and Add

I'll walk through this in 5 sub-stages so you can do it incrementally and verify at each step.

---

## ✅ Sub-Stage 3B-1 — Remove the Camera from the URDF

### 📁 File: `~/warehouse_agv_sim/src/agv_description/urdf/sensors.xacro`

**Find this block** (the entire downward-facing camera section) **and DELETE it:**

```xml
<!-- DELETE FROM HERE -->
<link name="line_cam_link">
  <visual>...</visual>
  <inertial>...</inertial>
</link>

<joint name="line_cam_joint" type="fixed">
  <parent link="base_link"/>
  <child  link="line_cam_link"/>
  <origin xyz="0.060 0 0.010" rpy="0 1.5708 0"/>
</joint>

<link name="line_cam_optical"/>
<joint name="line_cam_optical_joint" type="fixed">
  ...
</joint>

<gazebo reference="line_cam_link">
  <material>Gazebo/Blue</material>
  <sensor name="line_camera" type="camera">
    ... (the entire camera sensor + plugin block)
  </sensor>
</gazebo>
<!-- DELETE TO HERE -->
```

**Keep** the RFID reader and IMU sections — they're unaffected.

### ➕ Then ADD this in the same `sensors.xacro` file:

```xml
  <!-- ============================================================ -->
  <!--  VIRTUAL OPTICAL (IR) SENSOR ARRAY                           -->
  <!--  8 sensors evenly spaced across the front-bottom of the AGV. -->
  <!--  No physics — these are visual links only. The actual sensor -->
  <!--  reading happens in optical_sensor_node.py via odom + geometry-->
  <!-- ============================================================ -->
  <xacro:property name="ir_count"   value="8"/>
  <xacro:property name="ir_spacing" value="0.012"/>   <!-- 12mm between sensors -->
  <xacro:property name="ir_x"       value="0.080"/>   <!-- 8 cm in front of base center -->
  <xacro:property name="ir_z"       value="0.005"/>   <!-- 5 mm above floor -->

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
      <origin xyz="${ir_x} ${y_offset} ${ir_z}" rpy="0 0 0"/>
    </joint>

    <gazebo reference="ir_sensor_${idx}_link">
      <material>Gazebo/Blue</material>
    </gazebo>
  </xacro:macro>

  <!-- Spawn 8 sensors centered on Y=0, indexed 1 (left) to 8 (right) -->
  <!-- For 8 sensors with 12mm spacing, total array width = 7*12 = 84mm -->
  <!-- y_offset goes from +0.042 (left) to -0.042 (right) -->
  <xacro:ir_sensor idx="1" y_offset="0.042"/>
  <xacro:ir_sensor idx="2" y_offset="0.030"/>
  <xacro:ir_sensor idx="3" y_offset="0.018"/>
  <xacro:ir_sensor idx="4" y_offset="0.006"/>
  <xacro:ir_sensor idx="5" y_offset="-0.006"/>
  <xacro:ir_sensor idx="6" y_offset="-0.018"/>
  <xacro:ir_sensor idx="7" y_offset="-0.030"/>
  <xacro:ir_sensor idx="8" y_offset="-0.042"/>
```

> ✅ This gives you 8 visible blue dots on the bottom of the AGV in Gazebo, exactly matching what a real TCRT5000 array looks like.

---

## ✅ Sub-Stage 3B-2 — Create the Track Map

### 📁 NEW file: `~/warehouse_agv_sim/src/agv_control/agv_control/track_map.py`

```python
#!/usr/bin/env python3
"""
Track Map
---------
Defines the geometry of every black tape line in the warehouse.

Each line is represented as a 2D line segment with a width.
A query point (x, y) is "on the line" if its perpendicular distance
to the segment is less than (line_width / 2).

This MUST match the layout in warehouse_world/scripts/generate_world.py.
If you change tape positions there, update this file too.
"""

import math
from dataclasses import dataclass
from typing import List, Tuple


# -------- Constants (match generate_world.py) --------
LINE_WIDTH = 0.05    # 5 cm wide tape (typical electrical tape: 25mm, doubled for visibility)

# Main aisle: horizontal line along Y=0
MAIN_AISLE_X_START = -2.5
MAIN_AISLE_X_END   = 12.5
MAIN_AISLE_Y       = 0.0

# Spurs: vertical lines branching upward
SPUR_X_POSITIONS = [0.0, 3.0, 6.0, 9.0, 12.0]
SPUR_Y_START     = 0.0
SPUR_Y_END       = 4.0


@dataclass
class LineSegment:
    """A black tape line segment in the warehouse floor."""
    name: str
    x1: float
    y1: float
    x2: float
    y2: float
    width: float = LINE_WIDTH

    def distance_to_point(self, px: float, py: float) -> float:
        """Perpendicular distance from point (px, py) to this segment."""
        dx = self.x2 - self.x1
        dy = self.y2 - self.y1
        seg_len_sq = dx * dx + dy * dy
        if seg_len_sq < 1e-9:
            # Degenerate: just compute distance to endpoint
            return math.hypot(px - self.x1, py - self.y1)

        # Project point onto segment, clamp to [0, 1]
        t = ((px - self.x1) * dx + (py - self.y1) * dy) / seg_len_sq
        t = max(0.0, min(1.0, t))
        proj_x = self.x1 + t * dx
        proj_y = self.y1 + t * dy
        return math.hypot(px - proj_x, py - proj_y)

    def contains(self, px: float, py: float) -> bool:
        """Is the point on top of this tape line?"""
        return self.distance_to_point(px, py) < (self.width / 2.0)


def build_track() -> List[LineSegment]:
    """Construct the full list of tape segments in the warehouse."""
    segments: List[LineSegment] = []

    # 1. Main horizontal aisle
    segments.append(LineSegment(
        name="main_aisle",
        x1=MAIN_AISLE_X_START, y1=MAIN_AISLE_Y,
        x2=MAIN_AISLE_X_END,   y2=MAIN_AISLE_Y,
    ))

    # 2. Five vertical spurs
    for idx, sx in enumerate(SPUR_X_POSITIONS, start=1):
        segments.append(LineSegment(
            name=f"spur_{idx}",
            x1=sx, y1=SPUR_Y_START,
            x2=sx, y2=SPUR_Y_END,
        ))

    return segments


TRACK = build_track()


def is_on_any_line(px: float, py: float) -> Tuple[bool, str]:
    """Check if point is on any black tape line.
    Returns (True/False, name_of_line_or_empty)."""
    for seg in TRACK:
        if seg.contains(px, py):
            return True, seg.name
    return False, ""


if __name__ == "__main__":
    print(f"🛣️  Track has {len(TRACK)} segments:")
    for s in TRACK:
        print(f"   {s.name:14s}  ({s.x1:+.2f},{s.y1:+.2f}) → ({s.x2:+.2f},{s.y2:+.2f})")
    # Quick sanity check
    print("\n🧪 Self-test:")
    test_points = [
        (0.0, 0.0, True,  "junction main+spur1"),
        (1.5, 0.0, True,  "on main aisle"),
        (1.5, 0.5, False, "between spur1 and spur2, off main"),
        (3.0, 2.0, True,  "on spur 2"),
        (3.0, 4.5, False, "past end of spur 2"),
    ]
    for px, py, expected, label in test_points:
        on, name = is_on_any_line(px, py)
        ok = "✅" if on == expected else "❌"
        print(f"   {ok} ({px:+.1f},{py:+.1f}) [{label}] → on={on} ({name})")
```

Run it once to verify:
```bash
python3 ~/warehouse_agv_sim/src/agv_control/agv_control/track_map.py
```

You should see 6 segments listed and all 5 self-tests pass.

---

## ✅ Sub-Stage 3B-3 — Create the Optical Sensor Node (replaces camera processing)

### 📁 NEW file: `~/warehouse_agv_sim/src/agv_control/agv_control/optical_sensor_node.py`

```python
#!/usr/bin/env python3
"""
Optical Sensor Node
-------------------
Replaces the camera + 8-pixel sampling from the old line_follower_node.

Subscribes to /agv/odom, computes the world position of each of 8 virtual
IR sensors mounted on the AGV's underside, queries the track map, and
publishes a binary array on /agv/line_sensors — IDENTICAL output topic
and format to what the camera-based version published.

This means the existing PID line-follower logic can be reused with NO
changes (we'll refactor it in Sub-Stage 3B-4).
"""

import math
import rclpy
from rclpy.node import Node

from nav_msgs.msg import Odometry
from std_msgs.msg import Float32MultiArray
from visualization_msgs.msg import Marker, MarkerArray
from geometry_msgs.msg import Point

from agv_control.track_map import is_on_any_line


# ---- Sensor array geometry — MUST MATCH urdf/sensors.xacro ----
NUM_SENSORS    = 8
SENSOR_X       = 0.080    # forward of base_link origin (m)
SENSOR_SPACING = 0.012    # 12 mm between sensors
SENSOR_Z       = 0.005    # height above ground (used for visualization only)


def yaw_from_quat(q):
    """Extract yaw from a geometry_msgs/Quaternion."""
    siny_cosp = 2.0 * (q.w * q.z + q.x * q.y)
    cosy_cosp = 1.0 - 2.0 * (q.y * q.y + q.z * q.z)
    return math.atan2(siny_cosp, cosy_cosp)


class OpticalSensorNode(Node):

    def __init__(self):
        super().__init__('optical_sensor_node')

        # --- Parameters ---
        self.declare_parameter('publish_rate_hz', 50.0)
        self.declare_parameter('publish_markers', True)
        self.publish_markers = self.get_parameter('publish_markers').value

        # Pre-compute each sensor's body-frame Y offset (left = +Y, right = -Y)
        # Index 0 (sensor 1) is leftmost; index 7 (sensor 8) is rightmost
        self.sensor_offsets_y = [
            ((NUM_SENSORS - 1) / 2.0 - i) * SENSOR_SPACING
            for i in range(NUM_SENSORS)
        ]

        # --- State ---
        self.last_pose = None  # (x, y, yaw)

        # --- Subscriptions ---
        self.create_subscription(Odometry, '/agv/odom', self.odom_callback, 50)

        # --- Publishers ---
        self.sensors_pub = self.create_publisher(
            Float32MultiArray, '/agv/line_sensors', 10
        )
        if self.publish_markers:
            self.marker_pub = self.create_publisher(
                MarkerArray, '/agv/line_sensors_markers', 10
            )

        # --- Timer (decoupled from odom rate for stable publishing) ---
        period = 1.0 / float(self.get_parameter('publish_rate_hz').value)
        self.create_timer(period, self.tick)

        self.get_logger().info(
            f'🔆 Optical Sensor Node started ({NUM_SENSORS} virtual IR sensors)'
        )

    # ----------------------------------------------------------
    def odom_callback(self, msg: Odometry):
        x   = msg.pose.pose.position.x
        y   = msg.pose.pose.position.y
        yaw = yaw_from_quat(msg.pose.pose.orientation)
        self.last_pose = (x, y, yaw)

    # ----------------------------------------------------------
    def tick(self):
        if self.last_pose is None:
            return

        bx, by, byaw = self.last_pose
        cos_y = math.cos(byaw)
        sin_y = math.sin(byaw)

        # Compute world (x, y) of each of the 8 sensors
        sensor_world_positions = []
        binary = []
        for off_y in self.sensor_offsets_y:
            # Body-frame: (SENSOR_X, off_y)
            # World-frame: rotate by yaw, then translate by base_link pose
            wx = bx + cos_y * SENSOR_X - sin_y * off_y
            wy = by + sin_y * SENSOR_X + cos_y * off_y
            sensor_world_positions.append((wx, wy))

            on_line, _ = is_on_any_line(wx, wy)
            binary.append(1.0 if on_line else 0.0)

        # Publish binary readings (same format as old camera node)
        msg = Float32MultiArray()
        msg.data = binary
        self.sensors_pub.publish(msg)

        # Publish RViz markers for visualization
        if self.publish_markers:
            self.publish_marker_array(sensor_world_positions, binary)

    # ----------------------------------------------------------
    def publish_marker_array(self, positions, binary):
        ma = MarkerArray()
        now = self.get_clock().now().to_msg()
        for i, ((wx, wy), b) in enumerate(zip(positions, binary)):
            m = Marker()
            m.header.frame_id = 'odom'
            m.header.stamp = now
            m.ns = 'ir_sensors'
            m.id = i
            m.type = Marker.SPHERE
            m.action = Marker.ADD
            m.pose.position.x = wx
            m.pose.position.y = wy
            m.pose.position.z = SENSOR_Z
            m.pose.orientation.w = 1.0
            m.scale.x = 0.025
            m.scale.y = 0.025
            m.scale.z = 0.025
            # Red = sensing black (line); Green = sensing white (floor)
            if b > 0.5:
                m.color.r = 1.0; m.color.g = 0.0; m.color.b = 0.0
            else:
                m.color.r = 0.0; m.color.g = 1.0; m.color.b = 0.0
            m.color.a = 1.0
            ma.markers.append(m)
        self.marker_pub.publish(ma)


def main(args=None):
    rclpy.init(args=args)
    node = OpticalSensorNode()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
```

---

## ✅ Sub-Stage 3B-4 — Refactor the Line Follower (no more camera)

The old `line_follower_node.py` did two things: **(A)** read the camera and convert to 8 pixels, and **(B)** run PID on those 8 values. We're keeping (B) and ripping out (A) — it now subscribes to `/agv/line_sensors` (already in the right format thanks to Sub-Stage 3B-3).

### 📁 REPLACE the file: `~/warehouse_agv_sim/src/agv_control/agv_control/line_follower_node.py`

```python
#!/usr/bin/env python3
"""
Line Follower Node (optical sensor version)
-------------------------------------------
Subscribes to /agv/line_sensors (8 binary values from the optical_sensor_node),
computes the line offset, runs PID, and publishes /agv/cmd_vel.

This replaces the camera-based version. The PID logic is unchanged — only
the input source changed.
"""

import rclpy
from rclpy.node import Node

from std_msgs.msg import Bool, Float32MultiArray
from geometry_msgs.msg import Twist

import numpy as np


class LineFollowerNode(Node):

    def __init__(self):
        super().__init__('line_follower_node')

        # ---------------- Parameters ----------------
        self.declare_parameter('linear_speed', 0.30)
        self.declare_parameter('kp', 0.012)
        self.declare_parameter('ki', 0.000)
        self.declare_parameter('kd', 0.004)
        self.declare_parameter('enabled', True)
        # No more black_threshold / sample_row_ratio / num_samples — all gone

        self.linear_speed = self.get_parameter('linear_speed').value
        self.kp           = self.get_parameter('kp').value
        self.ki           = self.get_parameter('ki').value
        self.kd           = self.get_parameter('kd').value
        self.enabled      = self.get_parameter('enabled').value

        # ---------------- PID State ----------------
        self.prev_error      = 0.0
        self.integral        = 0.0
        self.last_offset     = 0.0
        self.line_lost_count = 0
        self.MAX_LOST_FRAMES = 15

        # ---------------- Subscriptions ----------------
        self.create_subscription(
            Float32MultiArray, '/agv/line_sensors',
            self.sensors_callback, 10
        )
        self.create_subscription(
            Bool, '/agv/line_follow_enable',
            self.enable_callback, 10
        )

        # ---------------- Publisher ----------------
        self.cmd_pub = self.create_publisher(Twist, '/agv/cmd_vel', 10)

        self.get_logger().info('🚀 Line Follower Node (optical) started')
        self.get_logger().info(
            f'   linear_speed={self.linear_speed:.2f}  '
            f'kp={self.kp:.4f}  ki={self.ki:.4f}  kd={self.kd:.4f}'
        )

    # ==========================================================
    def enable_callback(self, msg: Bool):
        self.enabled = msg.data
        state = "ENABLED" if self.enabled else "DISABLED"
        self.get_logger().info(f'🔧 Line follower {state}')
        if not self.enabled:
            self.cmd_pub.publish(Twist())  # stop

    # ==========================================================
    def sensors_callback(self, msg: Float32MultiArray):
        if not self.enabled:
            return
        if len(msg.data) == 0:
            return

        binary = np.array(msg.data, dtype=np.float32)
        offset, line_detected = self.compute_offset(binary)

        if line_detected:
            self.line_lost_count = 0
            angular_z = self.pid_step(offset)
            linear_x  = self.linear_speed
            self.last_offset = offset
        else:
            self.line_lost_count += 1
            if self.line_lost_count < self.MAX_LOST_FRAMES:
                # Brief grace period — keep last command at half speed
                angular_z = self.pid_step(self.last_offset) * 0.5
                linear_x  = self.linear_speed * 0.5
            else:
                angular_z = 0.0
                linear_x  = 0.0
                if self.line_lost_count == self.MAX_LOST_FRAMES:
                    self.get_logger().warn('⚠️  Line lost! Stopping.')

        twist = Twist()
        twist.linear.x  = float(linear_x)
        twist.angular.z = float(angular_z)
        self.cmd_pub.publish(twist)

    # ==========================================================
    def compute_offset(self, binary):
        """Weighted center-of-mass offset, normalized and scaled for PID."""
        if binary.sum() == 0:
            return 0.0, False

        indices = np.arange(len(binary))
        center_of_mass = float((indices * binary).sum() / binary.sum())
        center_index = (len(binary) - 1) / 2.0
        offset = center_of_mass - center_index
        offset_normalized = offset / center_index
        return offset_normalized * 100.0, True

    # ==========================================================
    def pid_step(self, error: float) -> float:
        self.integral += error
        self.integral = max(min(self.integral, 100.0), -100.0)
        derivative = error - self.prev_error
        output = (self.kp * error) + (self.ki * self.integral) + (self.kd * derivative)
        self.prev_error = error
        # Sign flip: positive error (line is right) → turn right (negative angular.z)
        return -output


def main(args=None):
    rclpy.init(args=args)
    node = LineFollowerNode()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.cmd_pub.publish(Twist())
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
```

---

## ✅ Sub-Stage 3B-5 — Update `setup.py`, `package.xml`, and Launch Files

### 📁 Edit: `~/warehouse_agv_sim/src/agv_control/setup.py`

In the `entry_points` block, **add the new node**:

```python
entry_points={
    'console_scripts': [
        'line_follower_node     = agv_control.line_follower_node:main',
        'optical_sensor_node    = agv_control.optical_sensor_node:main',  # ⭐ NEW
        'rfid_reader_node       = agv_control.rfid_reader_node:main',
        'junction_handler_node  = agv_control.junction_handler_node:main',
        'pivot_controller_node  = agv_control.pivot_controller_node:main',
        'arm_stub_node          = agv_control.arm_stub_node:main',
        'state_machine_node     = agv_control.state_machine_node:main',
        'send_order             = agv_control.send_order:main',
        'gui_node               = agv_control.gui_node:main',
    ],
},
```

### 📁 Edit: `~/warehouse_agv_sim/src/agv_control/package.xml`

**Remove** (no longer needed):
```xml
<exec_depend>cv_bridge</exec_depend>
<exec_depend>python3-opencv</exec_depend>
```

**Add** (for marker visualization):
```xml
<exec_depend>visualization_msgs</exec_depend>
```

### 📁 Edit: `~/warehouse_agv_sim/src/agv_control/launch/agv_brain.launch.py`

Add the optical sensor node to the launch list. Insert **before** `line_follower_node`:

```python
    Node(package='agv_control', executable='optical_sensor_node',
         name='optical_sensor_node', output='screen'),
    Node(package='agv_control', executable='line_follower_node',
         name='line_follower_node', output='screen', parameters=[params]),
    # ... rest of nodes unchanged
```

### 📁 Edit: `~/warehouse_agv_sim/src/agv_bringup/launch/full_demo.launch.py`

In the `brain_nodes` `TimerAction`, add the optical sensor node:

```python
brain_nodes = TimerAction(
    period=5.0,
    actions=[
        Node(package='agv_control', executable='optical_sensor_node',
             name='optical_sensor_node', output='screen'),
        Node(package='agv_control', executable='line_follower_node',
             name='line_follower_node', output='screen', parameters=[params_file]),
        # ... existing rfid/junction/pivot/arm/state_machine nodes
    ]
)
```

### 📁 Edit: `~/warehouse_agv_sim/src/agv_control/config/line_follower_params.yaml`

**Remove** these (no longer used):
```yaml
black_threshold: 80
sample_row_ratio: 0.75
num_samples: 8
publish_debug: true
```

**Keep** these:
```yaml
line_follower_node:
  ros__parameters:
    linear_speed: 0.30
    kp: 0.012
    ki: 0.000
    kd: 0.004
    enabled: true
```

---

## ✅ Sub-Stage 3B-6 — Update RViz Config (remove camera image panel)

### 📁 Edit: `~/warehouse_agv_sim/src/agv_description/rviz/agv_view.rviz`

**Find and DELETE** this block (the camera image display):

```yaml
- Class: rviz_default_plugins/Image
  Name: LineCamera
  Topic:
    Value: /agv/line_cam/image_raw
  Enabled: true
```

**Add** in its place (the marker array showing the 8 IR sensors):

```yaml
- Class: rviz_default_plugins/MarkerArray
  Name: IR Sensors
  Topic:
    Value: /agv/line_sensors_markers
  Enabled: true
```

---

# 🧪 Testing Checklist (Stage 3B Acceptance Criteria)

Build and verify in order:

```bash
cd ~/warehouse_agv_sim
colcon build --symlink-install
source install/setup.bash
```

### Test 1 — Track map sanity
```bash
python3 src/agv_control/agv_control/track_map.py
```
- ☐ Prints 6 segments, all 5 self-tests pass with ✅

### Test 2 — URDF still loads
```bash
ros2 launch agv_description display.launch.py
```
- ☐ AGV opens in RViz with 8 small blue dots on the bottom-front
- ☐ No camera-related errors in terminal

### Test 3 — Optical sensor publishes
```bash
ros2 launch agv_description spawn_agv.launch.py
# In another terminal:
source install/setup.bash
ros2 run agv_control optical_sensor_node
# In a third terminal:
ros2 topic echo /agv/line_sensors
```
- ☐ Binary arrays of length 8 stream at ~50 Hz
- ☐ Place AGV at HOME (-2, 0): all sensors should read 0 (off the lines)
- ☐ Drive AGV onto main aisle (use teleop): middle sensors flip to 1

### Test 4 — RViz marker visualization
- ☐ In RViz, add a `MarkerArray` display on `/agv/line_sensors_markers`
- ☐ See 8 colored dots tracking the AGV — red when on tape, green when on white floor

### Test 5 — Full mission
```bash
ros2 launch agv_bringup full_demo.launch.py
```
- ☐ All nodes start, including `optical_sensor_node`
- ☐ Send order S07 from the GUI
- ☐ AGV follows the line and completes the full mission

### Test 6 — Compare to old camera version
- ☐ No `cv_bridge` errors anywhere
- ☐ No `Image` topic warnings
- ☐ Mission completes more reliably than before
- ☐ CPU usage is lower (rough check via `htop`)

---

# 📋 Summary: Files Touched

| Status | File | Action |
|---|---|---|
| ✏️ Edit | `agv_description/urdf/sensors.xacro` | Remove camera, add 8 IR sensor links |
| ➕ New  | `agv_control/agv_control/track_map.py` | Defines tape geometry |
| ➕ New  | `agv_control/agv_control/optical_sensor_node.py` | Generates `/agv/line_sensors` from odom |
| ✏️ Edit | `agv_control/agv_control/line_follower_node.py` | Reads `/agv/line_sensors` instead of camera |
| ✏️ Edit | `agv_control/setup.py` | Register `optical_sensor_node` entry point |
| ✏️ Edit | `agv_control/package.xml` | Drop cv_bridge/opencv, add visualization_msgs |
| ✏️ Edit | `agv_control/launch/agv_brain.launch.py` | Add optical_sensor_node |
| ✏️ Edit | `agv_bringup/launch/full_demo.launch.py` | Add optical_sensor_node |
| ✏️ Edit | `agv_control/config/line_follower_params.yaml` | Drop camera-only params |
| ✏️ Edit | `agv_description/rviz/agv_view.rviz` | Replace camera image with marker array |

---

# 🎯 What Stayed The Same (No Changes Needed!)

This is the elegance of the change: because we kept `/agv/line_sensors` as the contract, **all of these work without modification**:

- ✅ State machine node
- ✅ RFID reader node
- ✅ Junction handler node
- ✅ Pivot controller node
- ✅ Arm stub node
- ✅ GUI node
- ✅ All custom messages (`Order`, `RFIDRead`, `AGVState`)
- ✅ The Tkinter GUI's color logic, queue, and order flow
- ✅ The Gazebo world file

---

# 🛠️ Common Issues + Fixes

| Issue | Likely Cause | Fix |
|---|---|---|
| All 8 sensors read 0 even on tape | `track_map.py` coordinates don't match `generate_world.py` | Open `generate_world.py`, copy exact tape coords into `track_map.py` |
| Sensors flicker rapidly | `LINE_WIDTH` too narrow vs sensor spacing | Increase `LINE_WIDTH` to 0.06 or 0.07 |
| AGV oscillates badly | PID was tuned for camera noise; IR is cleaner | Reduce `kp` by ~30% and `kd` by ~20% |
| Markers don't show in RViz | Wrong fixed frame | Set RViz Fixed Frame to `odom` |
| `optical_sensor_node` exits immediately | `/agv/odom` not yet publishing | Increase Gazebo startup delay or use `--ros-args -r` to verify topic |
| AGV "sees" line where there shouldn't be one | Spur extends into shelf zone | Adjust `SPUR_Y_END` in `track_map.py` |
| Build fails: `visualization_msgs not found` | Missing dep | `sudo apt install ros-humble-visualization-msgs` |
| Launch error: `unknown executable optical_sensor_node` | `setup.py` not rebuilt | `colcon build --packages-select agv_control --symlink-install` |

---

# 🔮 Bonus: Why This Helps Your Hardware Build (Phase 6)

When you build the IRL version, your ESP32 firmware will read 8 analog values from the TCRT5000 and threshold them:

```cpp
// On ESP32 — equivalent to optical_sensor_node.py
for (int i = 0; i < 8; i++) {
    int raw = analogRead(IR_PINS[i]);
    binary[i] = (raw < IR_BLACK_THRESHOLD) ? 1 : 0;
}
// Then run the SAME PID logic that's in your line_follower_node
```

The mental model is now identical between sim and hardware:
**Read 8 binary values → compute weighted center → PID → drive motors.**

No more camera-vs-sensor mental gymnastics. 🎯

---

🚀 **Once all 6 tests pass, you're caught up to where Stage 3 was supposed to leave you — and you're already 50% of the way to the hardware build.**
