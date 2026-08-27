# Build Docker. Two binaries out of ONE image, selected by entrypoint:
# /bin/grf-football is the game server, /bin/grf-football-player is every policy.
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/grf-football
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .
# The committed nim.cfg (if any) pins the AUTHOR's package paths; rebuild it
# from THIS container's package tree, exactly as CI does.
RUN rm -f nim.cfg && \
  for pkg in /root/.nimby/pkgs/*; do \
    if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg; \
    else echo "--path:\"$pkg\"" >> nim.cfg; fi; \
  done && \
  echo '--path:"src"' >> nim.cfg && cat nim.cfg

ARG NimFlags="-d:release -d:useMalloc --opt:speed --stackTrace:on --threads:on --mm:orc"
RUN nim c $NimFlags --nimcache:/tmp/grf-football-nimcache --out:grf-football src/grf_football.nim && \
    nim c $NimFlags --nimcache:/tmp/grf-football-player-nimcache \
      --out:grf-football-player src/grf_football_player.nim

# Run Docker.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/grf-football
COPY --from=build /workspace/grf-football/grf-football /bin/grf-football
COPY --from=build /workspace/grf-football/grf-football-player /bin/grf-football-player
COPY --from=build /workspace/grf-football/*.json ./
COPY --from=build /workspace/grf-football/data ./data
COPY --from=build /workspace/grf-football/client ./client

CMD ["/bin/grf-football"]
