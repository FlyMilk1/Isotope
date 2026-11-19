# Isotope WebSocket Quickstart

## 1. Setup & Start Server

```bash
bundle install
bundle exec ruby server.rb
```

Isotope listens on `ws://localhost:6464/ws` by default (override with `PORT=8080 bundle exec ruby server.rb`).

## 2. Connect & Use via WebSocket

Every message is a JSON object with an `"action"` field (and optional `"request_id"` echoed back in the reply).

```js
const ws = new WebSocket("ws://localhost:6464/ws");

ws.onopen = () => {
  // 1. Create a scene (auto-subscribes you to its updates)
  ws.send(JSON.stringify({ action: "create_scene", scene_id: "arena" }));

  // 2. Add a rigid body to the scene
  ws.send(JSON.stringify({
    action: "create_rigidbody",
    scene_id: "arena",
    rigid_body: {
      mass: 2.0,
      position: { x: 0, y: 0 },
      collider: { type: "CircleCollider", radius: 0.5 }
    }
  }));

  // 3. Apply a force and step the simulation
  ws.send(JSON.stringify({
    action: "add_linear_force",
    scene_id: "arena",
    rigidbody_id: 1,
    force: { x: 4.0, y: -19.6 }
  }));

  ws.send(JSON.stringify({
    action: "update",
    scene_id: "arena",
    time_step: 0.016
  }));
};

ws.onmessage = (event) => {
  const msg = JSON.parse(event.data);
  console.log(msg);
  // Direct replies have msg.status === "ok" | "error"
  // Broadcasts to other subscribed clients have msg.event ("scene_updated", "rigidbody_created", "rigidbody_removed")
};
```

## 3. Supported Actions

| Action | Key Fields | Description |
| :--- | :--- | :--- |
| `ping` | — | Health check (`pong`) |
| `create_scene` | `scene_id` (opt.), `scene` (opt.) | Create a new scene |
| `get_scene` / `list_scenes` | `scene_id` (for `get_scene`) | Fetch scene snapshot(s) |
| `delete_scene` | `scene_id` | Remove a scene |
| `create_rigidbody` | `scene_id`, `rigid_body` | Add a body to a scene |
| `get_rigidbody` / `remove_rigidbody` | `scene_id`, `rigidbody_id` | Read or remove a body |
| `add_linear_force` | `scene_id`, `rigidbody_id`, `force` | Apply `{ x, y }` force |
| `update` (or `step`) | `scene_id`, `time_step` (opt., default `1/60`) | Step scene & broadcast |
| `update_all` | `time_step` (opt.) | Step all scenes |
| `save` / `load` | `scene_id`, `file_path` | Save or load scene JSON |
| `subscribe` / `unsubscribe` | `scene_id` | Listen/stop listening to scene broadcasts |
