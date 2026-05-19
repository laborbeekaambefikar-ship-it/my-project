# 🔥 HOTFIX — SKU Always Shows "SKU-0000"

> Bug: After sending an order, SKU appears as `SKU-0000` in the GUI/logs even though you typed `SKU-1042`.

This is **two bugs combined**:

## Bug A — GUI loses the SKU after first send

The default SKU box has `SKU-1042`. But if you ever clear it or the variable returns empty, the Python code falls back to `'SKU-0000'`.

## Bug B — SKU is never propagated through the system

The `Order` message has a `sku` field. But:
- `state_node` saves the order but **doesn't include SKU in AGVState broadcasts**
- The GUI only reads `AGVState`, so it can never display the real SKU after the order was sent
- Without seeing it propagated back, you can't tell if the system actually received it

---

# 🔧 The 4 Fixes

## Fix #1 — Update `AGVState.msg` to include SKU

```bash
nano ~/agv_ws/src/agv_msgs/msg/AGVState.msg
```

Replace contents with:

```
string state
string current_target
string current_sku
string last_rfid
```

(Added `current_sku` field)

---

## Fix #2 — Update `state_node.py` to broadcast SKU

```bash
nano ~/agv_ws/src/agv_brain/agv_brain/state_node.py
```

Find this method:

```python
    def broadcast_state(self):
        m = AGVState()
        m.state = self.state
        m.current_target = self.order.shelf_id if self.order else ''
        m.last_rfid = self.last_rfid
        self.state_pub.publish(m)
```

**Replace** with:

```python
    def broadcast_state(self):
        m = AGVState()
        m.state = self.state
        m.current_target = self.order.shelf_id if self.order else ''
        m.current_sku    = self.order.sku if self.order else ''
        m.last_rfid = self.last_rfid
        self.state_pub.publish(m)
```

(Just added the `current_sku` line.)

---

## Fix #3 — Update `gui_node.py` to display the SKU & log it correctly

```bash
nano ~/agv_ws/src/agv_brain/agv_brain/gui_node.py
```

This file needs **3 small changes**.

### Change A: Update `state_cb` to pass SKU through

Find:

```python
    def state_cb(self, msg):
        self.ui_q.put(('state', {'state': msg.state,
                                 'target': msg.current_target,
                                 'rfid': msg.last_rfid}))
```

**Replace** with:

```python
    def state_cb(self, msg):
        self.ui_q.put(('state', {'state': msg.state,
                                 'target': msg.current_target,
                                 'sku': msg.current_sku,
                                 'rfid': msg.last_rfid}))
```

### Change B: Add SKU label to the dashboard

Find this section in `build_ui` (the "Position" row):

```python
        tk.Label(f2, text='Position:', bg='#2d2d2d', fg='white', font=('Arial', 10, 'bold'))\
            .grid(row=2, column=2, padx=8, pady=4, sticky='e')
        self.pos_lbl = tk.Label(f2, text='(0.00, 0.00)', bg='#1e1e1e', fg='lightgreen',
                                 font=('Courier', 11), width=18)
        self.pos_lbl.grid(row=2, column=3, padx=4, pady=4, sticky='w')
```

**Add this AFTER it** (before the Queue row):

```python
        # SKU display
        tk.Label(f2, text='SKU:', bg='#2d2d2d', fg='white', font=('Arial', 10, 'bold'))\
            .grid(row=3, column=0, padx=8, pady=4, sticky='e')
        self.sku_lbl = tk.Label(f2, text='—', bg='#1e1e1e', fg='magenta',
                                 font=('Courier', 11), width=14)
        self.sku_lbl.grid(row=3, column=1, padx=4, pady=4, sticky='w')
```

Then find the Queue row:

```python
        tk.Label(f2, text='Queue:', bg='#2d2d2d', fg='white', font=('Arial', 10, 'bold'))\
            .grid(row=3, column=0, padx=8, pady=4, sticky='e')
        self.queue_lbl = tk.Label(f2, text='(empty)', bg='#1e1e1e', fg='orange',
                                   font=('Courier', 10), anchor='w', width=55)
        self.queue_lbl.grid(row=3, column=1, columnspan=3, padx=4, pady=4, sticky='w')
```

Change `row=3` to `row=4`:

```python
        tk.Label(f2, text='Queue:', bg='#2d2d2d', fg='white', font=('Arial', 10, 'bold'))\
            .grid(row=4, column=0, padx=8, pady=4, sticky='e')
        self.queue_lbl = tk.Label(f2, text='(empty)', bg='#1e1e1e', fg='orange',
                                   font=('Courier', 10), anchor='w', width=55)
        self.queue_lbl.grid(row=4, column=1, columnspan=3, padx=4, pady=4, sticky='w')
```

### Change C: Update `poll` to display the SKU

Find this in `poll`:

```python
                if kind == 'state':
                    s = data['state']
                    self.state_lbl.config(text=s, bg=self.COLORS.get(s, '#666'))
                    self.target_lbl.config(text=data['target'] or '—')
                    self.rfid_lbl.config(text=data['rfid'] or '—')
```

**Replace** with:

```python
                if kind == 'state':
                    s = data['state']
                    self.state_lbl.config(text=s, bg=self.COLORS.get(s, '#666'))
                    self.target_lbl.config(text=data['target'] or '—')
                    self.rfid_lbl.config(text=data['rfid'] or '—')
                    self.sku_lbl.config(text=data['sku'] or '—')
```

### Change D: Better SKU validation in `send_now` and log the SKU

Find:

```python
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
```

**Replace** with:

```python
    def send_now(self):
        shelf = self.shelf_var.get()
        sku = self.sku_var.get().strip()
        if not sku:
            sku = 'SKU-0000'
            self.write_log('(SKU was empty, using default SKU-0000)')
        if self.cur_state != 'IDLE':
            self.write_log(f'AGV busy ({self.cur_state}) — added to queue: {shelf} ({sku})')
            self.q_orders.append((shelf, sku))
            self.update_queue_lbl()
            return
        self.bridge.send_order(shelf, sku)
        self.write_log(f'Order sent: {shelf} ({sku})')
```

Same change for `add_queue`:

Find:

```python
    def add_queue(self):
        shelf = self.shelf_var.get()
        sku = self.sku_var.get() or 'SKU-0000'
        self.q_orders.append((shelf, sku))
        self.write_log(f'Queued: {shelf} ({sku})')
        self.update_queue_lbl()
```

**Replace** with:

```python
    def add_queue(self):
        shelf = self.shelf_var.get()
        sku = self.sku_var.get().strip()
        if not sku:
            sku = 'SKU-0000'
        self.q_orders.append((shelf, sku))
        self.write_log(f'Queued: {shelf} ({sku})')
        self.update_queue_lbl()
```

---

## Fix #4 — Rebuild

Because we changed a `.msg` file, we need to rebuild **both** packages:

```bash
cd ~/agv_ws
colcon build --symlink-install --packages-select agv_msgs agv_brain
source install/setup.bash
```

> ⚠️ **Important:** After modifying a `.msg` file, you ALWAYS need to rebuild and re-source. Otherwise nodes will use the old message format and silently drop the new field.

---

# 🧪 Test It

```bash
# Kill any running stuff first
pkill -9 -f ros2; pkill -9 -f gz; pkill -9 -f rviz; sleep 2

# Launch
ros2 launch agv_run all.launch.py
```

When the GUI opens:

1. ✅ The SKU textbox should show `SKU-1042` (default)
2. Type something different, e.g., `SKU-9999`
3. Pick **S05**, click **SEND ORDER**
4. ✅ The dashboard should now show:
   ```
   State: GOING    Target: S05
   SKU:   SKU-9999   ← NEW: shows the actual SKU you sent
   Position: (...)
   ```
5. ✅ The mission log should show:
   ```
   [12:34:56] Order sent: S05 (SKU-9999)
   ```

---

# 🆘 If It Still Shows SKU-0000

This means the message rebuild didn't take effect. Run:

```bash
# Nuclear option
cd ~/agv_ws
rm -rf build/ install/ log/
colcon build --symlink-install
source install/setup.bash
```

This forces ALL packages to rebuild from scratch. Particularly important after `.msg` changes because ROS caches the generated Python code.

If you STILL see SKU-0000 after a clean rebuild, run:

```bash
ros2 interface show agv_msgs/msg/AGVState
```

It should output:
```
string state
string current_target
string current_sku
string last_rfid
```

If it still shows the old version (3 fields), the rebuild didn't actually rebuild `agv_msgs`. Try:

```bash
cd ~/agv_ws
rm -rf build/agv_msgs install/agv_msgs
colcon build --packages-select agv_msgs
colcon build --packages-select agv_brain
source install/setup.bash
```

---

# 📝 Why This Bug Existed

The original `AGVState.msg` was designed before we thought about displaying SKU. Adding SKU as an afterthought required:

1. Adding it to the message (Fix #1)
2. Setting it in the publisher (Fix #2)
3. Reading it in the subscriber (Fix #3)
4. Rebuilding generated Python code (Fix #4)

This is a common pattern in ROS — every time you want to expose a new piece of data, you touch the message + publisher + subscriber. Now you've done it once, you'll know the drill.

---

# 💡 Pro Tip: Always Watch the Topic Directly

When debugging "is X being sent correctly?" — don't trust the GUI. Watch the topic:

```bash
ros2 topic echo /agv/order
```

After clicking SEND, you'll see the actual message that was published:

```
shelf_id: S05
aisle: 2
sku: SKU-1042
```

If the SKU there is wrong, the bug is in the GUI's send code. If it's right but the dashboard shows wrong, the bug is in the broadcast/subscribe path. **This is the gold-standard debug technique.**
