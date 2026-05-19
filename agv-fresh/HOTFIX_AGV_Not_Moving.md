# 🔥 HOTFIX — AGV Not Moving (Two Publishers Fighting)

## The Real Problem

You found 2 publishers on `/agv/cmd_vel`:
```
Publishers: follow_node, pivot_node
```

This is the **fundamental bug**. Three nodes (`follow_node`, `turn_node`, `pivot_node`) all publish directly to `/agv/cmd_vel`. Even when one is "disabled", if it publishes even a single Twist message at the wrong moment, the two commands mix together and the robot gets confused or stops.

No amount of timing fixes or delays will permanently fix this.

## The Permanent Fix — Single Arbiter

The correct pattern is: **only ONE node publishes `/agv/cmd_vel`** — the `state_node`.

Every other node sends its desired velocity to its own private topic. The `state_node` reads them all but only forwards the one that matches the current mission state.

```
BEFORE (broken):
  follow_node ──────────────────────────► /agv/cmd_vel  ← FIGHT!
  turn_node   ──────────────────────────► /agv/cmd_vel  ← FIGHT!
  pivot_node  ──────────────────────────► /agv/cmd_vel  ← FIGHT!

AFTER (fixed):
  follow_node  ──► /agv/follow_vel  ──┐
  turn_node    ──► /agv/turn_vel    ──┤─► state_node ──► /agv/cmd_vel  ← ONLY ONE
  pivot_node   ──► /agv/pivot_vel   ──┘
```

The `state_node` acts as an arbiter:
- State=GOING or RETURNING → forward `/agv/follow_vel`
- State=PIVOTING           → forward `/agv/pivot_vel`
- During a junction turn   → forward `/agv/turn_vel`
- State=IDLE/WAITING       → forward zero (stop)

---

## What You Need to Change

You need to **replace 4 files** with the versions below.
Everything else (optical_node, rfid_node, arm_node, shelf_lib, track_lib, messages) stays exactly the same.

| File | Change |
|---|---|
| `follow_node.py` | Publishes to `/agv/follow_vel` instead of `/agv/cmd_vel` |
| `turn_node.py` | Publishes to `/agv/turn_vel` instead of `/agv/cmd_vel` |
| `pivot_node.py` | Publishes to `/agv/pivot_vel` instead of `/agv/cmd_vel` |
| `state_node.py` | Now the ONLY publisher of `/agv/cmd_vel`; arbitrates between the three |

---

## Step 1 — Replace `follow_node.py`

```bash
nano ~/agv_ws/src/agv_brain/agv_brain/follow_node.py
```

Delete everything and paste:

```python
#!/usr/bin/env python3
"""
follow_node.py — PID line follower.

CHANGED: publishes to /agv/follow_vel (NOT /agv/cmd_vel).
state_node reads /agv/follow_vel and forwards it to /agv/cmd_vel
only when the mission state says the line follower should be in control.
This eliminates the multi-publisher fight permanently.
"""
import rclpy
from rclpy.node import Node
from std_msgs.msg import Bool, Float32MultiArray
from geometry_msgs.msg import Twist
import numpy as np


class FollowNode(Node):
    def __init__(self):
        super().__init__('follow_node')

        self.declare_parameter('linear_speed', 0.50)
        self.declare_parameter('kp',  0.50)
        self.declare_parameter('ki',  0.00)
        self.declare_parameter('kd',  0.15)
        # Note: 'enabled' param removed — state_node controls this via arbitration now

        self.linear_speed = self.get_parameter('linear_speed').value
        self.kp = self.get_parameter('kp').value
        self.ki = self.get_parameter('ki').value
        self.kd = self.get_parameter('kd').value

        # PID state
        self.prev_err    = 0.0
        self.integral    = 0.0
        self.last_offset = 0.0
        self.lost_count  = 0
        self.MAX_LOST    = 25  # 0.5 s grace at 50 Hz

        # Junction debounce
        self.JUNC_THRESH  = 6   # sensors that must be black to call it a junction
        self.JUNC_STREAK  = 2   # consecutive frames needed
        self.junc_count   = 0
        self.junc_fired   = False

        self.create_subscription(
            Float32MultiArray, '/agv/line_sensors', self.sensors_cb, 10)
        self.junction_pub = self.create_publisher(
            Bool, '/agv/junction_detected', 10)

        # ── KEY CHANGE ──────────────────────────────────────────────────
        # Publish desired velocity to a PRIVATE topic.
        # state_node will forward it to /agv/cmd_vel only when appropriate.
        self.vel_pub = self.create_publisher(Twist, '/agv/follow_vel', 10)
        # ────────────────────────────────────────────────────────────────

        self.frame = 0
        self.get_logger().info(
            f'follow_node ready  speed={self.linear_speed}  '
            f'kp={self.kp}  kd={self.kd}  → publishing to /agv/follow_vel'
        )

    # ------------------------------------------------------------------
    def sensors_cb(self, msg):
        if len(msg.data) < 8:
            return
        binary = np.array(msg.data, dtype=np.float32)
        black  = int(binary.sum())

        # ── Junction detection ──────────────────────────────────────────
        if black >= self.JUNC_THRESH:
            self.junc_count += 1
            if self.junc_count >= self.JUNC_STREAK and not self.junc_fired:
                j = Bool(); j.data = True
                self.junction_pub.publish(j)
                self.junc_fired = True
        else:
            self.junc_count = 0
            self.junc_fired = False

        # ── At a junction: publish straight-ahead velocity ───────────────
        # (state_node may ignore this during a turn, but it's harmless)
        if black >= self.JUNC_THRESH:
            t = Twist(); t.linear.x = self.linear_speed
            self.vel_pub.publish(t)
            return

        # ── Normal PID ──────────────────────────────────────────────────
        offset, detected = self._offset(binary)

        if detected:
            self.lost_count  = 0
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

    # ------------------------------------------------------------------
    def _offset(self, binary):
        if binary.sum() == 0:
            return 0.0, False
        idx    = np.arange(len(binary))
        com    = float((idx * binary).sum() / binary.sum())
        center = (len(binary) - 1) / 2.0
        return (com - center) / center, True

    def _pid(self, error):
        self.integral += error
        self.integral  = max(min(self.integral, 2.0), -2.0)
        d   = error - self.prev_err
        out = self.kp*error + self.ki*self.integral + self.kd*d
        self.prev_err = error
        return -max(min(out, 1.5), -1.5)


def main(args=None):
    rclpy.init(args=args)
    node = FollowNode()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.vel_pub.publish(Twist())   # publish zero to own topic on shutdown
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
```

---

## Step 2 — Replace `turn_node.py`

```bash
nano ~/agv_ws/src/agv_brain/agv_brain/turn_node.py
```

Delete everything and paste:

```python
#!/usr/bin/env python3
"""
turn_node.py — Executes a 90° junction turn.

CHANGED: publishes to /agv/turn_vel (NOT /agv/cmd_vel).
state_node forwards /agv/turn_vel to /agv/cmd_vel only while
self.turning is True in state_node.
"""
import rclpy
from rclpy.node import Node
from std_msgs.msg import String, Bool, Float32MultiArray
from geometry_msgs.msg import Twist


class TurnNode(Node):
    def __init__(self):
        super().__init__('turn_node')

        self.turn_speed     = 0.60   # rad/s
        self.fwd_speed      = 0.10   # m/s forward during turn
        self.timeout        = 6.0    # safety cutoff (seconds)
        self.confirm_frames = 3      # consecutive frames of line = done
        self.warmup_secs    = 0.35   # full stop before starting to turn

        self.turning      = False
        self.warmup_done  = False
        self.direction    = 0
        self.start_time   = None
        self.line_count   = 0
        self.sensors      = [0.0] * 8

        self.create_subscription(
            String, '/agv/turn_cmd', self.cmd_cb, 10)
        self.create_subscription(
            Float32MultiArray, '/agv/line_sensors', self.sensors_cb, 10)

        # ── KEY CHANGE ──────────────────────────────────────────────────
        self.vel_pub  = self.create_publisher(Twist, '/agv/turn_vel', 10)
        # ────────────────────────────────────────────────────────────────
        self.done_pub = self.create_publisher(Bool,  '/agv/turn_done', 10)

        self.create_timer(0.05, self.tick)
        self.get_logger().info('turn_node ready → publishing to /agv/turn_vel')

    def cmd_cb(self, msg):
        d = msg.data.lower().strip()
        if   d == 'left':  self.direction = +1
        elif d == 'right': self.direction = -1
        else:
            self.get_logger().warn(f'unknown turn cmd: {msg.data}')
            return
        self.get_logger().info(f'turn START: {d.upper()}')
        self.turning     = True
        self.warmup_done = False
        self.start_time  = self.get_clock().now()
        self.line_count  = 0

    def sensors_cb(self, msg):
        if len(msg.data) >= 8:
            self.sensors = list(msg.data)

    def tick(self):
        if not self.turning:
            # Always publish zero so arbiter has something to read
            self.vel_pub.publish(Twist())
            return

        elapsed = (self.get_clock().now() - self.start_time).nanoseconds / 1e9

        # ── Warmup: sit still before starting to turn ──────────────────
        if not self.warmup_done:
            self.vel_pub.publish(Twist())          # full stop
            if elapsed >= self.warmup_secs:
                self.warmup_done = True
                self.start_time  = self.get_clock().now()   # reset for actual turn
            return

        elapsed = (self.get_clock().now() - self.start_time).nanoseconds / 1e9

        # ── Safety timeout ─────────────────────────────────────────────
        if elapsed > self.timeout:
            self.get_logger().warn('turn TIMEOUT — finishing anyway')
            self.finish()
            return

        # ── After 0.5 s, watch for line reacquisition ─────────────────
        if elapsed > 0.5:
            black = sum(1 for s in self.sensors if s > 0.5)
            if 1 <= black <= 4:
                self.line_count += 1
            else:
                self.line_count = 0
            if self.line_count >= self.confirm_frames:
                self.get_logger().info(f'turn done @ {elapsed:.1f}s')
                self.finish()
                return

        # ── Publish turn velocity ──────────────────────────────────────
        t = Twist()
        t.linear.x  = self.fwd_speed
        t.angular.z = self.turn_speed * self.direction
        self.vel_pub.publish(t)

    def finish(self):
        self.turning = False
        self.vel_pub.publish(Twist())          # zero out own topic
        d = Bool(); d.data = True
        self.done_pub.publish(d)


def main(args=None):
    rclpy.init(args=args)
    node = TurnNode()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()


---

## Step 3 — Replace `pivot_node.py`

```bash
nano ~/agv_ws/src/agv_brain/agv_brain/pivot_node.py
```

Delete everything and paste:

```python
#!/usr/bin/env python3
"""
pivot_node.py — In-place 180° rotation.

CHANGED: publishes to /agv/pivot_vel (NOT /agv/cmd_vel).
state_node forwards /agv/pivot_vel to /agv/cmd_vel only when
state == PIVOTING.
"""
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
    while d >  math.pi: d -= 2 * math.pi
    while d < -math.pi: d += 2 * math.pi
    return d


class PivotNode(Node):
    def __init__(self):
        super().__init__('pivot_node')

        self.angular_speed = 0.70   # rad/s
        self.tolerance     = 0.05   # rad (~3°)
        self.current_yaw   = 0.0
        self.target_yaw    = None
        self.pivoting      = False

        self.create_subscription(Odometry, '/agv/odom',       self.odom_cb, 10)
        self.create_subscription(Float32,  '/agv/pivot_cmd',  self.cmd_cb,  10)

        # ── KEY CHANGE ──────────────────────────────────────────────────
        self.vel_pub  = self.create_publisher(Twist, '/agv/pivot_vel', 10)
        # ────────────────────────────────────────────────────────────────
        self.done_pub = self.create_publisher(Bool,  '/agv/pivot_done', 10)

        self.create_timer(0.05, self.tick)
        self.get_logger().info('pivot_node ready → publishing to /agv/pivot_vel')

    def odom_cb(self, msg):
        self.current_yaw = yaw_from_quat(msg.pose.pose.orientation)

    def cmd_cb(self, msg):
        angle = float(msg.data)
        self.target_yaw = self.current_yaw + angle
        while self.target_yaw >  math.pi: self.target_yaw -= 2 * math.pi
        while self.target_yaw < -math.pi: self.target_yaw += 2 * math.pi
        self.pivoting = True
        self.get_logger().info(f'pivot start: {math.degrees(angle):.0f} deg')

    def tick(self):
        if not self.pivoting or self.target_yaw is None:
            # Always publish zero when idle so arbiter has something to read
            self.vel_pub.publish(Twist())
            return

        err = angle_diff(self.target_yaw, self.current_yaw)

        if abs(err) < self.tolerance:
            self.vel_pub.publish(Twist())          # zero out own topic
            self.pivoting   = False
            self.target_yaw = None
            d = Bool(); d.data = True
            self.done_pub.publish(d)
            self.get_logger().info('pivot done')
            return

        t = Twist()
        t.angular.z = self.angular_speed * (1 if err > 0 else -1)
        self.vel_pub.publish(t)


def main(args=None):
    rclpy.init(args=args)
    node = PivotNode()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.vel_pub.publish(Twist())
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
```

---

## Step 4 — Replace `state_node.py` (now the sole arbiter)

This is the biggest change. `state_node` now:
1. Subscribes to `/agv/follow_vel`, `/agv/turn_vel`, `/agv/pivot_vel`
2. Has a 50 Hz timer that publishes the RIGHT one to `/agv/cmd_vel` based on current state
3. Never has a race condition because there is only one publisher on `/agv/cmd_vel`

```bash
nano ~/agv_ws/src/agv_brain/agv_brain/state_node.py
```

Delete everything and paste:

```python
#!/usr/bin/env python3
"""
state_node.py — Mission orchestrator AND cmd_vel arbiter.

ONLY this node publishes to /agv/cmd_vel. It reads from:
  /agv/follow_vel  — desired velocity from follow_node
  /agv/turn_vel    — desired velocity from turn_node
  /agv/pivot_vel   — desired velocity from pivot_node

And forwards the correct one based on state:
  IDLE / WAITING / AT_SHELF  → zero  (stopped)
  GOING / RETURNING          → follow_vel  (unless turning)
  turning flag               → turn_vel
  PIVOTING                   → pivot_vel

States:
  IDLE -> GOING -> AT_SHELF -> WAITING -> PIVOTING -> RETURNING -> IDLE
"""

import math
import rclpy
from rclpy.node import Node
from std_msgs.msg import Bool, String, Float32
from geometry_msgs.msg import Twist
from agv_msgs.msg import Order, RFIDRead, AGVState
from agv_brain.shelf_lib import SHELF_MAP

IDLE      = 'IDLE'
GOING     = 'GOING'
AT_SHELF  = 'AT_SHELF'
WAITING   = 'WAITING'
PIVOTING  = 'PIVOTING'
RETURNING = 'RETURNING'


class StateNode(Node):
    def __init__(self):
        super().__init__('state_node')

        # ── Mission state ──────────────────────────────────────────────
        self.state          = IDLE
        self.order          = None
        self.last_rfid      = ''
        self.junction_count = 0
        self.turning        = False

        # Junction cooldown (avoid counting same junction twice)
        self.last_junc_t    = 0.0
        self.JUNC_COOLDOWN  = 1.5   # seconds

        # ── Buffered velocities from worker nodes ──────────────────────
        self.follow_vel = Twist()   # from follow_node
        self.turn_vel   = Twist()   # from turn_node
        self.pivot_vel  = Twist()   # from pivot_node

        # ── Subscriptions: worker velocities ──────────────────────────
        self.create_subscription(Twist, '/agv/follow_vel', self.fv_cb,  10)
        self.create_subscription(Twist, '/agv/turn_vel',   self.tv_cb,  10)
        self.create_subscription(Twist, '/agv/pivot_vel',  self.pv_cb,  10)

        # ── Subscriptions: events ─────────────────────────────────────
        self.create_subscription(Order,    '/agv/order',            self.order_cb,      10)
        self.create_subscription(RFIDRead, '/agv/rfid_detected',    self.rfid_cb,       10)
        self.create_subscription(Bool,     '/agv/junction_detected', self.junc_cb,      10)
        self.create_subscription(Bool,     '/agv/turn_done',         self.turn_done_cb, 10)
        self.create_subscription(Bool,     '/arm/done',              self.arm_done_cb,  10)
        self.create_subscription(Bool,     '/agv/pivot_done',        self.pivot_done_cb,10)

        # ── Publishers ────────────────────────────────────────────────
        # THE ONLY publisher of /agv/cmd_vel in the entire system
        self.cmd_pub   = self.create_publisher(Twist,    '/agv/cmd_vel',  10)
        self.turn_pub  = self.create_publisher(String,   '/agv/turn_cmd', 10)
        self.pivot_pub = self.create_publisher(Float32,  '/agv/pivot_cmd',10)
        self.arm_pub   = self.create_publisher(Bool,     '/arm/start',    10)
        self.state_pub = self.create_publisher(AGVState, '/agv/state',    10)

        # ── 50 Hz arbiter loop ────────────────────────────────────────
        self.create_timer(0.02, self.arbiter)

        # ── 2 Hz state broadcast ─────────────────────────────────────
        self.create_timer(0.5, self.broadcast_state)

        self.get_logger().info('state_node ready — SOLE publisher of /agv/cmd_vel')

    # ==================================================================
    # Velocity buffers — just cache what each worker wants to do
    # ==================================================================
    def fv_cb(self, msg): self.follow_vel = msg
    def tv_cb(self, msg): self.turn_vel   = msg
    def pv_cb(self, msg): self.pivot_vel  = msg

    # ==================================================================
    # THE ARBITER — runs at 50 Hz, decides who drives
    # ==================================================================
    def arbiter(self):
        if self.state in (IDLE, AT_SHELF, WAITING):
            self.cmd_pub.publish(Twist())          # full stop

        elif self.turning:
            self.cmd_pub.publish(self.turn_vel)    # junction turn

        elif self.state == PIVOTING:
            self.cmd_pub.publish(self.pivot_vel)   # 180° spin

        elif self.state in (GOING, RETURNING):
            self.cmd_pub.publish(self.follow_vel)  # PID line following

        else:
            self.cmd_pub.publish(Twist())          # default: stop

    # ==================================================================
    # Helpers
    # ==================================================================
    def now(self):
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

    # ==================================================================
    # Event handlers
    # ==================================================================
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
        # Note: no need to enable follow_node — arbiter auto-forwards follow_vel

    def junc_cb(self, msg):
        if not msg.data:
            return
        if self.now() - self.last_junc_t < self.JUNC_COOLDOWN:
            return
        if self.turning:
            return
        self.last_junc_t = self.now()

        if self.state == GOING and self.order:
            self.junction_count += 1
            target = SHELF_MAP[self.order.shelf_id]['aisle']
            self.get_logger().info(
                f'junction #{self.junction_count}  (target aisle {target})')
            if self.junction_count == target:
                self._do_turn('left')

        elif self.state == RETURNING:
            self.get_logger().info('return junction — turning onto main aisle')
            self._do_turn('right')

    def _do_turn(self, direction):
        self.turning = True
        # Arbiter will now forward turn_vel — follow_vel is automatically ignored
        m = String(); m.data = direction
        self.turn_pub.publish(m)
        self.get_logger().info(f'turn requested: {direction}')

    def turn_done_cb(self, msg):
        if not msg.data:
            return
        self.turning = False
        # Arbiter automatically switches back to follow_vel
        self.get_logger().info('turn complete — resuming line following')

    def rfid_cb(self, msg):
        self.last_rfid = msg.tag_id

        if self.state == GOING and self.order and msg.tag_id == self.order.shelf_id:
            self.get_logger().info(f'TARGET REACHED: {msg.tag_id}')
            # Arbiter stops the AGV automatically (state=AT_SHELF)
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
        self.get_logger().info('arm done — pivoting 180°')
        self.set_state(PIVOTING)
        p = Float32(); p.data = math.pi
        self.pivot_pub.publish(p)

    def pivot_done_cb(self, msg):
        if not msg.data or self.state != PIVOTING:
            return
        self.get_logger().info('pivot done — starting return')
        self.junction_count = 0
        self.set_state(RETURNING)
        # Arbiter automatically starts forwarding follow_vel again


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

## Step 5 — Update `follow_params.yaml` (remove `enabled`)

```bash
nano ~/agv_ws/src/agv_brain/config/follow_params.yaml
```

Replace with:

```yaml
follow_node:
  ros__parameters:
    linear_speed: 0.50
    kp: 0.50
    ki: 0.00
    kd: 0.15
    # Note: 'enabled' removed — state_node's arbiter handles this now
```

---

## Step 6 — Rebuild

```bash
cd ~/agv_ws
colcon build --symlink-install --packages-select agv_brain
source install/setup.bash
```

Expected: `1 package finished` with no errors.

---

## Step 7 — Verify only 1 publisher on `/agv/cmd_vel`

```bash
# Kill everything first
pkill -9 -f ros2; pkill -9 -f gz; pkill -9 -f rviz; sleep 2

# Terminal 1
source ~/agv_ws/install/setup.bash
ros2 launch agv_robot spawn.launch.py

# Terminal 2 (new terminal)
source ~/agv_ws/install/setup.bash
ros2 launch agv_brain brain.launch.py

# Terminal 3 (new terminal) — run this check
source ~/agv_ws/install/setup.bash
ros2 topic info /agv/cmd_vel --verbose
```

You should now see **exactly 1 publisher**:
```
Publisher count: 1
Node name: state_node
```

If you see more than 1 — one of the 4 files above wasn't saved correctly. Check which node is publishing:
```bash
ros2 topic info /agv/cmd_vel --verbose
```
It will list the node names. Find the unexpected publisher and re-paste that file.

---

## Step 8 — Test Full Mission

```bash
# Terminal 3
ros2 run agv_brain send S05
```

Watch Terminal 2 for this sequence:
```
[state_node]  STATE: IDLE -> GOING
[follow_node] [....##....]  off=+0.00  lin=0.50    ← driving on main aisle
[state_node]  junction #1  (target aisle 2)
[state_node]  junction #2  (target aisle 2)
[state_node]  turn requested: left
[turn_node]   turn START: LEFT
[turn_node]   turn done @ 1.4s
[follow_node] [....##....]                         ← now on spur 2
[rfid_node]   [TAG] S05 (dist=0.20m)
[state_node]  TARGET REACHED: S05
[state_node]  STATE: GOING -> AT_SHELF -> WAITING
[arm_node]    arm task done
[state_node]  STATE: WAITING -> PIVOTING
[pivot_node]  pivot start: 180 deg
[pivot_node]  pivot done
[state_node]  STATE: PIVOTING -> RETURNING
[state_node]  return junction — turning onto main aisle
[turn_node]   turn START: RIGHT
[turn_node]   turn done @ 1.5s
[rfid_node]   [HOME] HOME (dist=0.18m)
[state_node]  HOME reached — mission complete
[state_node]  STATE: RETURNING -> IDLE
```

---

## Why This Fix Is Permanent

| Old problem | New behavior |
|---|---|
| 3 nodes fighting over `/agv/cmd_vel` | Only `state_node` publishes `/agv/cmd_vel` — never a fight |
| pivot_node randomly publishing while idle | `pivot_node` publishes to `/agv/pivot_vel` — state_node ignores it when state≠PIVOTING |
| follow_node active while turning | `follow_node` publishes to `/agv/follow_vel` — state_node ignores it when `turning=True` |
| Disabling/enabling with race conditions | No enable/disable needed — arbiter selects by state, zero latency |
| 4 publishers visible on cmd_vel | **1 publisher always** — state_node |

---

## Quick Reference — New Topic Map

```
follow_node  → /agv/follow_vel  → state_node (arbiter) → /agv/cmd_vel → Gazebo AGV
turn_node    → /agv/turn_vel    ↗
pivot_node   → /agv/pivot_vel   ↗
```

Everything else (`/agv/odom`, `/agv/rfid_detected`, `/agv/junction_detected`, etc.) unchanged.
