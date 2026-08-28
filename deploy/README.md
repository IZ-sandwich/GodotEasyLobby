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
scp -r deploy/. you@your-server:~/noray/
ssh you@your-server
cd ~/noray && docker compose up -d
```

Then you'll need to open the firewall, example settings in table below. Note: you may also need to run additional commands to open the firewall depending on your provider/os.

| Port | Protocol | Purpose |
| --- | --- | --- |
| 8890 | TCP | Control channel - clients register and request connections |
| 8809 | UDP | Registrar - clients announce their public address |
| 61000-62023 | UDP | Relay ports, one per relayed peer |

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
higher. Bandwidth is not the binding constraint, the 1024 relay ports are.
That is 1024 concurrent relayed peers, which at a ~15% relay rate is roughly
7,000 concurrent players.

These are estimates from documented limits. Replace them with real numbers from your game's metrics endpoint before relying on them.

## Monitoring with Prometheus and Grafana (Optional)

noray publishes a plain text list of numbers at `http://127.0.0.1:8891/metrics`.
That page only ever shows the current values, so it cannot answer "how busy were
we last night?". Two pieces fix that, and `monitoring/` sets both up:

- **Prometheus** is the recorder. Every 15 seconds it fetches that page and
  stores every number with a timestamp.
- **Grafana** is a web display. It asks Prometheus for numbers and draws them.
  It stores no data of its own.


Both can run independently of noray with the sample docker-compose file in `deploy/montoring`

### Setup

The files are already under `~/noray/monitoring` if you copied `deploy/` with
the `scp -r` above. Run:

```sh
cd ~/noray/monitoring
docker compose up -d
```

### Viewing it

It is not directly exposed to the internet, but you can reach it over an SSH tunnel like so:

```sh
ssh -N -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 -L 8891:127.0.0.1:8891 you@your-server
```

Then in your browser open <http://127.0.0.1:3000> for the dashboard. The tunnel also gives you
<http://127.0.0.1:9090> for Prometheus' own query page, and
<http://127.0.0.1:8891/metrics> for the raw numbers. Grafana does not ask you
to log in - read-only access is anonymous, which is safe because the port is
loopback only. Log in as `admin`, default password is: `admin` to edit dashboards.

### If Grafana comes up with no dashboard

Almost always directory permissions on the copied files, not the dashboard
itself. `scp -r` copies source permissions, and since Windows has no POSIX mode bits copying `deploy/` from Windows does not set the necessary read permissions. You can look at the logs like so to check if permissions were the issue:

```sh
docker logs noray-grafana 2>&1 | grep -i "permission denied"
```

Run the following as a fix:

```sh
find ~/noray/monitoring/grafana -type d -exec chmod 755 {} +
docker compose restart grafana
```

### Teardown

```sh
docker compose down      # stop, keep recorded history
docker compose down -v   # stop, delete recorded history too
```

### What is in monitoring/

| File | What it does |
| --- | --- |
| `docker-compose.yml` | The two containers. Both use host networking, both bound to `127.0.0.1`. |
| `prometheus.yml` | The scrape target: `127.0.0.1:8891`, every 15s. |
| `grafana/provisioning/datasources/` | Points Grafana at Prometheus so you never type a URL. |
| `grafana/provisioning/dashboards/` | Tells Grafana to load dashboards from a folder. |
| `grafana/dashboards/noray.json` | The dashboard itself. Editable in the browser or manually. |

Both containers need docker's `host` networking since noray binds its metrics to `127.0.0.1`.

### What the metrics mean

| Metric | Type | Meaning |
| --- | --- | --- |
| `noray_active_hosts` | gauge | Peers with an open TCP control connection. Both hosts and joiners register, so this is players, not lobbies. |
| `noray_relay_count` | gauge | Relays currently allocated - one UDP port each. **The number to watch**, capped by `NORAY_UDP_RELAY_PORTS`. |
| `noray_relay_expired` | counter | Relays freed after `NORAY_UDP_RELAY_TIMEOUT` of silence. Normal at session end. |
| `noray_relay_drop_count` | counter | Packets with no matching relay entry. A few at session edges is normal; sustained growth is not. |
| `noray_relay_size` | histogram | Bytes per relayed packet. Use `_sum` for bandwidth and `_count` for packet rate. |
| `noray_relay_duration` | histogram | CPU time to handle one packet, not network latency. |
| `noray_remote_registrar_success` | counter | Peers that completed the address handshake. Effectively joins. |
| `noray_remote_registrar_repeat` | counter | Peers re-registering an address they already had. The addon retries, so some are expected. |
| `noray_remote_registrar_fail` | counter | Rejected registrations. This is what a player experiences as a join timeout. |

A caveat if you write your own panels: `noray_relay_size` is declared without
bucket boundaries, so it inherits Prometheus client defaults meant for seconds
(0.005 to 10). Packet sizes are bytes, so every real packet lands in the
overflow bucket and any percentile you compute from it is meaningless. Its
`_sum` and `_count` are correct, which is why the dashboard only uses those.

The bandwidth panels are drawn in bits per second, since that is how VPS plans
and ISPs quote traffic - hence the `* 8` in those queries. "Average relayed
packet size" is still in bytes.

None of them count packet headers. `noray_relay_size` observes `msg.byteLength`,
which is the UDP payload, so the 20-byte IP and 8-byte UDP headers on every
packet never reach the counter even though your VPS bills them. For game traffic
that error is small. For voice it is not: a 20ms Opus frame at 12 kbps is about
30 bytes of payload carrying 28 bytes of header, so the real wire cost is nearly
double what the graph shows. To chart billed bytes use metrics from your server host or you can add the header back before doubling:

```promql
(rate(noray_relay_size_sum[5m]) + 28 * rate(noray_relay_size_count[5m])) * 16
```

Do note however that noray's `NORAY_UDP_RELAY_MAX_INDIVIDUAL_TRAFFIC` throttle counts **payload only**
(`limiter.validate(message.length)`), so the uncorrected number is the one that
predicts when a relay gets throttled.

### Tuning

- **History length** - `--storage.tsdb.retention.time` and `.size` in
  `docker-compose.yml`. Defaults to 90 days or 2 GB, whichever comes first.
- **Sampling rate** - `scrape_interval` in `prometheus.yml`. Lower means finer
  graphs and more disk.
- **Relay pool size** - the "Relay port usage" gauge divides by `1024`. If you
  change `NORAY_UDP_RELAY_PORTS`, edit that query in `grafana/dashboards/noray.json`.
- **Grafana password** - `GRAFANA_ADMIN_PASSWORD=... docker compose up -d`, or
  put it in a `.env` file next to the compose file. Defaults to `admin`.
- **Image versions** - both images are `:latest`. Pin them to a tag once you
  are happy with the setup, so a `docker compose pull` cannot surprise you.

Do not open ports 3000 or 9090 on your VPS firewall. Prometheus has no
authentication at all, and Grafana is deliberately configured to allow
anonymous reads.

## Operating it

- To cover crashes use `restart: unless-stopped` in docker.
- Watch relay port usage as that is probably the ceiling you will hit first.
- noray down means no new lobbies apart from LAN. Existing direct connections survive, since noray is not in their data path. Relayed sessions die with it.
- The relay lifetime caps (default `4hr` / `4Gb` adjusted in `noray.env`) cut long sessions. Raise both for games with long matches, or relayed players will get dropped mid-game.
