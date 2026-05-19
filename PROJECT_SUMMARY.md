# 🤖 Warehouse AGV Simulation — Complete Project Summary

> This document summarizes the entire development journey: what was built, what broke, how it was fixed, and the final working architecture.

---

## 📋 Project Overview

**Goal:** Simulate an autonomous warehouse robot (AGV) that receives orders, follows black tape lines on the floor, navigates to specific shelves using junction counting, picks up items (simulated), and returns home.

**Platform:** Ubuntu 22.04 + ROS 2 Humble + Gazebo Classic 11

**Final Project Name:** `wbot` (warehouse bot)  
**Workspace:** `~/wbot_ws/`

---

## 🏗️ Architecture (Final Working Version)

### Package Structure

```
~/wbot_ws/src/
├── wbot_msgs/     Custom message types (Order, RFIDRead, BotState)
├── wbot_world/    Gazebo warehouse (20 shelves, tape lines, HOME zone)
├── wbot_robot/    Robot URDF with correct physics
├── wbot_brain/    All 9 Python nodes (sensors, PID, state machine, GUI)
└── wbot_run/      Master launcher (one-command start)
```

### Topic Architecture — Single Arbiter Pattern

```
follow.py  ──► /wbot/follow_vel  ──┐
turn.py    ──► /wbot/turn_vel    ──┼──► brain.py ──► /wbot/cmd_vel ──► Gazebo
pivot.py   ──► /wbot/pivot_vel   ──┘   (sole writer)
```

**Key principle:** Only `brain.py` (the state machine) writes to `/wbot/cmd_vel`. Other nodes write to private velocity topics. The brain's arbiter loop (50 Hz) selects which velocity to forward based on mission state. This eliminates publisher race conditions permanently.

### State Machine

```
IDLE → GOING → AT_SHELF → WAITING → PIVOTING → PIVOT_NUDGE → RETURNING → IDLE
```

| State | What Happens | Who Controls Movement |
|---|---|---|
| IDLE | Robot at HOME, waiting | Arbiter publishes zero (stopped) |
| GOING | Following line toward shelf | Arbiter forwards follow_vel |
| AT_SHELF | RFID confirmed, stopped | Arbiter publishes zero |
| WAITING | Arm stub working (3 sec) | Arbiter publishes zero |
| PIVOTING | Rotating 180° | Arbiter forwards pivot_vel |
| PIVOT_NUDGE | Driving 15cm forward after pivot | Arbiter publishes nudge_twist |
| RETURNING | Following line toward HOME | Arbiter forwards follow_vel |

### Junction Navigation (Counting Method)

Instead of using GPS-like coordinates, the robot counts how many junctions it crosses:

```
Shelf S01-S04 → Aisle 1 (turn at junction #1)
Shelf S05-S08 → Aisle 2 (turn at junction #2)
Shelf S09-S12 → Aisle 3 (turn at junction #3)
Shelf S13-S16 → Aisle 4 (turn at junction #4)
Shelf S17-S20 → Aisle 5 (turn at junction #5)
```

Formula: `target_aisle = ((shelf_number - 1) // 4) + 1`

---

## 🐛 Bugs Encountered & Solutions (Chronological)

### Bug 1: Camera-based Line Following Failed

**Symptom:** cv_bridge errors, QoS mismatches, lighting flicker, frame drops.

**Root Cause:** Gazebo's camera plugin is unreliable for thin black tape detection.

**Solution:** Replaced camera with **optical sensor simulation** — uses odometry + geometry to compute 8 virtual IR sensor readings. No camera plugin, no OpenCV, no image processing. Just math.

---

### Bug 2: AGV Extremely Slow (0.8 cm/s instead of 30 cm/s)

**Symptom:** AGV crawled along the line, taking 15 minutes to cross half the warehouse.

**Root Cause:** The PID code multiplied the offset by 100 (`offset * 100.0`), then fed it into a PID with gains tuned for small numbers. The result: massive angular corrections that caused wild oscillation, eating all forward motion.

**Solution:** Removed `* 100.0`. Offset stays in [-1, +1] range. Recalibrated PID gains: `kp=0.50, kd=0.15, linear_speed=0.50`.

---

### Bug 3: AGV Never Turned at Junctions

**Symptom:** Robot drove straight past every junction without turning.

**Root Cause:** Multiple publishers on `/cmd_vel`. `follow_node`, `turn_node`, and `pivot_node` all published to the same topic simultaneously. Commands cancelled each other out.

**Solution:** Single arbiter pattern. Each worker publishes to its own private topic (`/follow_vel`, `/turn_vel`, `/pivot_vel`). Only `brain.py` writes to `/cmd_vel`, forwarding whichever velocity matches the current state.

---

### Bug 4: AGV Froze at Junction After Turning

**Symptom:** Perfect 90° turn, then robot stopped dead at the intersection.

**Root Cause:** After the turn, the robot was still at the junction cross-point. Sensors immediately detected 6+ black (junction signal) again. State machine tried to trigger another turn → infinite loop.

**Solution:** 2.5-second `post_turn_block` — after any turn completes, junction events are ignored for 2.5 seconds, giving the robot time to drive clear of the intersection.

---

### Bug 5: Junction Turn Imprecise (Robot Shot Off Line)

**Symptom:** Robot attempted to turn but overshot, ending up at a diagonal angle.

**Root Cause:** Old turn logic used sensor-watching exit strategy. The spur line (5 cm wide) was swept past in 0.08 seconds — too fast for the 3-frame confirmation requirement. 6-second timeout = 206° of rotation.

**Solution:** IMU yaw-controlled exact 90° turn. Same approach as pivot (which always worked). Record target yaw, rotate until within 3° tolerance, stop. Plus 12cm forward nudge after rotation to clear the intersection.

---

### Bug 6: AGV Lost Line on Return Trip

**Symptom:** After pivot, robot drifted off the spur line and stopped ("Line lost").

**Root Cause:** The 180° pivot is pure rotation (no position change). If the robot stopped slightly off-centre before pivoting, it starts the return slightly off-centre. The grace period (`MAX_LOST = 25` frames = 0.5 seconds) expired before the PID could correct.

**Solution:** Three changes:
- `MAX_LOST` increased to 80 (1.6 seconds grace)
- `LINE_WIDTH` increased to 0.10 (wider virtual detection zone)
- Added `PIVOT_NUDGE` state: drive 15cm forward after pivot before line follower takes over

---

### Bug 7: AGV Missed Shelf RFID Tags

**Symptom:** Robot drove past the target shelf without stopping.

**Root Cause:** Tags placed 0.40m off the spur line. Detection radius was 0.45m — only 5cm margin. At 0.5 m/s, the detection window was ~0.1 seconds. At 10 Hz odom, only 1 sample — easily missed.

**Solution:** Detection radius increased to 0.60m. Odom subscription depth increased to 50 (5× more samples per second).

---

### Bug 8: AGV Moved On Its Own When Spawned (No Brain Running)

**Symptom:** Robot slid forward the moment it spawned in Gazebo, even with no brain nodes running.

**Root Cause:** URDF wheel placement error. Wheel bottoms were 5mm below the ground (`z = -0.005`). Gazebo's physics engine resolved the collision by applying an impulse. With no joint damping, the impulse became permanent rotational velocity.

**Solution:** Corrected URDF with:
- Mathematically exact wheel placement (`wheel_bottom = z = 0.000`)
- Joint damping (`<dynamics damping="0.5" friction="0.2"/>`)
- Friction parameters (`mu1=1.0, mu2=0.5, kp=1e6, kd=10`)
- Spawn height changed from `z=0.05` to `z=0.01`

---

### Bug 9: `wbot_msgs/msg/BotState` Invalid

**Symptom:** `ros2 topic echo /wbot/state --once` → "The message type is invalid"

**Root Cause:** Messages package (`wbot_msgs`) wasn't built before the brain packages that depend on it. Stale/missing generated Python files.

**Solution:** Build `wbot_msgs` FIRST in isolation, source it, verify with `ros2 interface show`, THEN build everything else. The final install script enforces this order.

---

### Bug 10: SKU Always Showed "SKU-0000"

**Symptom:** After sending order, SKU displayed as SKU-0000 even though user typed SKU-1042.

**Root Cause:** The `AGVState` message (later `BotState`) didn't have a `current_sku` field. SKU was sent in the Order but never propagated back for display.

**Solution:** Added `current_sku` field to `BotState.msg`. Brain broadcasts it. GUI displays it.

---

### Bug 11: `Sensor.cc:510 Get noise index not valid`

**Symptom:** Gazebo terminal spam with red error messages about noise index.

**Root Cause:** IMU plugin in URDF missing explicit noise configuration. Gazebo tried to access a noise parameter that was never set.

**Solution:** Added explicit zero-noise `<imu>` config block inside the sensor element. Harmless warning — IMU still worked — but silenced for cleaner terminal output.

---

## 🔧 Key Technical Decisions

| Decision | Why |
|---|---|
| Optical sensors (not camera) | Camera in Gazebo is fragile; optical simulation is deterministic |
| Single arbiter for cmd_vel | Prevents multi-publisher race conditions permanently |
| Junction COUNTING (not position matching) | More reliable — sensors always detect wide junctions |
| IMU yaw for turns (not sensor-watching) | Exact angle every time, independent of line width |
| LINE_WIDTH = 0.10 (virtual) | Wider than physical tape — helps sensors detect even when slightly off-centre |
| Post-turn cooldown 2.5s | Prevents junction re-trigger at intersection cross-points |
| PIVOT_NUDGE state | Drives robot onto line cleanly before line follower takes over |
| Build msgs FIRST | Prevents stale message definition errors |

---

## 📊 Final Working Configuration

### PID Parameters
```yaml
linear_speed: 0.50  # m/s
kp: 0.50            # proportional
ki: 0.00            # integral (disabled)
kd: 0.15            # derivative
```

### Sensor Parameters
```python
LINE_WIDTH = 0.10          # virtual detection zone (physical tape is 5cm)
SENSOR_X = 0.10            # 10cm in front of base_link
SENSOR_OFFSETS_Y = [0.042, 0.030, 0.018, 0.006,
                    -0.006, -0.018, -0.030, -0.042]
JUNC_THRESHOLD = 5         # 5+ sensors black = junction
JUNC_STREAK = 2            # need 2 consecutive frames to confirm
MAX_LOST = 80              # 1.6s grace period before stopping
```

### RFID Parameters
```python
DETECTION_RADIUS = 0.60    # meters (tag fires when AGV within this)
REARM_DISTANCE = 0.90      # meters (tag rearms when AGV moves this far away)
```

### Turn Parameters
```python
TURN_SPEED = 0.50          # rad/s rotation speed
TOLERANCE = 0.05           # rad (~3°) exit tolerance
NUDGE_SPEED = 0.20         # m/s forward during nudge
NUDGE_TIME = 0.60          # seconds (= 12cm forward after turn)
```

### Physics (URDF)
```xml
<!-- Wheels -->
<dynamics damping="0.5" friction="0.2"/>
<mu1>1.0</mu1> <mu2>0.5</mu2>
<kp>1000000.0</kp> <kd>10.0</kd>

<!-- Caster (frictionless) -->
<mu1>0.0</mu1> <mu2>0.0</mu2>

<!-- Spawn -->
z = 0.01 (just above ground, no fall/bounce)
```

### Cooldowns
```python
JUNC_COOLDOWN = 1.5        # seconds between counting two junctions
POST_TURN_BLOCK = 2.5      # seconds — block junctions after any turn
NUDGE_DURATION = 0.75      # seconds — post-pivot forward drive
```

---

## 🚀 How to Run

```bash
# One-command launch
source ~/wbot_ws/install/setup.bash
ros2 launch wbot_run all.launch.py

# Send order (from another terminal)
source ~/wbot_ws/install/setup.bash
ros2 run wbot_brain send S05
```

Or use the Tkinter GUI (launches automatically with `all.launch.py`).

---

## 📁 All Source Files

| Package | File | Purpose |
|---|---|---|
| wbot_msgs | `msg/Order.msg` | Order format (shelf_id, aisle, sku) |
| wbot_msgs | `msg/RFIDRead.msg` | RFID detection (tag_id, distance, is_home) |
| wbot_msgs | `msg/BotState.msg` | State broadcast (state, target, sku, rfid) |
| wbot_world | `scripts/build_world.py` | Generates warehouse.world |
| wbot_robot | `urdf/wbot.urdf.xacro` | Robot model with correct physics |
| wbot_robot | `launch/spawn.launch.py` | Gazebo + robot + RViz |
| wbot_brain | `track.py` | Line geometry (where tape is) |
| wbot_brain | `shelves.py` | Shelf locations + aisle numbers |
| wbot_brain | `optical.py` | 8 virtual IR sensors (50 Hz) |
| wbot_brain | `follow.py` | PID line follower → /wbot/follow_vel |
| wbot_brain | `turn.py` | IMU 90° turn + nudge → /wbot/turn_vel |
| wbot_brain | `pivot.py` | IMU 180° pivot → /wbot/pivot_vel |
| wbot_brain | `rfid.py` | Pose-based RFID detection |
| wbot_brain | `arm.py` | Arm stub (3-second wait) |
| wbot_brain | `brain.py` | State machine + cmd_vel arbiter |
| wbot_brain | `gui.py` | Tkinter GUI with dashboard + queue |
| wbot_brain | `send.py` | CLI order sender |
| wbot_run | `launch/all.launch.py` | Master launcher (everything in one command) |

---

## 🔮 What's Next (If You Want To Expand)

1. **Multi-AGV:** Namespace each robot (`/wbot1/`, `/wbot2/`), add collision avoidance
2. **Real Robotic Arm:** Replace `arm.py` stub with MoveIt 2 + 6-DOF arm
3. **Inventory System:** Track which SKUs are on which shelves
4. **Real Hardware:** ESP32 + TCRT5000 IR array + RC522 RFID + MPU6050 IMU (same logic, real sensors)
5. **Path Planning:** Replace junction counting with A* for optimal multi-shelf routes

---

## 📅 Development Timeline

| Phase | What Happened |
|---|---|
| Start | Original 5-stage plan with camera-based line following |
| Stage 3B | Migrated from camera to optical sensors (eliminated cv_bridge bugs) |
| Stage 4 | Added state machine, RFID, junctions (many bugs emerged) |
| Hotfix 1 | Fixed PID scaling (×100 bug) |
| Hotfix 2 | Fixed multi-publisher race condition (arbiter pattern) |
| Hotfix 3 | Fixed junction re-trigger loop (post-turn cooldown) |
| Hotfix 4 | Fixed turn precision (IMU yaw instead of sensor-watching) |
| Hotfix 5 | Fixed return line-loss (wider detection + longer grace + pivot nudge) |
| Hotfix 6 | Fixed URDF physics (wheel placement below ground) |
| Hotfix 7 | Fixed message build order (wbot_msgs must build first) |
| Final | Complete rewrite as `wbot` project with all fixes baked in |

---

## 🎓 Lessons Learned

1. **Build messages separately first.** Always `colcon build --packages-select wbot_msgs` before building packages that use them.
2. **Single publisher per actuator topic.** Never let multiple nodes publish to the same topic. Use an arbiter.
3. **URDF physics matters.** A 5mm wheel placement error creates unstoppable drift.
4. **Clean rebuild fixes 90% of "weird" bugs.** `rm -rf build install log && colcon build`
5. **Source in every terminal.** Old terminals have stale state. Always `source install/setup.bash` in new terminals.
6. **Test incrementally.** Verify each piece works in isolation before combining.
7. **Deterministic beats sensor-based.** IMU yaw (deterministic angle) is better than sensor-watching (probabilistic timing) for turns.
8. **Wider tolerances, longer timeouts.** Real systems are noisy. Design with margin.

---

*Generated: May 2026 — B.Tech Autonomous Guided Vehicle Project*
