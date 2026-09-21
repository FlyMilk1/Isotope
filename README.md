# Isotope

A real-time 2D physics simulation server, built on [Rubidium](https://github.com/FlyMilk1/Rubidium).

Isotope loads a scene described in JSON, steps it forward in time using the
Rubidium physics engine, and streams the resulting state to every connected
client over WebSockets. Clients send scenes and control messages; Isotope
owns the simulation and broadcasts authoritative state at a fixed tick rate.

## What it does

- Accepts scene definitions (bodies, gravity, initial velocities) as JSON over a WebSocket connection
- Steps the simulation on a fixed timestep, independent of client frame rate or network jitter
- Broadcasts compact state snapshots to all connected clients every tick
- Supports multiple concurrent, independent scenes (sessions)
- Acts as the single source of truth for simulation state — clients render, Isotope decides

## What it isn't

Isotope doesn't implement physics itself. Rigid-body dynamics, vector math,
and collision resolution live in Rubidium. Isotope is the delivery layer:
session management, the simulation loop, JSON translation, and the WebSocket
protocol.

## Architecture

```
Client(s)  ⇄  JSON over WebSocket  ⇄  Isotope  ⇄  Rubidium (physics engine)
```

## Requirements

- Ruby 3.0+
- Linux (Isotope's server layer does not support Windows)

## Installation

```bash
git clone <isotope-repo-url>
cd isotope
bundle install
```

## Usage

```bash
bundle exec ruby server.rb
```

By default Isotope listens on port `6464` and serves the WebSocket endpoint
at `/ws`.

## License

MIT
