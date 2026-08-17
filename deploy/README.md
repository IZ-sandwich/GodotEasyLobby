# Deploying noray for EasyLobby

`noray` is the only infrastructure EasyLobby needs. It introduces peers to each
other and relays for the minority who cannot connect directly. It is not in
the data path once a direct connection succeeds.

## Testing locally

For testing locally, run noray natively. Like so:

```sh
git clone https://github.com/foxssake/noray
cd noray
bun install
cp /path/to/easy-lobby/deploy/noray.env .env
bun bin/noray.ts
```

Needs [bun](https://bun.sh). Then leave the addon's project settings at their
defaults (`127.0.0.1:8890`) and run two copies of the demo scene.

### Why not test with Docker locally

Docker Desktop on Windows and macOS cannot run this, and fails in a way that
looks like a config error. Published UDP ports go through Docker's userland
proxy, which rewrites the source address. For example Godot binds UDP 59931 but noray sees 172.18.0.1:38712.
noray records the Docker gateway as your "public" address and its `OK` reply
never finds its way back, so `register_remote()` times out. Even if the reply did
arrive, every address noray handed out for punchthrough would be Docker-internal
and useless.

`network_mode: host` fixes this, but Docker Desktop does not properly support it
on Windows or macOS. On Linux, `docker compose up` from this directory should work locally exactly as it does in production.

## Production - Hosting with your own Linux box aka a Virtual Private Server (VPS)

Example setup:
```sh
scp -r deploy/ you@your-server:~/noray/
ssh you@your-server
cd ~/noray && docker compose up -d
```

Then you'll need to open the firewall, example settings in table below. You may also need to run additional commands depending on your provider/os.

| Port | Protocol | Purpose |
| --- | --- | --- |
| 8890 | TCP | Control channel - clients register and request connections |
| 8809 | UDP | Registrar - clients announce their public address |
| 49152–51200 | UDP | Relay ports, one per relayed peer |

Then configure the game to point at the noray server: **Project Settings -> Easy Lobby -> Noray -> Host**.

## Architecture: amd64 vs ARM

`ghcr.io/foxssake/noray:main` is published for linux/amd64 - there is no
arm64 image. On an ARM host (e.g. a rapsberry pi), comment out `image:` and uncomment the `build:` block in the
compose file:

```yaml
build:
  context: "https://github.com/foxssake/noray.git#main"
```

## About noray's config

`noray.env` is mostly noray's defaults. The two lines that matter to EasyLobby:

```env
NORAY_OID_LENGTH=6
NORAY_OID_CHARSET=ABCDEFGHJKMNPQRSTUVWXYZ
```

This config sets up a simple 6 letter the "join code" with no "I", "L", or "O" characters for easy legibility and sharing if read outloud.

## Capacity and cost

Estimates for 4 players playing for 30 minutes:

| Game traffic | Per relayed session | On a ~20 TB/mo VPS |
| --- | --- | --- |
| Turn-based (~2 KB/s/player) | ~22 MB | ~900,000 sessions |
| Co-op, 20 Hz (~15 KB/s) | ~162 MB | ~123,000 sessions |
| Fast action, 60 Hz (~50 KB/s) | ~540 MB | ~37,000 sessions |

A minority of sessions should relay so real totals should be
higher. Bandwidth is not the binding constraint, the 2,048 relay ports are.
That is 2,048 concurrent relayed peers, which at a ~15% relay rate is roughly
13,000 concurrent players.

These are estimates from documented limits. Replace them with real numbers from your game's metrics endpoint before relying on them.

## Operating it

- To cover crashes use `restart: unless-stopped` in docker.
- Metrics can be looked at from noray on port `8891`. Watch relay port usage as that is probably the ceiling you will hit first.
- noray down means no new lobbies apart from LAN. Existing direct connections survive, since noray is not in their data path. Relayed sessions die with it.
- The relay lifetime caps (default `4hr` / `4Gb` adjusted in `noray.env`) cut long sessions. Raise both for games with long matches, or relayed players will get dropped mid-game.
