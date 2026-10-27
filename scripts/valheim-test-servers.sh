#!/bin/bash
# Two throwaway Valheim dedicated servers for testing a port's online play:
#   crossplay  PlayFab Party (-crossplay): join by IP or join code       ports 2456-2457/udp
#   steam      Steam networking only: join by IP, server list           ports 2466-2467/udp
# Both run the free Linux server (Steam app 896660, anonymous download) in
# Docker on a colima VM, published on the Mac's LAN address so an iPad on the
# same network can join too. The server is x86_64 but runs under Box64 in an
# arm64 container: under Rosetta or QEMU its Mono JIT aborts at start
# (x86-codegen.h:410, offset == (gint32)offset) because neither keeps JIT code
# within 2 GB of the code it calls; Box64 does.
#
#   scripts/valheim-test-servers.sh up       download/update the server, start the VM and both servers
#   scripts/valheim-test-servers.sh status   addresses, password, join code, last log lines
#   scripts/valheim-test-servers.sh logs crossplay|steam
#   scripts/valheim-test-servers.sh down     stop the servers (add --vm to stop the VM too)
#
# Everything lives under $VALHEIM_SERVERS_HOME (default <RECOMP_HOME>/build/valheim-servers),
# the VM under $COLIMA_HOME (default <RECOMP_HOME>/build/colima): keep both off a full disk.
# The password is random, made on first use and kept in $VALHEIM_SERVERS_HOME/password.
# Set VALHEIM_SERVERS_PUBLIC=1 to list the servers on Steam's community list (they
# register with Valve; joining from the list still needs the ports reachable).
set -euo pipefail

CODE=$(cd "$(dirname "$0")/.." && pwd)
RECOMP_HOME=${RECOMP_HOME:-$CODE}
DIR=${VALHEIM_SERVERS_HOME:-$RECOMP_HOME/build/valheim-servers}
export COLIMA_HOME=${COLIMA_HOME:-$RECOMP_HOME/build/colima}
PROFILE=valheim
export DOCKER_CONTEXT=colima-$PROFILE
IMAGE=recomp-valheim-box64
BOX64=v0.4.4
PUBLIC=${VALHEIM_SERVERS_PUBLIC:-0}

lan_ip() {
    if [ -n "${VALHEIM_SERVERS_HOST:-}" ]; then echo "$VALHEIM_SERVERS_HOST"; return; fi
    local iface
    iface=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')
    ipconfig getifaddr "${iface:-en0}"
}

password() {
    [ -s "$DIR/password" ] || { mkdir -p "$DIR"; openssl rand -hex 5 > "$DIR/password"; }
    cat "$DIR/password"
}

download() {
    local cmd=$DIR/steamcmd
    if [ ! -x "$cmd/steamcmd.sh" ]; then
        mkdir -p "$cmd"
        curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz | tar xz -C "$cmd"
    fi
    # The Mac steamcmd (x86_64, Rosetta 2) fetches the Linux build; the Linux
    # steamcmd is 32-bit, which the arm64 VM cannot run.
    "$cmd/steamcmd.sh" +@sSteamCmdForcePlatformType linux +force_install_dir "$DIR/server" \
        +login anonymous +app_update 896660 validate +quit | grep -E "Success|ERROR|Error" || true
    [ -x "$DIR/server/valheim_server.x86_64" ] || { echo "server download failed" >&2; exit 1; }
}

vm_up() {
    if ! colima status "$PROFILE" >/dev/null 2>&1; then
        # colima makes its context the default; put the user's back afterwards.
        local was
        was=$(DOCKER_CONTEXT= docker context show 2>/dev/null || echo default)
        # lima forwards published ports to 127.0.0.1 only; this rule puts the
        # servers' UDP ports on every address of the Mac, the LAN one included.
        mkdir -p "$COLIMA_HOME/_lima/_config"
        cat > "$COLIMA_HOME/_lima/_config/override.yaml" <<EOF
portForwards:
  - guestIP: 0.0.0.0
    guestPortRange: [2456, 2467]
    hostIP: 0.0.0.0
    proto: any
EOF
        # The grpc forwarder carries UDP; the ssh one does not.
        colima start "$PROFILE" --vm-type vz --arch aarch64 --cpus 4 --memory 6 \
            --disk 30 --port-forwarder grpc --mount "$DIR:w"
        DOCKER_CONTEXT= docker context use "$was" >/dev/null
    fi
}

start_server() { # name port world crossplay
    local name=$1 port=$2 world=$3 cross=$4 ip pw
    ip=$(lan_ip); pw=$(password)
    mkdir -p "$DIR/data-$name"
    docker rm -f "valheim-$name" >/dev/null 2>&1 || true
    docker run -d --name "valheim-$name" --restart unless-stopped \
        -v "$DIR/server:/irongate" -v "$DIR/data-$name:/data" \
        -p "$port-$((port + 1)):$port-$((port + 1))/udp" \
        -w /irongate -e SteamAppId=892970 -e BOX64_LD_LIBRARY_PATH=/irongate/linux64:/irongate \
        "$IMAGE" box64 ./valheim_server.x86_64 -nographics -batchmode -name "Recomp $name test" \
        -port "$port" -world "$world" -password "$pw" -savedir /data -public "$PUBLIC" $cross >/dev/null
    echo "valheim-$name: $ip:$port"
}

image() {
    # Box64 built from source with its arm64 dynarec, plus the libraries the
    # server's own Dockerfile installs. PlayFab Party (libparty.so) calls libogg,
    # which it gets through the x86_64 libpulse; Box64 runs Arm's libpulse instead,
    # so an x86_64 libogg is preloaded.
    mkdir -p "$DIR/image"
    cat > "$DIR/image/Dockerfile" <<EOF
FROM ubuntu:22.04 AS build
RUN apt-get update && apt-get install -y git cmake python3 build-essential && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 -b $BOX64 https://github.com/ptitSeb/box64 /box64 && mkdir /box64/build && cd /box64/build \\
 && cmake .. -DARM_DYNAREC=ON -DCMAKE_BUILD_TYPE=RelWithDebInfo && make -j\$(nproc) && make install DESTDIR=/out
FROM ubuntu:22.04
RUN apt-get update && apt-get install -y ca-certificates curl libatomic1 libpulse0 libpulse-mainloop-glib0 zlib1g && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/ /
RUN curl -fsSLo /tmp/ogg.deb http://archive.ubuntu.com/ubuntu/pool/main/libo/libogg/libogg0_1.3.5-0ubuntu3_amd64.deb \\
 && dpkg-deb -x /tmp/ogg.deb /x86 && rm /tmp/ogg.deb
ENV BOX64_LD_PRELOAD=/x86/usr/lib/x86_64-linux-gnu/libogg.so.0
EOF
    docker build -q -t "$IMAGE" "$DIR/image" >/dev/null
}

up() {
    download
    vm_up
    docker image inspect "$IMAGE" >/dev/null 2>&1 || image
    start_server crossplay 2456 RecompCrossplay -crossplay
    start_server steam 2466 RecompSteam ""
    echo "password: $(password)   (the join code shows in 'status' once the crossplay server is up)"
}

status() {
    echo "LAN address: $(lan_ip)   password: $(password)"
    for n in crossplay steam; do
        echo "== valheim-$n: $(docker inspect -f '{{.State.Status}}' "valheim-$n" 2>/dev/null || echo absent)"
        docker logs "valheim-$n" 2>&1 | grep -E "registered with join code|Game server connected|Opened (PlayFab|Steam) server|Got connection|Got handshake|Connections [0-9]|Peer .* disconnected|Exception" | tail -6 || true
    done
    # The Steam server speaks Valve's SteamNetworkingSockets UDP protocol on its
    # game port: a padded ChallengeRequest (32) gets a ChallengeReply (33).
    python3 - "$(lan_ip)" 2466 <<'EOF'
import socket, struct, sys, time
ts = struct.pack("<Q", int(time.time() * 1e6))
body = b"\x0d" + struct.pack("<I", 1) + b"\x19" + ts + b"\x20\x0b"  # connection_id, my_timestamp, protocol_version
pkt = struct.pack("<BH", 32, len(body)) + body
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(3)
s.sendto(pkt.ljust(512, b"\0"), (sys.argv[1], int(sys.argv[2])))
try:
    print("steam game port: answers" if s.recvfrom(2048)[0][0] == 33 else "steam game port: unexpected reply")
except OSError:
    print("steam game port: no answer on %s:%s" % (sys.argv[1], sys.argv[2]))
EOF
}

case "${1:-}" in
    up) up ;;
    status) status ;;
    logs) docker logs -f "valheim-${2:?crossplay or steam}" ;;
    down)
        docker rm -f valheim-crossplay valheim-steam >/dev/null 2>&1 || true
        [ "${2:-}" = --vm ] && colima stop "$PROFILE"
        ;;
    *) sed -n '2,22p' "$0"; exit 2 ;;
esac
