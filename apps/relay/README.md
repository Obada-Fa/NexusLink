# @nexuslink/relay

WebSocket relay server for NexusLink peer-to-peer connections.

## Start

```bash
bun run dev          # start on ws://localhost:3033
RELAY_PORT=9090 bun run dev  # custom port
```

## Usage

Clients connect at `ws://localhost:3033/room/<roomId>`. First peer in a room becomes host, second becomes client. Messages relay between peers.

## Scripts

- `bun run dev` — start relay
- `bun run build` — type-check
- `bun test` — run tests

Room expiry: 30 minutes. Cleanup interval: 5 minutes.
