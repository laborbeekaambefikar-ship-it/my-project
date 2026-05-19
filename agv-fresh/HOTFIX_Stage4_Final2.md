# 🔥 HOTFIX — state_node Crash + AGV Idle Fix

## The Exact Error

```
File "state_node.py", line 34, in <module>
    self._pivot_nudge_timer = None
AttributeError: 'StateNode' object has no attribute '_pivot_nudge_timer'
```

The previous hotfix added a pivot nudge using `create_timer()` inside a
callback. This breaks because the attribute was not declared in `__init__`
before it was referenced. The node crashes on startup and the AGV never moves.

## The Fix

Replace the **entire `state_node.py`** with the version below.

Changes vs the previous version:
1. All `_pivot_nudge_*` attributes declared in `__init__` — crash fixed
2. Pivot nudge is handled inside the existing 50 Hz `arbiter()` loop —
   no extra timer created at runtime (the previous approach)
3. A new `PIVOT_NUDGE` state is added so the arbiter knows to publish
   a forward velocity during the nudge phase cleanly

---

## Step 1 — Replace `state_node.py` (complete file)

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

PIVOT_NUDGE is a new intermediate state:
  After the 180° pivot, the AGV drives forward 15 cm (0.75s @ 0.20 m/s)
  to position itself cleanly on the spur before the line follower takes
  over. This prevents the AGV from starting off-centre and losing the line.

ONLY this node publishes to /agv/cmd_vel.
"""
import math
import rclpy
from rclpy.node import Node
from std_msgs.msg import Bool, String, Float32
from geometry_msgs.msg import Twist
from agv_msgs.msg import Order, RFIDRead, AGVState
from agv_brain.shelf_lib import SHELF_MAP

IDLE         = 'IDLE'
GOING        = 'GOING'
AT_SHELF     = 'AT_SHELF'
WAITING      = 'WAITING'
PIVOTING     = 'PIVOTING'
PIVOT_NUDGE  = 'PIVOT_NUDGE'   # ← NEW: short forward drive after pivot
RETURNING    = 'RETURNING'

PIVOT_NUDGE_SPEED    = 0.20    # m/s forward during nudge
PIVOT_NUDGE_DURATION = 0.75    # seconds  →  0.20 × 0.75 = 15 cm


class StateNode(Node):
    def __init__(self):
        super().__init__('state_node')

        # ── Mission state ─────────────────────────────────────────────
        self.state          = IDLE
        self.order          = None
        self.last_rfid      = ''
        self.junction_count = 0
        self.turning        = False

        # ── Junction cooldowns ────────────────────────────────────────
        self.last_junc_t        = 0.0
        self.JUNC_COOLDOWN      = 1.5   # s between two counted junctions
        self.post_turn_block_until = 0.0
        self.POST_TURN_BLOCK    = 2.5   # s to block junctions after any turn

        # ── Pivot nudge state (ALL declared here — no AttributeError) ──
        self.pivot_nudge_start = None   # timestamp when nudge began

        # ── Velocity buffers ──────────────────────────────────────────
        self.follow_vel = Twist()
        self.turn_vel   = Twist()
        self.pivot_vel  = Twist()

        # ── Nudge twist (constant) ────────────────────────────────────
        self._nudge_twist = Twist()
        self._nudge_twist.linear.x = PIVOT_NUDGE_SPEED

        # ── Subscriptions: velocities ─────────────────────────────────
        self.create_subscription(Twist, '/agv/follow_vel', self.fv_cb, 10)
        self.create_subscription(Twist, '/agv/turn_vel',   self.tv_cb, 10)
        self.create_subscription(Twist, '/agv/pivot_vel',  self.pv_cb, 10)

        # ── Subscriptions: events ─────────────────────────────────────
        self.create_subscription(Order,    '/agv/order',
                                 self.order_cb,      10)
        self.create_subscription(RFIDRead, '/agv/rfid_detected',
                                 self.rfid_cb,       10)
        self.create_subscription(Bool,     '/agv/junction_detected',
                                 self.junc_cb,       10)
        self.create_subscription(Bool,     '/agv/turn_done',
                                 self.turn_done_cb,  10)
        self.create_subscription(Bool,     '/arm/done',
                                 self.arm_done_cb,   10)
        self.create_subscription(Bool,     '/agv/pivot_done',
                                 self.pivot_done_cb, 10)

        # ── Publishers ────────────────────────────────────────────────
        self.cmd_pub   = self.create_publisher(Twist,    '/agv/cmd_vel',  10)
        self.turn_pub  = self.create_publisher(String,   '/agv/turn_cmd', 10)
        self.pivot_pub = self.create_publisher(Float32,  '/agv/pivot_cmd',10)
        self.arm_pub   = self.create_publisher(Bool,     '/arm/start',    10)
        self.state_pub = self.create_publisher(AGVState, '/agv/state',    10)

        # ── Timers ────────────────────────────────────────────────────
        self.create_timer(0.02, self.arbiter)        # 50 Hz control loop
        self.create_timer(0.5,  self.broadcast_state)# 2 Hz state broadcast

        self.get_logger().info(
            'state_node ready — sole publisher of /agv/cmd_vel')

    # ── Velocity buffer callbacks ─────────────────────────────────────
    def fv_cb(self, msg): self.follow_vel = msg
    def tv_cb(self, msg): self.turn_vel   = msg
    def pv_cb(self, msg): self.pivot_vel  = msg

    # ── THE ARBITER — runs at 50 Hz ───────────────────────────────────
    def arbiter(self):
        if self.state in (IDLE, AT_SHELF, WAITING):
            self.cmd_pub.publish(Twist())           # full stop

        elif self.state == PIVOT_NUDGE:
            # Check if nudge duration has elapsed
            elapsed = (self.get_clock().now().nanoseconds / 1e9
                       - self.pivot_nudge_start)
            if elapsed >= PIVOT_NUDGE_DURATION:
                self.get_logger().info(
                    f'pivot nudge done ({elapsed:.2f}s) — starting line follow')
                self.set_state(RETURNING)
                self.pivot_nudge_start = None
                # Fall through — next arbiter call will forward follow_vel
                return
            self.cmd_pub.publish(self._nudge_twist)  # drive forward

        elif self.turning:
            self.cmd_pub.publish(self.turn_vel)

        elif self.state == PIVOTING:
            self.cmd_pub.publish(self.pivot_vel)

        elif self.state in (GOING, RETURNING):
            self.cmd_pub.publish(self.follow_vel)

        else:
            self.cmd_pub.publish(Twist())

    # ── Helpers ───────────────────────────────────────────────────────
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
        t = self.now_s()

        # Post-turn block — ignore junctions for 2.5s after any turn
        if t < self.post_turn_block_until:
            return

        # Per-junction cooldown — avoid double-counting one wide junction
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
        self.post_turn_block_until = self.now_s() + self.POST_TURN_BLOCK
        self.get_logger().info(
            f'turn complete — junctions blocked {self.POST_TURN_BLOCK}s')

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
        self.get_logger().info('arm done — pivoting 180°')
        self.set_state(PIVOTING)
        p = Float32(); p.data = math.pi
        self.pivot_pub.publish(p)

    def pivot_done_cb(self, msg):
        if not msg.data or self.state != PIVOTING:
            return
        # Start pivot nudge (drives forward 15 cm to centre on spur)
        self.pivot_nudge_start = self.now_s()
        self.junction_count    = 0
        self.get_logger().info(
            f'pivot done — nudging {PIVOT_NUDGE_DURATION}s @ '
            f'{PIVOT_NUDGE_SPEED}m/s onto spur')
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

## Step 2 — Rebuild

```bash
cd ~/agv_ws
colcon build --symlink-install --packages-select agv_brain
source install/setup.bash
```

Expected: `Summary: 1 package finished` with **no errors and no tracebacks**.

---

## Step 3 — Verify state_node starts cleanly

```bash
pkill -9 -f ros2; pkill -9 -f gz; pkill -9 -f rviz; sleep 3

# Terminal 1
source ~/agv_ws/install/setup.bash
ros2 launch agv_robot spawn.launch.py

# Terminal 2
source ~/agv_ws/install/setup.bash
ros2 launch agv_brain brain.launch.py
```

In Terminal 2, look for this line (no errors, no tracebacks):
```
[state_node] state_node ready — sole publisher of /agv/cmd_vel
```

The AGV must stay still at HOME. If it moves immediately, the
`follow_node.py` still has `enabled: true` in the YAML — see Step 4.

---

## Step 4 — Verify `follow_params.yaml` has correct value

The arbiter pattern does NOT use an enable flag anymore. The YAML should
have this (the value doesn't matter since the arbiter controls everything,
but it must not crash):

```bash
cat ~/agv_ws/src/agv_brain/config/follow_params.yaml
```

It should look like:
```yaml
follow_node:
  ros__parameters:
    linear_speed: 0.50
    kp: 0.50
    ki: 0.00
    kd: 0.15
```

If it still has `enabled: true` or `enabled: false` and your `follow_node.py`
is the version from HOTFIX_AGV_Not_Moving (which removed the `enabled`
parameter), that's fine — the param simply won't be read.

If your `follow_node.py` is the ORIGINAL Stage 3 version (which has
`enabled: true` as default), it will start driving immediately. Check:

```bash
grep "enabled" ~/agv_ws/src/agv_brain/agv_brain/follow_node.py
```

If it prints a line with `enabled`, you have the old version. Replace it
with the version from HOTFIX_AGV_Not_Moving.md (the one that publishes to
`/agv/follow_vel` not `/agv/cmd_vel`).

---

## Step 5 — Test Full Mission

```bash
# Terminal 3
source ~/agv_ws/install/setup.bash
ros2 run agv_brain send S05
```

Watch Terminal 2. You should now see `PIVOT_NUDGE` in the state sequence:

```
[state_node] STATE: IDLE -> GOING
[state_node] junction #1  (target aisle 2)
[state_node] junction #2  (target aisle 2)
[state_node] turn requested: left
[turn_node]  turn START: LEFT
[turn_node]  turn + nudge DONE
[state_node] turn complete — junctions blocked 2.5s
[follow_node] [....##....] lin=0.50
[rfid_node]  [TAG] DETECTED S05  dist=0.52m
[state_node] TARGET REACHED: S05
[state_node] STATE: GOING -> AT_SHELF -> WAITING
[arm_node]   arm task done
[state_node] STATE: WAITING -> PIVOTING
[pivot_node] pivot done
[state_node] pivot done — nudging 0.75s @ 0.20m/s onto spur
[state_node] STATE: PIVOTING -> PIVOT_NUDGE    ← NEW
[state_node] pivot nudge done (0.75s) — starting line follow
[state_node] STATE: PIVOT_NUDGE -> RETURNING   ← NEW
[follow_node] [....##....] lin=0.50            ← on spur, heading south
[state_node] return junction — turning onto main aisle
[turn_node]  turn START: RIGHT
[turn_node]  turn + nudge DONE
[state_node] turn complete — junctions blocked 2.5s
[follow_node] [....##....] lin=0.50            ← on main aisle, heading west
[rfid_node]  [HOME] DETECTED HOME  dist=0.22m
[state_node] HOME reached — mission complete
[state_node] STATE: RETURNING -> IDLE
```

---

## What Changed vs Previous Version

| Issue | Old code | New code |
|---|---|---|
| `AttributeError: no attribute '_pivot_nudge_timer'` | Attributes created inside callback, not in `__init__` | All attributes declared in `__init__` |
| `create_timer()` called inside callback | Created a new timer on every pivot — can crash | No new timers: pivot nudge handled in existing `arbiter()` loop |
| Pivot nudge state | No explicit state, just a flag | New `PIVOT_NUDGE` state — clean, visible in GUI dashboard |
| Return line lost | AGV starts from off-centre position | 15 cm nudge forward after pivot before line follower starts |

---

## Summary of ALL Changes Currently Applied

To be clear, here is what your `state_node.py` now does that the original
Stage 4 version did not:

1. **Single arbiter** — only node publishing `/agv/cmd_vel`
2. **Post-turn junction block** — 2.5s cooldown after any turn
3. **`PIVOT_NUDGE` state** — 15 cm forward drive after 180° pivot
4. All `_pivot_nudge_*` attributes properly declared in `__init__`
