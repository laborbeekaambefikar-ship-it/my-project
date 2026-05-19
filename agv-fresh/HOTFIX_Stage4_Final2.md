# 🔥 HOTFIX — state_node Crash + AGV Idle Fix + Sensor Warning

## Three Issues Fixed Here

1. `AttributeError: 'StateNode' object has no attribute '_pivot_nudge_timer'` → node crashes
2. AGV doesn't turn at the correct junction (wrong velocity topics)
3. `[Sensor.cc:510] Get noise index not valid` Gazebo warning

---

# Issue 1 + 2 — Complete Working `state_node.py`

The crash was caused by the previous patch creating a timer inside a callback without declaring the attribute in `__init__`. This version fixes that AND uses the correct arbiter pattern.

## Step 1 — Replace `state_node.py`

```bash
nano ~/agv_ws/src/agv_brain/agv_brain/state_node.py
```

Delete everything. Paste:

```python
#!/usr/bin/env python3
"""
state_node.py — Mission orchestrator AND cmd_vel arbiter.

States:
  IDLE -> GOING -> AT_SHELF -> WAITING -> PIVOTING
       -> PIVOT_NUDGE -> RETURNING -> IDLE

PIVOT_NUDGE: after 180° pivot, drive forward 15 cm before line follower starts.
ONLY this node publishes /agv/cmd_vel.
"""
import math
import rclpy
from rclpy.node import Node
from std_msgs.msg import Bool, String, Float32
from geometry_msgs.msg import Twist
from agv_msgs.msg import Order, RFIDRead, AGVState
from agv_brain.shelf_lib import SHELF_MAP

IDLE        = 'IDLE'
GOING       = 'GOING'
AT_SHELF    = 'AT_SHELF'
WAITING     = 'WAITING'
PIVOTING    = 'PIVOTING'
PIVOT_NUDGE = 'PIVOT_NUDGE'
RETURNING   = 'RETURNING'

NUDGE_SPEED    = 0.20   # m/s
NUDGE_DURATION = 0.75   # seconds  →  15 cm


class StateNode(Node):
    def __init__(self):
        super().__init__('state_node')

        # Mission state
        self.state          = IDLE
        self.order          = None
        self.last_rfid      = ''
        self.junction_count = 0
        self.turning        = False

        # Junction cooldowns
        self.last_junc_t           = 0.0
        self.JUNC_COOLDOWN         = 1.5
        self.post_turn_block_until = 0.0
        self.POST_TURN_BLOCK       = 2.5

        # Pivot nudge — ALL declared here to avoid AttributeError
        self.pivot_nudge_start = None
        self._nudge_twist = Twist()
        self._nudge_twist.linear.x = NUDGE_SPEED

        # Velocity buffers from worker nodes
        self.follow_vel = Twist()
        self.turn_vel   = Twist()
        self.pivot_vel  = Twist()

        # Subscriptions: velocities
        self.create_subscription(Twist, '/agv/follow_vel', self.fv_cb, 10)
        self.create_subscription(Twist, '/agv/turn_vel',   self.tv_cb, 10)
        self.create_subscription(Twist, '/agv/pivot_vel',  self.pv_cb, 10)

        # Subscriptions: events
        self.create_subscription(Order,    '/agv/order',             self.order_cb,      10)
        self.create_subscription(RFIDRead, '/agv/rfid_detected',     self.rfid_cb,       10)
        self.create_subscription(Bool,     '/agv/junction_detected', self.junc_cb,       10)
        self.create_subscription(Bool,     '/agv/turn_done',         self.turn_done_cb,  10)
        self.create_subscription(Bool,     '/arm/done',              self.arm_done_cb,   10)
        self.create_subscription(Bool,     '/agv/pivot_done',        self.pivot_done_cb, 10)

        # Publishers — ONLY this node publishes /agv/cmd_vel
        self.cmd_pub   = self.create_publisher(Twist,    '/agv/cmd_vel',  10)
        self.turn_pub  = self.create_publisher(String,   '/agv/turn_cmd', 10)
        self.pivot_pub = self.create_publisher(Float32,  '/agv/pivot_cmd',10)
        self.arm_pub   = self.create_publisher(Bool,     '/arm/start',    10)
        self.state_pub = self.create_publisher(AGVState, '/agv/state',    10)

        self.create_timer(0.02, self.arbiter)
        self.create_timer(0.5,  self.broadcast_state)

        self.get_logger().info('state_node ready — sole publisher of /agv/cmd_vel')

    # Velocity buffer callbacks
    def fv_cb(self, msg): self.follow_vel = msg
    def tv_cb(self, msg): self.turn_vel   = msg
    def pv_cb(self, msg): self.pivot_vel  = msg

    # THE ARBITER — 50 Hz, decides who drives
    def arbiter(self):
        if self.state in (IDLE, AT_SHELF, WAITING):
            self.cmd_pub.publish(Twist())

        elif self.state == PIVOT_NUDGE:
            elapsed = self.now_s() - self.pivot_nudge_start
            if elapsed >= NUDGE_DURATION:
                self.get_logger().info(
                    f'pivot nudge done ({elapsed:.2f}s) — line follow starting')
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
        if s == self.state:
            return
        self.get_logger().info(f'STATE: {self.state} -> {s}')
        self.state = s
        self.broadcast_state()

    def broadcast_state(self):
        m = AGVState()
        m.state          = self.state
        m.current_target = self.order.shelf_id if self.order else ''
        m.last_rfid      = self.last_rfid
        self.state_pub.publish(m)

    def order_cb(self, msg):
        if self.state != IDLE:
            self.get_logger().warn(f'order ignored — state={self.state}')
            return
        if msg.shelf_id not in SHELF_MAP:
            self.get_logger().error(f'unknown shelf: {msg.shelf_id}')
            return
        self.order          = msg
        self.junction_count = 0
        info = SHELF_MAP[msg.shelf_id]
        self.get_logger().info(
            f'ORDER: {msg.shelf_id}  aisle={info["aisle"]}  sku={msg.sku}')
        self.set_state(GOING)

    def junc_cb(self, msg):
        if not msg.data:
            return
        t = self.now_s()
        if t < self.post_turn_block_until:
            return
        if t - self.last_junc_t < self.JUNC_COOLDOWN:
            return
        if self.turning:
            return
        self.last_junc_t = t

        if self.state == GOING and self.order:
            self.junction_count += 1
            target = SHELF_MAP[self.order.shelf_id]['aisle']
            self.get_logger().info(
                f'junction #{self.junction_count}  (target aisle {target})')
            if self.junction_count == target:
                self._do_turn('left')

        elif self.state == RETURNING:
            self.get_logger().info('return junction — turning right')
            self._do_turn('right')

    def _do_turn(self, direction):
        self.turning = True
        m = String(); m.data = direction
        self.turn_pub.publish(m)
        self.get_logger().info(f'turn requested: {direction}')

    def turn_done_cb(self, msg):
        if not msg.data:
            return
        self.turning = False
        self.post_turn_block_until = self.now_s() + self.POST_TURN_BLOCK
        self.get_logger().info(
            f'turn done — junctions blocked {self.POST_TURN_BLOCK}s')

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
        if not msg.data or self.state != WAITING:
            return
        self.get_logger().info('arm done — pivoting 180')
        self.set_state(PIVOTING)
        p = Float32(); p.data = math.pi
        self.pivot_pub.publish(p)

    def pivot_done_cb(self, msg):
        if not msg.data or self.state != PIVOTING:
            return
        self.pivot_nudge_start = self.now_s()
        self.junction_count    = 0
        self.get_logger().info(
            f'pivot done — nudging {NUDGE_DURATION}s @ {NUDGE_SPEED}m/s')
        self.set_state(PIVOT_NUDGE)


def main(args=None):
    rclpy.init(args=args)
    node = StateNode()
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

## Step 2 — Verify `follow_node.py` publishes to the RIGHT topic

This is the #1 cause of "AGV doesn't turn at the right junction."

Run:
```bash
grep "follow_vel\|cmd_vel" ~/agv_ws/src/agv_brain/agv_brain/follow_node.py | head -5
```

You must see `/agv/follow_vel`. If you see `/agv/cmd_vel` instead, your
`follow_node.py` is the OLD version from Stage 3. Replace it with the
version from `HOTFIX_AGV_Not_Moving.md` Step 1.

Quick check of the correct topic names:
```
follow_node  → /agv/follow_vel   ✓
turn_node    → /agv/turn_vel     ✓
pivot_node   → /agv/pivot_vel    ✓
state_node   → /agv/cmd_vel      ✓ (sole publisher)
```

If ANY of the first three publish directly to `/agv/cmd_vel`, the arbiter
is bypassed and the junction/turn logic breaks.

---

## Step 3 — Verify all 4 nodes publish to the right topics

Run this diagnostic while brain.launch.py is running:

```bash
source ~/agv_ws/install/setup.bash
ros2 topic info /agv/cmd_vel --verbose
```

You must see **exactly 1 publisher: state_node**.

```bash
ros2 topic info /agv/follow_vel --verbose
```

Must show 1 publisher: follow_node.

```bash
ros2 topic info /agv/turn_vel --verbose
```

Must show 1 publisher: turn_node.

If any of these show the wrong publisher, that file still has the old code.

---

## Step 4 — Rebuild and test

```bash
cd ~/agv_ws
colcon build --symlink-install --packages-select agv_brain
source install/setup.bash
```

Then:
```bash
pkill -9 -f ros2; pkill -9 -f gz; pkill -9 -f rviz; sleep 3
```

Terminal 1:
```bash
source ~/agv_ws/install/setup.bash
ros2 launch agv_robot spawn.launch.py
```

Terminal 2:
```bash
source ~/agv_ws/install/setup.bash
ros2 launch agv_brain brain.launch.py
```

Terminal 3 (after ~5s):
```bash
source ~/agv_ws/install/setup.bash
ros2 run agv_brain send S05
```

---

# Issue 3 — Fix `[Sensor.cc:510] Get noise index not valid`

## What This Error Means

This is a **harmless Gazebo warning** from the IMU plugin. It does NOT
affect the AGV — the IMU still works correctly. The warning appears because
the IMU sensor in the URDF doesn't specify noise parameters and Gazebo's
internal Sensor.cc tries to access a noise index that was never set.

It will spam your terminal but won't break anything. You have two options:

## Option A — Just ignore it (recommended)

The IMU works. The AGV turns correctly using the IMU yaw. The warning is
cosmetic noise. Many real ROS projects ship with this warning.

## Option B — Silence it by adding noise config to the URDF

Open the URDF:
```bash
nano ~/agv_ws/src/agv_robot/urdf/agv.urdf.xacro
```

Find the IMU plugin section:
```xml
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
```

Replace it with this version that includes explicit noise config:

```xml
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
          <namespace>/agv</namespace>
          <remapping>~/out:=imu</remapping>
        </ros>
        <frame_name>imu_link</frame_name>
      </plugin>
    </sensor>
  </gazebo>
```

Then rebuild:
```bash
cd ~/agv_ws
colcon build --symlink-install --packages-select agv_robot
source install/setup.bash
```

Relaunch and the `[Sensor.cc:510]` warnings should be gone.

---

# Troubleshooting: AGV Still Doesn't Turn

## Diagnosis 1: Junction not being detected

While the AGV is driving, watch:
```bash
ros2 topic echo /agv/junction_detected
```

When the AGV crosses a junction (X=0, X=3, etc.) you should see:
```
data: true
---
```

If nothing appears, the sensors are not seeing the junction.
This means either:
- `LINE_WIDTH` in `track_lib.py` is still 0.05 (too narrow)
- The junction threshold in `follow_node.py` is too high

Fix: In `follow_node.py`, find `self.JUNC_THRESH = 6` and lower it to `5`.
In `track_lib.py`, confirm `LINE_WIDTH = 0.10`.

## Diagnosis 2: Junction detected but turn not triggered

Watch:
```bash
ros2 topic echo /agv/state
```

If state stays GOING but no turn happens after the correct junction,
check that `state_node.py` is the version with the arbiter
(`state_node ready — sole publisher`). If it says `state_node ready (state=IDLE)`
you have the OLD version from Stage 4 that doesn't have the arbiter.

## Diagnosis 3: Turn triggered but AGV doesn't move during turn

Watch:
```bash
ros2 topic echo /agv/cmd_vel
```

During the turn, you should see `angular.z: ±0.5`. If you see zeros,
either `turn_node.py` is the old sensor-based version OR it still
publishes to `/agv/cmd_vel` directly (bypassing the arbiter and causing
a conflict with `state_node`).

Check:
```bash
grep "turn_vel\|cmd_vel" ~/agv_ws/src/agv_brain/agv_brain/turn_node.py | head -5
```

Must show `turn_vel`. If it shows `cmd_vel`, replace `turn_node.py`
with the version from `HOTFIX_AGV_Not_Moving.md` Step 2 (the IMU-yaw
version from `HOTFIX_Junction_Turn.md`).

---

## Summary: Correct File Versions

| File | Must contain | Check command |
|---|---|---|
| `follow_node.py` | `follow_vel` | `grep follow_vel follow_node.py` |
| `turn_node.py` | `turn_vel` + `yaw_from_quat` | `grep turn_vel turn_node.py` |
| `pivot_node.py` | `pivot_vel` | `grep pivot_vel pivot_node.py` |
| `state_node.py` | `PIVOT_NUDGE` + `arbiter` | `grep PIVOT_NUDGE state_node.py` |
| `track_lib.py` | `LINE_WIDTH = 0.10` | `grep LINE_WIDTH track_lib.py` |
| `follow_node.py` | `MAX_LOST = 80` | `grep MAX_LOST follow_node.py` |
