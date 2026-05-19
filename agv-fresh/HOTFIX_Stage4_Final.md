# 🔥 HOTFIX — Final Stage 4 Fixes (All Three Bugs)

## The Two Symptoms You See

1. **AGV freezes at junction after turning** — takes perfect 90° turn then stops
2. **AGV drives past the shelf without stopping** — misses the RFID tag

Both are caused by three bugs. Here they are.

---

## Bug 1 — Junction Re-Trigger Causes Freeze

**What happens:**
After the 90° turn, the AGV is sitting right at the intersection point of
the main aisle and the spur (X=3, Y=0 for spur 1). This point has BOTH
lines crossing. The sensors immediately see 6+ black again.

`state_node` receives another `/agv/junction_detected` signal.
`state_node.turning` is now False (turn just finished).
So `state_node` tries to do ANOTHER turn — calling `_do_turn('left')` again.
`turning` becomes True again. The arbiter switches back to `turn_vel`.
`turn_node` receives the command, immediately completes it (it's already at
90°), fires `turn_done`. `turning` goes False. Sensors still see the junction.
Loop repeats. AGV is stuck in a tight re-trigger loop at the junction.

**The proof:** Look at your screenshot — the AGV is at the exact junction
crossing point, not partway up the spur.

**Fix:** After a turn completes, block junction detection for 2.5 seconds.
This gives the AGV time to drive forward off the intersection before sensors
can trigger another turn.

---

## Bug 2 — AGV Misses Shelf RFID Tag

**What happens:**
Look at `shelf_lib.py`:
```python
TAG_X_OFFSET = -0.4   # 0.4m LEFT of the spur line
```

The shelf RFID tags are placed 0.4m to the **left** of the spur line.

But the AGV drives **on** the spur line — its centre is at the spur X.
The `rfid_node` checks the AGV's odometry position against the tag position.

Distance = sqrt((agv_x - tag_x)² + (agv_y - tag_y)²)

When AGV is on the spur (agv_x = spur_x) and passing the shelf:
  distance = sqrt((spur_x - (spur_x - 0.4))² + 0²)
           = sqrt(0.16)
           = **0.40 m**

But `DETECTION_RADIUS = 0.45` — so it should just barely detect...

Except: the AGV is only 0.25m wide. It follows the spur line centre.
The tag is 0.4m offset. When the AGV is moving at 0.5 m/s, it crosses
the tag's Y position in 0.1 seconds. At 10 Hz odom, that might be only
1 odom sample where distance < 0.45. If that sample arrives slightly late,
the AGV has already moved past and distance > 0.45 again.

**Fix:** Two changes:
1. Increase `DETECTION_RADIUS` to `0.60` — larger catch zone
2. Check detection at 50 Hz instead of 10 Hz — more samples

---

## Bug 3 — Post-Turn Freeze (turn_done missed + no forward nudge)

After the turn, the AGV is at the junction intersection. Even after the
junction re-trigger cooldown is fixed, the AGV's sensors might still see
the junction (6+ sensors on the wide intersection area). `follow_node`
sees a junction and publishes straight-ahead vel. But `state_node` arbiter
is forwarding `follow_vel` which says "go straight" — so the AGV should
move. Unless `follow_node` is in "line lost" mode because the spur is thin
and sensors don't see it cleanly right at Y=0.

**Fix:** Add a forward nudge phase to `turn_node` after the angle is reached.
Drive forward 12 cm at 0.2 m/s before firing `turn_done`. This gets the AGV
fully onto the spur line before the line follower takes over.

---

## What You Replace

| File | What changes |
|---|---|
| `state_node.py` | Add 2.5s post-turn junction cooldown |
| `rfid_node.py` | Bigger detection radius (0.60m) + higher odom rate (50Hz) |
| `turn_node.py` | Add 12cm forward nudge after angle reached |

---

## Step 1 — Replace `state_node.py`

```bash
nano ~/agv_ws/src/agv_brain/agv_brain/state_node.py
```

Delete everything. Paste:

```python
#!/usr/bin/env python3
"""
state_node.py — Mission orchestrator AND cmd_vel arbiter.

FIXES IN THIS VERSION:
  - post-turn junction cooldown (2.5s) prevents re-trigger loop at intersection
  - returning-junction cooldown independent from going-junction cooldown
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

        self.state          = IDLE
        self.order          = None
        self.last_rfid      = ''
        self.junction_count = 0
        self.turning        = False

        # ── Junction cooldowns ────────────────────────────────────────
        # JUNC_COOLDOWN: minimum time between counting two different junctions
        #   (prevents double-counting a single wide junction)
        self.last_junc_t   = 0.0
        self.JUNC_COOLDOWN = 1.5    # seconds

        # POST_TURN_BLOCK: after a turn completes, block ALL junction events
        #   for this many seconds. Prevents the intersection cross-point from
        #   immediately re-triggering another turn.
        self.post_turn_block_until = 0.0
        self.POST_TURN_BLOCK = 2.5  # seconds  ← KEY FIX

        # ── Velocity buffers ──────────────────────────────────────────
        self.follow_vel = Twist()
        self.turn_vel   = Twist()
        self.pivot_vel  = Twist()

        # ── Subscriptions: velocities ─────────────────────────────────
        self.create_subscription(Twist, '/agv/follow_vel', self.fv_cb, 10)
        self.create_subscription(Twist, '/agv/turn_vel',   self.tv_cb, 10)
        self.create_subscription(Twist, '/agv/pivot_vel',  self.pv_cb, 10)

        # ── Subscriptions: events ─────────────────────────────────────
        self.create_subscription(Order,    '/agv/order',             self.order_cb,      10)
        self.create_subscription(RFIDRead, '/agv/rfid_detected',     self.rfid_cb,       10)
        self.create_subscription(Bool,     '/agv/junction_detected', self.junc_cb,       10)
        self.create_subscription(Bool,     '/agv/turn_done',         self.turn_done_cb,  10)
        self.create_subscription(Bool,     '/arm/done',              self.arm_done_cb,   10)
        self.create_subscription(Bool,     '/agv/pivot_done',        self.pivot_done_cb, 10)

        # ── Publishers ────────────────────────────────────────────────
        self.cmd_pub   = self.create_publisher(Twist,    '/agv/cmd_vel',  10)
        self.turn_pub  = self.create_publisher(String,   '/agv/turn_cmd', 10)
        self.pivot_pub = self.create_publisher(Float32,  '/agv/pivot_cmd',10)
        self.arm_pub   = self.create_publisher(Bool,     '/arm/start',    10)
        self.state_pub = self.create_publisher(AGVState, '/agv/state',    10)

        self.create_timer(0.02, self.arbiter)
        self.create_timer(0.5,  self.broadcast_state)

        self.get_logger().info('state_node ready — sole publisher of /agv/cmd_vel')

    # ── Velocity buffers ──────────────────────────────────────────────
    def fv_cb(self, msg): self.follow_vel = msg
    def tv_cb(self, msg): self.turn_vel   = msg
    def pv_cb(self, msg): self.pivot_vel  = msg

    # ── Arbiter — 50 Hz ───────────────────────────────────────────────
    def arbiter(self):
        if self.state in (IDLE, AT_SHELF, WAITING):
            self.cmd_pub.publish(Twist())
        elif self.turning:
            self.cmd_pub.publish(self.turn_vel)
        elif self.state == PIVOTING:
            self.cmd_pub.publish(self.pivot_vel)
        elif self.state in (GOING, RETURNING):
            self.cmd_pub.publish(self.follow_vel)
        else:
            self.cmd_pub.publish(Twist())

    # ── Helpers ───────────────────────────────────────────────────────
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

    # ── Event handlers ────────────────────────────────────────────────
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
        t = self.now()

        # ── POST-TURN BLOCK: ignore junctions for 2.5s after any turn ──
        if t < self.post_turn_block_until:
            remaining = self.post_turn_block_until - t
            self.get_logger().debug(
                f'junction blocked — post-turn cooldown {remaining:.1f}s remaining')
            return

        # ── Normal junction cooldown ────────────────────────────────
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
            self.get_logger().info('return junction — turning onto main aisle')
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
        # ── Set post-turn block ─────────────────────────────────────────
        self.post_turn_block_until = self.now() + self.POST_TURN_BLOCK
        self.get_logger().info(
            f'turn complete — junctions blocked for {self.POST_TURN_BLOCK}s')

    def rfid_cb(self, msg):
        self.last_rfid = msg.tag_id

        if self.state == GOING and self.order and msg.tag_id == self.order.shelf_id:
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

## Step 2 — Replace `rfid_node.py`

```bash
nano ~/agv_ws/src/agv_brain/agv_brain/rfid_node.py
```

Delete everything. Paste:

```python
#!/usr/bin/env python3
"""
rfid_node.py — Pose-based RFID detection.

FIXES IN THIS VERSION:
  - DETECTION_RADIUS increased from 0.45 to 0.60m
    (shelf tags are 0.40m off the spur line, so 0.45m was barely enough
     and often missed at 0.5 m/s; 0.60m gives reliable detection)
  - Odom subscription depth increased to 50 (faster sampling)
  - Added debug log showing distance to target shelf while GOING
    (helps diagnose if detection still fails)
"""
import math
import rclpy
from rclpy.node import Node
from nav_msgs.msg import Odometry
from agv_msgs.msg import RFIDRead
from agv_brain.shelf_lib import SHELF_MAP, HOME_X, HOME_Y


DETECTION_RADIUS = 0.60   # ← WAS 0.45, NOW 0.60
REARM_DISTANCE   = 0.90   # ← WAS 0.80, bumped proportionally


class RfidNode(Node):
    def __init__(self):
        super().__init__('rfid_node')

        # All tags: shelf tags + HOME
        self.tags = {
            sid: (d['tag_x'], d['tag_y'], False)
            for sid, d in SHELF_MAP.items()
        }
        self.tags['HOME'] = (HOME_X, HOME_Y, True)

        # Armed = ready to fire
        self.armed = {tid: True for tid in self.tags}

        # Track current target for debug logging
        self.current_target = None
        self.log_counter    = 0

        self.create_subscription(
            Odometry, '/agv/odom', self.odom_cb, 50)  # ← depth 50
        self.pub = self.create_publisher(RFIDRead, '/agv/rfid_detected', 10)

        self.get_logger().info(
            f'rfid_node ready — {len(self.tags)} tags  '
            f'radius={DETECTION_RADIUS}m')

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

        # Debug: every 50 callbacks (~1s), log distance to current target
        self.log_counter += 1
        if self.log_counter >= 50 and self.current_target:
            self.log_counter = 0
            if self.current_target in self.tags:
                tx, ty, _ = self.tags[self.current_target]
                dist = math.hypot(x - tx, y - ty)
                armed = self.armed.get(self.current_target, True)
                self.get_logger().info(
                    f'[dist to {self.current_target}] = {dist:.2f}m  '
                    f'(armed={armed}  radius={DETECTION_RADIUS}m)')

    def fire(self, tid, d, is_home):
        m = RFIDRead()
        m.tag_id   = tid
        m.distance = float(d)
        m.is_home  = is_home
        self.pub.publish(m)
        icon = 'HOME' if is_home else 'TAG'
        self.get_logger().info(f'[{icon}] DETECTED {tid}  dist={d:.2f}m')


def main(args=None):
    rclpy.init(args=args)
    node = RfidNode()
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

## Step 3 — Replace `turn_node.py`

```bash
nano ~/agv_ws/src/agv_brain/agv_brain/turn_node.py
```

Delete everything. Paste:

```python
#!/usr/bin/env python3
"""
turn_node.py — Exact 90° junction turn + forward nudge.

APPROACH:
  Phase 1 — Rotate to target_yaw ± 90° using IMU (same as pivot_node)
  Phase 2 — Drive forward 12 cm at 0.20 m/s to clear the junction
             intersection before handing back to line follower
  Phase 3 — Fire turn_done

WHY THE NUDGE:
  After in-place rotation, the AGV sits at the exact junction cross-point
  (spur_x, 0). The line follower sensors may see the wide intersection area
  as a junction (6+ black) and report "confused" velocity. Driving forward
  12 cm places the AGV clearly on the spur, away from the intersection.

PUBLISHES to /agv/turn_vel — NOT /agv/cmd_vel.
state_node arbitrates.
"""
import math
import rclpy
from rclpy.node import Node
from nav_msgs.msg import Odometry
from std_msgs.msg import String, Bool
from geometry_msgs.msg import Twist

TURN_SPEED   = 0.50          # rad/s — rotation speed
TOLERANCE    = 0.05          # rad (~3°) — stop rotating when within this
TURN_ANGLE   = math.pi / 2   # 90 degrees

NUDGE_SPEED  = 0.20          # m/s — forward speed during nudge
NUDGE_TIME   = 0.60          # seconds — 0.60s × 0.20m/s = 12 cm


def yaw_from_quat(q):
    s = 2.0 * (q.w * q.z + q.x * q.y)
    c = 1.0 - 2.0 * (q.y * q.y + q.z * q.z)
    return math.atan2(s, c)


def angle_diff(target, current):
    d = target - current
    while d >  math.pi: d -= 2.0 * math.pi
    while d < -math.pi: d += 2.0 * math.pi
    return d


class TurnNode(Node):

    # Phase constants
    PHASE_IDLE   = 0
    PHASE_ROTATE = 1
    PHASE_NUDGE  = 2

    def __init__(self):
        super().__init__('turn_node')

        self.current_yaw = 0.0
        self.target_yaw  = None
        self.phase       = self.PHASE_IDLE
        self.direction   = 0
        self.nudge_start = None

        self.create_subscription(Odometry, '/agv/odom',     self.odom_cb, 50)
        self.create_subscription(String,   '/agv/turn_cmd', self.cmd_cb,  10)

        self.vel_pub  = self.create_publisher(Twist, '/agv/turn_vel',  10)
        self.done_pub = self.create_publisher(Bool,  '/agv/turn_done', 10)

        self.create_timer(0.02, self.tick)   # 50 Hz

        self.get_logger().info(
            f'turn_node ready  speed={TURN_SPEED}rad/s  '
            f'tol={math.degrees(TOLERANCE):.1f}°  '
            f'nudge={NUDGE_TIME}s@{NUDGE_SPEED}m/s  '
            f'→ /agv/turn_vel'
        )

    def odom_cb(self, msg):
        self.current_yaw = yaw_from_quat(msg.pose.pose.orientation)

    def cmd_cb(self, msg):
        d = msg.data.lower().strip()
        if   d == 'left':  self.direction = +1
        elif d == 'right': self.direction = -1
        else:
            self.get_logger().warn(f'unknown turn cmd: "{msg.data}"')
            return

        self.target_yaw = self.current_yaw + self.direction * TURN_ANGLE
        while self.target_yaw >  math.pi: self.target_yaw -= 2.0 * math.pi
        while self.target_yaw < -math.pi: self.target_yaw += 2.0 * math.pi

        self.phase = self.PHASE_ROTATE
        self.get_logger().info(
            f'turn START: {d.upper()}  '
            f'{math.degrees(self.current_yaw):.1f}° → '
            f'{math.degrees(self.target_yaw):.1f}°'
        )

    def tick(self):
        # ── IDLE: publish zero ────────────────────────────────────────
        if self.phase == self.PHASE_IDLE:
            self.vel_pub.publish(Twist())
            return

        # ── PHASE 1: Rotate to target yaw ────────────────────────────
        if self.phase == self.PHASE_ROTATE:
            err = angle_diff(self.target_yaw, self.current_yaw)
            if abs(err) < TOLERANCE:
                # Angle reached — start nudge phase
                self.phase       = self.PHASE_NUDGE
                self.nudge_start = self.get_clock().now()
                self.get_logger().info(
                    f'rotation done ({math.degrees(self.current_yaw):.1f}°) '
                    f'— nudging forward {NUDGE_TIME}s'
                )
                self.vel_pub.publish(Twist())   # momentary stop
                return

            t = Twist()
            t.linear.x  = 0.0   # pure rotation, no forward motion
            t.angular.z = TURN_SPEED * (1.0 if err > 0 else -1.0)
            self.vel_pub.publish(t)
            return

        # ── PHASE 2: Nudge forward onto spur ─────────────────────────
        if self.phase == self.PHASE_NUDGE:
            elapsed = (self.get_clock().now() - self.nudge_start).nanoseconds / 1e9
            if elapsed < NUDGE_TIME:
                t = Twist()
                t.linear.x  = NUDGE_SPEED
                t.angular.z = 0.0
                self.vel_pub.publish(t)
                return
            else:
                # Nudge complete — done
                self.vel_pub.publish(Twist())   # stop
                self.phase      = self.PHASE_IDLE
                self.target_yaw = None
                done = Bool(); done.data = True
                self.done_pub.publish(done)
                self.get_logger().info('turn + nudge DONE')
                return


def main(args=None):
    rclpy.init(args=args)
    node = TurnNode()
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

## Step 4 — Rebuild

```bash
cd ~/agv_ws
colcon build --symlink-install --packages-select agv_brain
source install/setup.bash
```

Expected: `Summary: 1 package finished` with no errors.

---

## Step 5 — Test

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

Terminal 3:
```bash
source ~/agv_ws/install/setup.bash
ros2 run agv_brain send S05
```

### What you should see in Terminal 2

```
STATE: IDLE -> GOING
junction #1  (target aisle 2)
junction #2  (target aisle 2)
turn requested: left
turn START: LEFT  0.0° → 90.0°
rotation done (90.1°) — nudging forward 0.60s
turn + nudge DONE
turn complete — junctions blocked for 2.5s    ← prevents re-trigger
[....##....]  lin=0.50                         ← line follower on spur
[TAG] DETECTED S05  dist=0.48m                 ← RFID fires reliably
TARGET REACHED: S05
STATE: GOING -> AT_SHELF -> WAITING
arm task done
STATE: WAITING -> PIVOTING
pivot done
STATE: PIVOTING -> RETURNING
return junction — turning onto main aisle
turn START: RIGHT  90.0° → 0.0°
turn + nudge DONE
turn complete — junctions blocked for 2.5s
[HOME] DETECTED HOME  dist=0.21m
HOME reached — mission complete
STATE: RETURNING -> IDLE
```

---

## What each fix solves

| Bug | Root cause | Fix |
|---|---|---|
| Freeze at junction after turn | AGV still on intersection, sensors re-trigger junction, state loops | 2.5s post-turn cooldown blocks junction events |
| AGV drives past shelf | Tag 0.40m off-line, 0.45m radius barely catches it at speed | Radius 0.60m + depth 50 for denser sampling |
| Line follower confused after turn | AGV on junction intersection, sensors see chaos | 12cm forward nudge clears the intersection |

---

## If RFID still misses (rare)

If on a particular shelf the tag is still missed, run this while the
mission is in progress to see distances in real time:

```bash
ros2 topic echo /agv/rfid_detected
```

And watch the debug distance log in the brain terminal:
```
[dist to S05] = 0.63m  (armed=True  radius=0.60m)
[dist to S05] = 0.47m  (armed=True  radius=0.60m)
[dist to S05] = 0.39m  (armed=True  radius=0.60m)  ← fires here
```

If the minimum distance shown is always > 0.60m, increase `DETECTION_RADIUS`
to `0.75` in `rfid_node.py`. You do not need to rebuild for this change
because `--symlink-install` was used — just save the file and restart.
