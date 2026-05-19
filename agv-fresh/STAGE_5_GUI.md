# 🎨 Stage 5 — GUI + Master Launcher

> **Goal:** Add a Tkinter GUI for sending orders + a one-command master launcher. Project complete.

**Time:** ~30 minutes. **Files created:** 1 GUI node, 1 master launch file.

---

## 🖼️ What the GUI Looks Like

```
┌─────────────────────────────────────────────────────────┐
│           🤖 AGV Control Center                          │
├─────────────────────────────────────────────────────────┤
│  Send Order                                              │
│   Shelf: [ S07 ▼ ]   SKU: [ SKU-1042 ]                  │
│   [ SEND ORDER ]   [ + ADD TO QUEUE ]                    │
├─────────────────────────────────────────────────────────┤
│  Live Dashboard                                          │
│   State:    [GOING]    Target: S07                       │
│   Last RFID: S03       Position: (3.4, 0.0)              │
│   Queue: S13 → S20                                       │
├─────────────────────────────────────────────────────────┤
│  Mission Log                                             │
│   [12:01:32] Order sent: S07                             │
│   [12:01:33] STATE: IDLE -> GOING                        │
│   [12:01:35] junction #1                                 │
│   ...                                                    │
└─────────────────────────────────────────────────────────┘
```

---

## 📋 Step 1 — Create the GUI Node

```bash
nano ~/agv_ws/src/agv_brain/agv_brain/gui_node.py
```

Paste this **complete file**:

```python
#!/usr/bin/env python3
"""
gui_node.py - Tkinter control panel for the AGV.
"""
import threading
import queue
from datetime import datetime

import rclpy
from rclpy.node import Node
from nav_msgs.msg import Odometry
from agv_msgs.msg import Order, RFIDRead, AGVState

import tkinter as tk
from tkinter import ttk, scrolledtext

from agv_brain.shelf_lib import SHELF_MAP


# ===================== ROS bridge =====================
class RosBridge(Node):
    def __init__(self, ui_q):
        super().__init__('gui_node')
        self.ui_q = ui_q

        self.order_pub = self.create_publisher(Order, '/agv/order', 10)
        self.create_subscription(AGVState, '/agv/state',          self.state_cb, 10)
        self.create_subscription(RFIDRead, '/agv/rfid_detected',  self.rfid_cb, 10)
        self.create_subscription(Odometry, '/agv/odom',           self.odom_cb, 10)

    def send_order(self, shelf_id, sku):
        info = SHELF_MAP[shelf_id]
        m = Order()
        m.shelf_id = shelf_id
        m.aisle = info['aisle']
        m.sku = sku
        self.order_pub.publish(m)

    def state_cb(self, msg):
        self.ui_q.put(('state', {'state': msg.state,
                                 'target': msg.current_target,
                                 'rfid': msg.last_rfid}))

    def rfid_cb(self, msg):
        icon = 'HOME' if msg.is_home else 'TAG'
        self.ui_q.put(('log', f'[{icon}] {msg.tag_id} ({msg.distance:.2f}m)'))

    def odom_cb(self, msg):
        self.ui_q.put(('odom', {'x': msg.pose.pose.position.x,
                                'y': msg.pose.pose.position.y}))


# ===================== GUI =====================
class Gui:
    COLORS = {
        'IDLE':      '#4CAF50',
        'GOING':     '#2196F3',
        'AT_SHELF':  '#FF9800',
        'WAITING':   '#9C27B0',
        'PIVOTING':  '#FF5722',
        'RETURNING': '#00BCD4',
    }

    def __init__(self, root, bridge, ui_q):
        self.root = root
        self.bridge = bridge
        self.ui_q = ui_q
        self.q_orders = []
        self.cur_state = 'IDLE'

        root.title('AGV Control Center')
        root.geometry('850x650')
        root.configure(bg='#1e1e1e')

        self.build_ui()
        self.poll()

    def build_ui(self):
        # === Order entry ===
        f1 = tk.Frame(self.root, bg='#2d2d2d', pady=8)
        f1.pack(fill='x', padx=8, pady=6)

        tk.Label(f1, text='Send Order', font=('Arial', 13, 'bold'),
                 bg='#2d2d2d', fg='white').grid(row=0, column=0, columnspan=4, sticky='w', padx=4)

        tk.Label(f1, text='Shelf:', bg='#2d2d2d', fg='white')\
            .grid(row=1, column=0, padx=4, pady=4, sticky='e')
        self.shelf_var = tk.StringVar(value='S01')
        ttk.Combobox(f1, textvariable=self.shelf_var, values=sorted(SHELF_MAP.keys()),
                     state='readonly', width=8).grid(row=1, column=1, padx=4)

        tk.Label(f1, text='SKU:', bg='#2d2d2d', fg='white')\
            .grid(row=1, column=2, padx=4, pady=4, sticky='e')
        self.sku_var = tk.StringVar(value='SKU-1042')
        tk.Entry(f1, textvariable=self.sku_var, width=14).grid(row=1, column=3, padx=4)

        tk.Button(f1, text='SEND ORDER', command=self.send_now,
                  bg='#4CAF50', fg='white', font=('Arial', 9, 'bold'), width=12)\
            .grid(row=1, column=4, padx=8)
        tk.Button(f1, text='+ QUEUE', command=self.add_queue,
                  bg='#2196F3', fg='white', font=('Arial', 9, 'bold'), width=10)\
            .grid(row=1, column=5, padx=4)

        # === Dashboard ===
        f2 = tk.Frame(self.root, bg='#2d2d2d', pady=8)
        f2.pack(fill='x', padx=8, pady=6)

        tk.Label(f2, text='Live Dashboard', font=('Arial', 13, 'bold'),
                 bg='#2d2d2d', fg='white').grid(row=0, column=0, columnspan=4, sticky='w', padx=4)

        tk.Label(f2, text='State:', bg='#2d2d2d', fg='white', font=('Arial', 10, 'bold'))\
            .grid(row=1, column=0, padx=8, pady=4, sticky='e')
        self.state_lbl = tk.Label(f2, text='IDLE', bg='#4CAF50', fg='white',
                                   font=('Arial', 11, 'bold'), width=12)
        self.state_lbl.grid(row=1, column=1, padx=4, pady=4, sticky='w')

        tk.Label(f2, text='Target:', bg='#2d2d2d', fg='white', font=('Arial', 10, 'bold'))\
            .grid(row=1, column=2, padx=8, pady=4, sticky='e')
        self.target_lbl = tk.Label(f2, text='—', bg='#1e1e1e', fg='yellow',
                                    font=('Courier', 11, 'bold'), width=10)
        self.target_lbl.grid(row=1, column=3, padx=4, pady=4, sticky='w')

        tk.Label(f2, text='RFID:', bg='#2d2d2d', fg='white', font=('Arial', 10, 'bold'))\
            .grid(row=2, column=0, padx=8, pady=4, sticky='e')
        self.rfid_lbl = tk.Label(f2, text='—', bg='#1e1e1e', fg='cyan',
                                  font=('Courier', 11), width=12)
        self.rfid_lbl.grid(row=2, column=1, padx=4, pady=4, sticky='w')

        tk.Label(f2, text='Position:', bg='#2d2d2d', fg='white', font=('Arial', 10, 'bold'))\
            .grid(row=2, column=2, padx=8, pady=4, sticky='e')
        self.pos_lbl = tk.Label(f2, text='(0.00, 0.00)', bg='#1e1e1e', fg='lightgreen',
                                 font=('Courier', 11), width=18)
        self.pos_lbl.grid(row=2, column=3, padx=4, pady=4, sticky='w')

        tk.Label(f2, text='Queue:', bg='#2d2d2d', fg='white', font=('Arial', 10, 'bold'))\
            .grid(row=3, column=0, padx=8, pady=4, sticky='e')
        self.queue_lbl = tk.Label(f2, text='(empty)', bg='#1e1e1e', fg='orange',
                                   font=('Courier', 10), anchor='w', width=55)
        self.queue_lbl.grid(row=3, column=1, columnspan=3, padx=4, pady=4, sticky='w')

        # === Log ===
        f3 = tk.Frame(self.root, bg='#2d2d2d')
        f3.pack(fill='both', expand=True, padx=8, pady=6)
        tk.Label(f3, text='Mission Log', font=('Arial', 13, 'bold'),
                 bg='#2d2d2d', fg='white').pack(anchor='w', padx=4, pady=4)
        self.log = scrolledtext.ScrolledText(f3, height=14, bg='#0a0a0a', fg='#00ff00',
                                              font=('Courier', 9), wrap='word')
        self.log.pack(fill='both', expand=True, padx=4, pady=4)
        self.write_log('AGV Control Center ready.')

    def send_now(self):
        shelf = self.shelf_var.get()
        sku = self.sku_var.get() or 'SKU-0000'
        if self.cur_state != 'IDLE':
            self.write_log(f'AGV busy ({self.cur_state}) — added to queue: {shelf}')
            self.q_orders.append((shelf, sku))
            self.update_queue_lbl()
            return
        self.bridge.send_order(shelf, sku)
        self.write_log(f'Order sent: {shelf} ({sku})')

    def add_queue(self):
        shelf = self.shelf_var.get()
        sku = self.sku_var.get() or 'SKU-0000'
        self.q_orders.append((shelf, sku))
        self.write_log(f'Queued: {shelf} ({sku})')
        self.update_queue_lbl()

    def update_queue_lbl(self):
        if not self.q_orders:
            self.queue_lbl.config(text='(empty)')
        else:
            self.queue_lbl.config(text=' -> '.join(s for s, _ in self.q_orders))

    def poll(self):
        try:
            while True:
                kind, data = self.ui_q.get_nowait()
                if kind == 'state':
                    s = data['state']
                    self.state_lbl.config(text=s, bg=self.COLORS.get(s, '#666'))
                    self.target_lbl.config(text=data['target'] or '—')
                    self.rfid_lbl.config(text=data['rfid'] or '—')
                    if self.cur_state != 'IDLE' and s == 'IDLE' and self.q_orders:
                        nshelf, nsku = self.q_orders.pop(0)
                        self.update_queue_lbl()
                        self.bridge.send_order(nshelf, nsku)
                        self.write_log(f'Auto-dispatch from queue: {nshelf}')
                    if s != self.cur_state:
                        self.write_log(f'STATE: {self.cur_state} -> {s}')
                    self.cur_state = s
                elif kind == 'odom':
                    self.pos_lbl.config(text=f"({data['x']:+.2f}, {data['y']:+.2f})")
                elif kind == 'log':
                    self.write_log(data)
        except queue.Empty:
            pass
        self.root.after(80, self.poll)

    def write_log(self, msg):
        ts = datetime.now().strftime('%H:%M:%S')
        self.log.insert('end', f'[{ts}] {msg}\n')
        self.log.see('end')


# ===================== Main =====================
def main():
    rclpy.init()
    ui_q = queue.Queue()
    bridge = RosBridge(ui_q)

    threading.Thread(target=rclpy.spin, args=(bridge,), daemon=True).start()

    root = tk.Tk()
    Gui(root, bridge, ui_q)
    try:
        root.mainloop()
    except KeyboardInterrupt:
        pass
    finally:
        bridge.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
```

---

## 📋 Step 2 — Register the GUI Node

Edit `setup.py`:

```bash
nano ~/agv_ws/src/agv_brain/setup.py
```

Find the `entry_points` block. **Add one line** for `gui_node`:

```python
    entry_points={
        'console_scripts': [
            'optical_node = agv_brain.optical_node:main',
            'follow_node  = agv_brain.follow_node:main',
            'rfid_node    = agv_brain.rfid_node:main',
            'turn_node    = agv_brain.turn_node:main',
            'pivot_node   = agv_brain.pivot_node:main',
            'arm_node     = agv_brain.arm_node:main',
            'state_node   = agv_brain.state_node:main',
            'send         = agv_brain.send:main',
            'gui_node     = agv_brain.gui_node:main',   # ← NEW
        ],
    },
```

---

## 📋 Step 3 — Create the Master Launcher (`agv_run`)

This is the **one command that starts everything**.

```bash
mkdir -p ~/agv_ws/src/agv_run/launch
nano ~/agv_ws/src/agv_run/launch/all.launch.py
```

Paste:

```python
#!/usr/bin/env python3
"""all.launch.py - Master launcher: Gazebo + AGV + brain + GUI."""

import os
from launch import LaunchDescription
from launch.actions import IncludeLaunchDescription, TimerAction
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch_ros.actions import Node
from ament_index_python.packages import get_package_share_directory


def generate_launch_description():
    pkg_robot = get_package_share_directory('agv_robot')
    pkg_brain = get_package_share_directory('agv_brain')

    spawn = IncludeLaunchDescription(
        PythonLaunchDescriptionSource(os.path.join(pkg_robot, 'launch', 'spawn.launch.py'))
    )

    params = os.path.join(pkg_brain, 'config', 'follow_params.yaml')

    # Brain delayed 5s so Gazebo has time to start publishing /agv/odom
    brain = TimerAction(period=5.0, actions=[
        Node(package='agv_brain', executable='optical_node', name='optical_node', output='screen'),
        Node(package='agv_brain', executable='follow_node',  name='follow_node',  output='screen', parameters=[params]),
        Node(package='agv_brain', executable='rfid_node',    name='rfid_node',    output='screen'),
        Node(package='agv_brain', executable='turn_node',    name='turn_node',    output='screen'),
        Node(package='agv_brain', executable='pivot_node',   name='pivot_node',   output='screen'),
        Node(package='agv_brain', executable='arm_node',     name='arm_node',     output='screen'),
        Node(package='agv_brain', executable='state_node',   name='state_node',   output='screen'),
    ])

    gui = TimerAction(period=7.0, actions=[
        Node(package='agv_brain', executable='gui_node', name='gui_node', output='screen'),
    ])

    return LaunchDescription([spawn, brain, gui])
```

---

## 📋 Step 4 — Update `setup.py` for `agv_run`

```bash
nano ~/agv_ws/src/agv_run/setup.py
```

Replace with:

```python
from setuptools import setup
from glob import glob
import os

package_name = 'agv_run'

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
    description='Master launchers',
    license='MIT',
    entry_points={'console_scripts': []},
)
```

---

## 📋 Step 5 — Update `package.xml` for `agv_run`

```bash
nano ~/agv_ws/src/agv_run/package.xml
```

Replace with:

```xml
<?xml version="1.0"?>
<package format="3">
  <name>agv_run</name>
  <version>0.1.0</version>
  <description>AGV master launcher</description>
  <maintainer email="you@example.com">you</maintainer>
  <license>MIT</license>

  <buildtool_depend>ament_python</buildtool_depend>

  <exec_depend>agv_robot</exec_depend>
  <exec_depend>agv_brain</exec_depend>
  <exec_depend>agv_world</exec_depend>

  <export><build_type>ament_python</build_type></export>
</package>
```

---

## 📋 Step 6 — Final Build

```bash
cd ~/agv_ws
colcon build --symlink-install
source install/setup.bash
```

✅ **Test:** `Summary: 5 packages finished` with no errors.

---

## 📋 Step 7 — The Grand Demo

**One command starts everything:**

```bash
ros2 launch agv_run all.launch.py
```

After ~7 seconds you'll see:
- 🌍 Gazebo with the warehouse
- 🤖 AGV at HOME
- 🖥️ RViz showing the robot
- 🎨 GUI window with shelf dropdown

### Send an order from the GUI

In the GUI:
1. Pick **S07** from the dropdown
2. Leave SKU as default
3. Click **SEND ORDER**

The AGV runs the full mission. State indicator changes color through `GOING → AT_SHELF → WAITING → PIVOTING → RETURNING → IDLE`.

### Test the queue

While the AGV is mid-mission:
1. Pick **S13**, click **+ QUEUE**
2. Pick **S20**, click **+ QUEUE**
3. When AGV returns to IDLE, S13 auto-dispatches
4. When that finishes, S20 dispatches

---

## 🎉 PROJECT COMPLETE!

You built a fully autonomous warehouse AGV simulation:

| Stage | What you built | Status |
|---|---|---|
| 1 | Workspace + warehouse world | ✅ |
| 2 | AGV robot (URDF) | ✅ |
| 3 | Optical sensors + line follower | ✅ |
| 4 | State machine + RFID + junctions | ✅ |
| 5 | GUI + master launcher | ✅ |

### Summary of what you have

```
~/agv_ws/
└── src/
    ├── agv_world/    Warehouse + world generator
    ├── agv_robot/    AGV URDF + spawn
    ├── agv_msgs/     3 custom messages
    ├── agv_brain/    9 nodes (sensors, follower, brain, GUI)
    └── agv_run/      Master launcher
```

**Total ROS topics:** 14
**Total nodes:** 9 (when GUI is on, otherwise 8)
**Lines of code:** ~1500

---

## 🚀 What's Next?

### Option A: Make it prettier
- Add custom textures to shelves in `build_world.py`
- Add a 3D model for the AGV body (use Blender → DAE export)
- Replace the simple boxes with proper meshes

### Option B: Add features
- Multi-AGV (spawn 2-3 AGVs, each with their own namespace)
- Battery simulation (AGV must return for charging)
- Shelf inventory (which SKUs are where)
- Real arm (Component 2): replace `arm_node` stub with MoveIt 2 + 6-DOF arm

### Option C: Real hardware
- Use the IRL build guide from your earlier conversation file
- ESP32 + TCRT5000 IR array + RC522 RFID + N20 motors
- Same logic, real sensors

---

## 🆘 Troubleshooting

| Problem | Fix |
|---|---|
| GUI won't open | `sudo apt install python3-tk` |
| GUI opens but no updates | Brain nodes might not be running. Check `ros2 node list`. |
| Auto-dispatch doesn't work | Wait for state to actually return to IDLE. The poll runs every 80ms. |
| Master launch is too fast | Increase `period=5.0` to `period=8.0` in `all.launch.py` |
| `agv_msgs not found` in GUI | `source install/setup.bash` in the terminal you launched from |
| Multiple Gazebos open | `killall -9 gzserver gzclient` then retry |

---

## 🎬 Demo Tips

For a video/presentation:

1. Start the system, wait for everything to load.
2. Show the warehouse layout in Gazebo.
3. Send an order to **S05** (closest shelf, fast demo).
4. Talk through the state transitions visible in the GUI.
5. Send a queue: S20 + S03 + S15. Show the AGV servicing them in order.
6. Optional: open `rqt_graph` in another terminal to show the node graph.

Have fun! 🚀
