# 🧠 Stage 4 — The Brain of the AGV (Beginner's Walkthrough)

> Read top to bottom. Do not skip sections. By the end, your AGV will autonomously: receive an order → drive to a shelf → wait → turn around → drive home.

---

# 📚 PART 1: Understand What We're Doing (10-minute read, no code)

## The Big Idea

Right now (after Stage 3), your AGV is like a **car with a driver who only knows one trick**: follow whatever line is in front of it. It can't:
- Decide *where* to go
- Recognize *which* shelf it arrived at
- Know when to *stop*
- Know when to *turn around*
- Know when to *come home*

**Stage 4 adds a brain.** We're not changing the car (the line follower still drives). We're adding 6 new "advisors" who whisper instructions to it.

## The Warehouse Worker Analogy

Imagine a real warehouse worker named Bob. Bob's day looks like this:

```
1. Bob stands at his desk (HOME), waiting.
2. A manager hands him an order: "Go fetch the package from Shelf 7."
3. Bob starts walking, following the painted lines on the floor.
4. As he walks, he checks each shelf's barcode tag.
5. When he finds Shelf 7, he stops.
6. He waits for the picker to grab the item.
7. He turns 180 degrees.
8. He walks back, following the lines.
9. When he reaches his desk, he stops.
10. He waits for the next order.
```

This is **exactly** what Stage 4 implements. Bob's brain has 6 functions:

| Bob's Brain Function | Our ROS Node |
|---|---|
| "What am I doing right now?" (overall manager) | `state_machine_node` |
| "What barcode am I reading?" | `rfid_reader_node` |
| "Should I turn left at this intersection?" | `junction_handler_node` |
| "Time to spin 180°!" | `pivot_controller_node` |
| "Wait for the picker to do their job." | `arm_stub_node` |
| "Hey Bob, here's a new order." | `send_order` (CLI tool) |

## What Is a "State Machine"?

A state machine is just a **fancy name for a checklist** that says "you can only be doing ONE of these things at a time, and here are the rules for switching between them."

Bob's possible states:
- **IDLE** = Standing at desk, doing nothing
- **GOING** = Walking toward target shelf
- **AT_SHELF** = Just arrived at the right shelf
- **WAITING** = Standing at shelf while picker works
- **PIVOTING** = Spinning 180°
- **RETURNING** = Walking back to desk

The rules for switching states:
```
IDLE → GOING:       only when an order arrives
GOING → AT_SHELF:   only when correct RFID tag is detected
AT_SHELF → WAITING: immediately (just signals "arm, do your thing")
WAITING → PIVOTING: only when arm reports "done"
PIVOTING → RETURNING: only when 180° rotation is complete
RETURNING → IDLE:   only when HOME tag is detected
```

If you understand this diagram, **you understand all of Stage 4**. The rest is just code.

```
   ┌─────────┐
   │  IDLE   │◄────────────────────────────────┐
   └────┬────┘                                 │
        │ order arrives                        │
        ▼                                      │
   ┌─────────┐                                 │
   │  GOING  │ ──────► RFID matches ──────┐    │
   └─────────┘                            │    │
                                          ▼    │
                                  ┌─────────────┐
                                  │  AT_SHELF   │
                                  └──────┬──────┘
                                         │ (auto)
                                         ▼
                                  ┌─────────────┐
                                  │   WAITING   │
                                  └──────┬──────┘
                                         │ arm done
                                         ▼
                                  ┌─────────────┐
                                  │  PIVOTING   │
                                  └──────┬──────┘
                                         │ rotated 180°
                                         ▼
                                  ┌─────────────┐
                                  │  RETURNING  │
                                  └──────┬──────┘
                                         │ HOME tag
                                         └────────┐
                                                  │
                                                  ▼
                                          (back to IDLE)
```

---

# 🎭 PART 2: The Cast of Characters

Six new "actors" join your project. Let me introduce each one with a one-liner before we go deep.

## Actor 1: 📋 The Manager — `state_machine_node`

> *"I keep track of what we're doing right now and tell everyone else what to do next."*

This is the central brain. Other nodes report to it ("I detected an RFID!", "I finished pivoting!"), and it makes decisions ("OK now turn around" or "OK now go home").

It's the ONLY node that knows what state the AGV is in.

## Actor 2: 👁️ The Reader — `rfid_reader_node`

> *"I watch the AGV's position and shout whenever it gets close to an RFID tag."*

In real life, an RFID reader uses radio waves. In simulation, we cheat: we know where every tag is, and we just check distance. When the AGV is within 25 cm of a tag, this node yells "TAG DETECTED: S07!"

## Actor 3: 🗺️ The Navigator — `junction_handler_node`

> *"At intersections, I know which way to turn."*

The line follower can only do "follow whatever line is in front of me." But at a T-junction, there are TWO lines (the main aisle and a spur). This node briefly takes control, executes a turn into the correct spur, and hands control back to the line follower.

## Actor 4: 🔄 The Dancer — `pivot_controller_node`

> *"On command, I spin the AGV exactly 180 degrees."*

When the arm is done picking, the AGV needs to face the other way. This node does that turn precisely using IMU feedback (knows when it's rotated exactly π radians = 180°).

## Actor 5: 🦾 The Stunt Double — `arm_stub_node`

> *"I pretend to be a robotic arm. Wait 3 seconds, then say 'done'."*

This is a placeholder. When you build Component 2 (real arm), you'll replace this with a real arm controller. For now, it's a 3-second timer.

## Actor 6: 📨 The Customer — `send_order` (CLI tool)

> *"I'm how you tell the AGV 'go fetch shelf 7'."*

This isn't even a long-running node — it's a tiny script you run once per order, like:
```bash
ros2 run agv_control send_order S07
```

Later (Stage 5), the GUI will replace this. But for testing Stage 4, the CLI is perfect.

## Plus: 📦 Custom Message Types (`agv_msgs`)

We also need 3 new "message formats" — like envelope types in a postal system:

| Message Type | What It Carries |
|---|---|
| `Order` | `shelf_id, row, col, sku` (which shelf, what item) |
| `RFIDRead` | `tag_id, distance, is_home` (which tag, how close) |
| `AGVState` | `state, current_target, last_rfid` (status report) |

You'll create these as `.msg` files in the `agv_msgs` package.

## Plus: 🗺️ Static Data (`shelf_map.py`)

This is just a Python dictionary that maps shelf names to coordinates:
```python
{
  "S01": {"x": 0.9, "y": 1.0, "aisle": 1, ...},
  "S02": {"x": 0.9, "y": 3.0, "aisle": 1, ...},
  ...
}
```
The state machine and RFID reader both use it to look up "where is shelf S07?"

---

# 🗂️ PART 3: File-by-File Score Card

Here's the complete map of what we're touching in Stage 4.

```
~/warehouse_agv_sim/src/
│
├── agv_msgs/                           ← Currently EMPTY package
│   ├── msg/                                ⭐ CREATE this folder
│   │   ├── Order.msg                       ⭐ NEW FILE
│   │   ├── RFIDRead.msg                    ⭐ NEW FILE
│   │   └── AGVState.msg                    ⭐ NEW FILE
│   ├── CMakeLists.txt                      ✏️ EDIT
│   └── package.xml                         ✏️ EDIT
│
├── agv_description/                    ← UNCHANGED. Don't touch.
│
├── warehouse_world/                    ← UNCHANGED. Don't touch.
│
├── agv_control/                        ← Most of the work happens here
│   ├── agv_control/
│   │   ├── (Stage 3 files)             ← UNCHANGED. Don't touch.
│   │   │   ├── line_follower_node.py
│   │   │   ├── optical_sensor_node.py
│   │   │   └── track_map.py
│   │   │
│   │   ├── shelf_map.py                    ⭐ NEW FILE
│   │   ├── rfid_reader_node.py             ⭐ NEW FILE
│   │   ├── pivot_controller_node.py        ⭐ NEW FILE
│   │   ├── arm_stub_node.py                ⭐ NEW FILE
│   │   ├── junction_handler_node.py        ⭐ NEW FILE
│   │   ├── state_machine_node.py           ⭐ NEW FILE
│   │   └── send_order.py                   ⭐ NEW FILE
│   │
│   ├── launch/
│   │   └── agv_brain.launch.py             ✏️ EDIT (add 5 new nodes)
│   │
│   ├── package.xml                         ✏️ EDIT (add 2 deps)
│   └── setup.py                            ✏️ EDIT (add 6 entry points)
│
└── agv_bringup/                        ← UNCHANGED for now (Stage 5)
```

## Score

| Action | Count |
|---|---|
| ⭐ **Create** | **10 new files** (3 messages, 7 Python nodes) |
| ✏️ **Edit** | **5 files** (CMakeLists, 2 package.xml, setup.py, launch.py) |
| ✅ **Leave alone** | Everything else |

That's it. Ten new files, five edits, and your AGV gets a brain.

---

# 🔧 PART 4: Step-by-Step Execution

I'm going to break this into **5 sub-stages**. Each sub-stage is independently testable. Don't skip ahead — if something breaks, you'll know exactly which sub-stage caused it.

> 💡 **All the actual code is already in your conversation file** (`Stage_1 Complete, Awaiting Confirmation.md`, in the "Stage 4" section). I'll tell you which file to copy from there at each step. I'm not going to retype 800 lines of code that you already have.

---

## ⏱️ STEP 0 — Backup First (1 minute)

```bash
cd ~/warehouse_agv_sim
git add -A
git commit -m "Snapshot before Stage 4 (state machine)"
```

If you don't use git:
```bash
cd ~
cp -r warehouse_agv_sim warehouse_agv_sim_BACKUP_before_stage4
```

✅ **Checkpoint:** You can always rewind.

---

## 🟦 SUB-STAGE 4A — Custom Messages (15 minutes)

### Why first?
Every other node in Stage 4 uses these message types. If we build them last, nothing else compiles. So we do them first.

### Files to create (3 messages)

In `~/warehouse_agv_sim/src/agv_msgs/`:

```bash
mkdir -p ~/warehouse_agv_sim/src/agv_msgs/msg
```

Then create these 3 tiny files. Copy contents from the original conversation file's "Stage 4 Step 1.1" section:

| File | What's inside |
|---|---|
| `msg/Order.msg` | 4 fields: shelf_id, row, col, sku |
| `msg/RFIDRead.msg` | 3 fields: tag_id, distance, is_home |
| `msg/AGVState.msg` | 3 fields: state, current_target, last_rfid |

### Files to edit (2 config files)

| File | What changes |
|---|---|
| `CMakeLists.txt` | Replace contents (registers the 3 messages with ROS) |
| `package.xml` | Replace contents (declares ament_cmake build type, adds rosidl deps) |

Both replacements are spelled out in "Stage 4 Step 1.2" and "Step 1.3" of your conversation file.

### Test it

```bash
cd ~/warehouse_agv_sim
colcon build --packages-select agv_msgs
source install/setup.bash
ros2 interface show agv_msgs/msg/Order
```

✅ **Checkpoint:** You should see something like:
```
string shelf_id
int32  row
int32  col
string sku
```

If you do, **the messages are registered system-wide** and any other ROS node can now use them.

---

## 🟦 SUB-STAGE 4B — The Static Data (5 minutes)

### Just one new file

Create `~/warehouse_agv_sim/src/agv_control/agv_control/shelf_map.py`.

**Where to find the code:** "Stage 4 Step 2" of your conversation file.

This file is pure Python — no ROS at all. It builds a dictionary mapping `S01`, `S02`, ..., `S20` to their world coordinates.

### Test it

```bash
python3 ~/warehouse_agv_sim/src/agv_control/agv_control/shelf_map.py
```

✅ **Checkpoint:** You should see all 20 shelves listed with their coordinates.

---

## 🟦 SUB-STAGE 4C — The Five Worker Nodes (45 minutes)

These can be created in any order, but I recommend this sequence (simplest to most complex):

### 1. `arm_stub_node.py` (the simplest — 30 lines)
**Where:** "Stage 4 Step 5" of your conversation file.
**What it does:** Listens for `/arm/start_task = true`, waits 3 seconds, publishes `/arm/task_done = true`. That's it.

### 2. `pivot_controller_node.py`
**Where:** "Stage 4 Step 4" of your conversation file.
**What it does:** Listens for a target angle on `/agv/pivot_cmd`, rotates the AGV until it reaches that angle (using `/agv/odom`), publishes `/agv/pivot_done`.

### 3. `rfid_reader_node.py`
**Where:** "Stage 4 Step 3" of your conversation file.
**What it does:** Listens to `/agv/odom`, computes distance to all 21 tags (20 shelves + HOME), publishes `/agv/rfid_detected` whenever within 25 cm of any tag.

### 4. `junction_handler_node.py`
**Where:** "Stage 4 Step 6" of your conversation file.
**What it does:** Watches the AGV's state and position. When state = GOING and AGV reaches the target aisle's X-coordinate while still on the main aisle, it briefly disables the line follower and steers left into the spur.

### 5. `state_machine_node.py` (the boss — 200 lines)
**Where:** "Stage 4 Step 7" of your conversation file.
**What it does:** Orchestrates everything. Receives orders, transitions states, sends commands to all the other nodes.

### Test after creating each

After creating each file, you can do a syntax sanity check:
```bash
python3 -c "import ast; ast.parse(open('PATH/TO/FILE.py').read()); print('OK')"
```

You won't be able to *run* them yet (`setup.py` hasn't been updated), but at least you'll catch typos early.

✅ **Checkpoint:** All 5 files exist and have valid Python syntax.

---

## 🟦 SUB-STAGE 4D — The CLI Tool (5 minutes)

Create `~/warehouse_agv_sim/src/agv_control/agv_control/send_order.py`.

**Where to find code:** "Stage 4 Step 8" of your conversation file.

This is a tiny script that sends an Order message and exits. Used for testing.

✅ **Checkpoint:** File exists.

---

## 🟦 SUB-STAGE 4E — Wire Everything Up (15 minutes)

This is where we tell ROS about all the new files.

### 1. Edit `~/warehouse_agv_sim/src/agv_control/setup.py`

Replace the `entry_points` block. The new version is in "Stage 4 Step 10" of your conversation file. It should now have **8 entry points** (Stage 3's `line_follower_node` and `optical_sensor_node`, plus Stage 4's 6 new nodes).

The full list:
```python
entry_points={
    'console_scripts': [
        'line_follower_node     = agv_control.line_follower_node:main',
        'optical_sensor_node    = agv_control.optical_sensor_node:main',
        'rfid_reader_node       = agv_control.rfid_reader_node:main',
        'junction_handler_node  = agv_control.junction_handler_node:main',
        'pivot_controller_node  = agv_control.pivot_controller_node:main',
        'arm_stub_node          = agv_control.arm_stub_node:main',
        'state_machine_node     = agv_control.state_machine_node:main',
        'send_order             = agv_control.send_order:main',
    ],
},
```

### 2. Edit `~/warehouse_agv_sim/src/agv_control/package.xml`

Add two new dependency lines:

```xml
<exec_depend>nav_msgs</exec_depend>
<exec_depend>agv_msgs</exec_depend>
```

(`nav_msgs` is for `Odometry`, `agv_msgs` is your custom message package.)

### 3. Edit/replace `~/warehouse_agv_sim/src/agv_control/launch/agv_brain.launch.py`

Replace the contents with the version from "Stage 4 Step 9" of your conversation file. The new version launches **all 7 nodes** (Stage 3's `optical_sensor_node` and `line_follower_node` PLUS Stage 4's 5 long-running nodes — note `send_order` is NOT a launchable node, it's a CLI tool).

> ⚠️ **Important:** Make sure `optical_sensor_node` is in the launch list! The version in your conversation file was written for the camera-based Stage 3 — it might be missing. If so, add this line at the top of the actions list:
> ```python
> Node(package='agv_control', executable='optical_sensor_node',
>      name='optical_sensor_node', output='screen'),
> ```

✅ **Checkpoint:** No tests yet. Move on to the build.

---

## ⏱️ STEP F — Clean Build (5 minutes)

This is critical. We've created 10 new files. A fresh build catches typos.

```bash
cd ~/warehouse_agv_sim
rm -rf build/ install/ log/
colcon build --symlink-install
source install/setup.bash
```

✅ **Checkpoint:** "Summary: 5 packages finished" with no errors.

If a package fails:
- `agv_msgs` failed → you have a typo in a `.msg` file or `CMakeLists.txt`
- `agv_control` failed → check the error trace, it will name the file
- A node failed to install → you forgot to update `setup.py` entry_points

---

# 🧪 PART 5: Testing — Confidence Building, One Piece at a Time

This is the most important part. **Don't try to test everything at once.** Test each piece in isolation first.

## Test 1: Just the messages

```bash
ros2 interface show agv_msgs/msg/Order
ros2 interface show agv_msgs/msg/RFIDRead
ros2 interface show agv_msgs/msg/AGVState
```

✅ Should print all 3 message definitions.

## Test 2: Just the arm stub (alone, no AGV)

Open 3 terminals (each with `source install/setup.bash`):

```bash
# Terminal 1
ros2 run agv_control arm_stub_node

# Terminal 2
ros2 topic echo /arm/task_done

# Terminal 3
ros2 topic pub --once /arm/start_task std_msgs/Bool "data: true"
```

✅ After 3 seconds, Terminal 2 should print `data: true`. The arm stub is working.

`Ctrl+C` Terminal 1 when done.

## Test 3: Just the RFID reader (with Gazebo)

```bash
# Terminal 1: Launch the world + AGV
ros2 launch agv_description spawn_agv.launch.py

# Terminal 2: Disable line follower so AGV doesn't run away
ros2 topic pub --once /agv/line_follow_enable std_msgs/Bool "data: false"

# Terminal 3: Run the RFID reader
ros2 run agv_control rfid_reader_node

# Terminal 4: Watch for detections
ros2 topic echo /agv/rfid_detected

# Terminal 5: Drive AGV manually
ros2 run teleop_twist_keyboard teleop_twist_keyboard --ros-args -r cmd_vel:=/agv/cmd_vel
```

Drive the AGV close to a shelf. ✅ Within 25 cm of a tag, you should see:
```
tag_id: 'S01'
distance: 0.18
is_home: false
```

The RFID reader is working.

## Test 4: Just the pivot controller

```bash
# Same setup as Test 3, but stop teleop and...
ros2 run agv_control pivot_controller_node

# Send a 180° pivot command
ros2 topic pub --once /agv/pivot_cmd std_msgs/Float32 "data: 3.14159"

# Watch for completion
ros2 topic echo /agv/pivot_done
```

✅ The AGV should rotate in place exactly 180° and then publish `data: true`.

## Test 5: The full mission

Now bring it all together:

```bash
# Terminal 1: World + AGV
ros2 launch agv_description spawn_agv.launch.py

# Terminal 2: All 7 brain nodes
ros2 launch agv_control agv_brain.launch.py
```

The AGV should be **idle** (line follower disabled by state machine).

```bash
# Terminal 3: Send an order
ros2 run agv_control send_order S07
```

**Watch the magic:**
1. State machine logs: `IDLE → GOING`
2. Line follower enabled — AGV starts moving
3. AGV approaches aisle 2 (S07 is in aisle 2)
4. Junction handler logs: "🧭 Junction reached for S07 ... Turning LEFT"
5. AGV turns into spur
6. Line follower re-engages
7. RFID reader logs: "🎯 Target S07 reached! Stopping AGV."
8. State machine: `GOING → AT_SHELF → WAITING`
9. Arm stub waits 3 seconds, logs: "✅ Arm task complete"
10. State machine: `WAITING → PIVOTING`
11. Pivot controller rotates 180°
12. State machine: `PIVOTING → RETURNING`
13. AGV drives back along spur
14. Junction handler turns left back onto main aisle
15. AGV continues to HOME
16. RFID reader detects HOME tag
17. State machine: `RETURNING → IDLE`
18. ✅ Mission complete!

If all 18 events happen, **Stage 4 is done.** Send a few more orders to different shelves to confirm reliability.

---

# 🆘 PART 6: Common Confusions and Issues

## "What's the difference between Stage 3's `track_map.py` and Stage 4's `shelf_map.py`?"

Easy:
- **`track_map.py`** = where the BLACK TAPE LINES are (geometry of the path)
- **`shelf_map.py`** = where the SHELVES are (and their RFID tag locations)

Both are static data files. Both are imported by various nodes. They don't conflict.

## "Why doesn't `send_order` appear in the launch file?"

Because it's not a long-running node — it's a one-shot script. You run it manually whenever you want to send an order. Like calling a friend on the phone instead of having them sit next to you.

In Stage 5, the GUI replaces `send_order` with a button. But `send_order` is still useful for testing.

## "What if the AGV makes the junction turn in the wrong direction?"

The junction handler tries to turn LEFT into spurs (because in our world layout, all spurs branch upward and the AGV is heading right). If your warehouse layout is different, you might need to adjust the turn direction.

In `junction_handler_node.py`, find:
```python
self.begin_turn(direction=+1)
```
Change `+1` to `-1` to turn right instead. There are two places this happens (one for GOING, one for RETURNING).

## "What if the AGV passes the shelf without stopping?"

The detection radius might be too small. Try:
```bash
ros2 param set /rfid_reader_node detection_radius 0.35
```

## "What if the pivot is messy (overshoots, oscillates)?"

The pivot controller's tolerance might be too tight or its angular speed too high. Try:
```bash
ros2 param set /pivot_controller_node angular_speed 0.5
ros2 param set /pivot_controller_node tolerance 0.06
```

## "What if I get `agv_msgs not found` everywhere?"

You forgot to source the install. **Every new terminal needs:**
```bash
source ~/warehouse_agv_sim/install/setup.bash
```

This is the #1 cause of "but it built fine!" confusion.

## "Why are there SO MANY topics now?"

Stage 4 adds 9 new topics:
| Topic | Direction |
|---|---|
| `/agv/order` | Customer → State Machine |
| `/agv/state` | State Machine → everyone |
| `/agv/rfid_detected` | RFID Reader → State Machine |
| `/agv/line_follow_enable` | State Machine → Line Follower |
| `/agv/junction_turn_done` | Junction Handler → (informational) |
| `/agv/pivot_cmd` | State Machine → Pivot Controller |
| `/agv/pivot_done` | Pivot Controller → State Machine |
| `/arm/start_task` | State Machine → Arm Stub |
| `/arm/task_done` | Arm Stub → State Machine |

You can see the full graph with:
```bash
rqt_graph
```
This is the standard ROS visualization tool. Run it after launching everything — the box-and-arrow diagram is incredibly helpful for understanding what talks to what.

## "Should I create the GUI now?"

That's Stage 5. Don't do it yet — finish Stage 4 first, verify everything works with `send_order`, then move to Stage 5 for the polish.

---

# 🏁 PART 7: Final Sanity Check Table

After completing everything, run through this checklist:

| ✅ Check | How to verify |
|---|---|
| ☐ All 3 messages exist | `ros2 interface list \| grep agv_msgs` shows 3 entries |
| ☐ All 6 new nodes runnable | `ros2 run agv_control state_machine_node` (then Ctrl+C) — no error |
| ☐ Build succeeds | `colcon build` finishes with no errors on all 5 packages |
| ☐ AGV stays put after launch | After `ros2 launch agv_control agv_brain.launch.py`, AGV doesn't move |
| ☐ Order triggers GOING | After `ros2 run agv_control send_order S07`, state goes IDLE → GOING |
| ☐ AGV reaches shelf | RFID detection triggers AT_SHELF → WAITING |
| ☐ Arm "completes" | After 3s, state goes WAITING → PIVOTING |
| ☐ AGV pivots 180° | Visual confirmation in Gazebo |
| ☐ AGV returns home | State goes PIVOTING → RETURNING → IDLE |
| ☐ Multiple orders work | Send orders to S01, S07, S13, S20 in sequence (let each finish first) |

If all 10 boxes are checked, **you have a working autonomous warehouse AGV.** 🎉

---

# 🚀 What's Next?

After Stage 4 is solid:
- **Stage 5:** GUI + order queue + polish (your conversation file has the complete code)
- Or skip ahead to **Phase 6:** the IRL hardware build

But finish Stage 4 first. Walking before running.

---

# 🎁 Bonus: Visual Mission Diagram

```
                  ┌─────────────────┐
                  │    YOU type:    │
                  │ ros2 run send_order S07
                  └────────┬────────┘
                           │
                           ▼
              ┌────────────────────────┐
              │   /agv/order   ━━━━━━━━━━━━━━━┓
              └────────────────────────┘     ┃
                                              ┃
                                              ▼
                                ┌──────────────────────┐
                                │  state_machine_node  │
                                │     state: IDLE      │
                                │            ↓         │
                                │     state: GOING     │
                                └────────┬─────────────┘
                                         │ enables
                                         ▼
                              /agv/line_follow_enable=true
                                         │
                                         ▼
                       ┌──────────────────────────┐
                       │     line_follower_node   │
                       │      drives the AGV       │
                       └────────────┬──────────────┘
                                    │ /agv/cmd_vel
                                    ▼
                          ╔════════════════════╗
                          ║  AGV moves on map  ║
                          ╚════════════════════╝
                                    │
                                    │ /agv/odom
                                    ▼
                       ┌──────────────────────────┐
                       │    rfid_reader_node      │ ──► detects S07
                       └──────────────┬───────────┘
                                      │ /agv/rfid_detected
                                      ▼
                                ┌──────────────┐
                                │ state_machine│
                                │   state:     │
                                │   AT_SHELF → │
                                │   WAITING    │
                                └──────┬───────┘
                                       │ /arm/start_task
                                       ▼
                                ┌──────────┐
                                │ arm_stub │ (waits 3s)
                                └────┬─────┘
                                     │ /arm/task_done
                                     ▼
                                ┌──────────────┐
                                │ state_machine│
                                │  state:      │
                                │  PIVOTING    │
                                └──────┬───────┘
                                       │ /agv/pivot_cmd
                                       ▼
                                ┌──────────────┐
                                │pivot_controller│ rotates 180°
                                └──────┬───────┘
                                       │ /agv/pivot_done
                                       ▼
                                ┌──────────────┐
                                │ state_machine│
                                │  state:      │
                                │  RETURNING   │
                                └──────────────┘
                                       │
                                       │ (drives home)
                                       ▼
                              detects HOME tag → IDLE
```

You've got this. Take it one sub-stage at a time. Test before moving on. **One hour of patience now saves five hours of debugging later.** 🛠️
