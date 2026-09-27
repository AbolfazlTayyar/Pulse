# Dev image: Lua 5.4 + luarocks + the rocks in market-dev-1.rockspec (ADR 0005).
# The repo is bind-mounted at /app by docker-compose.yml, not copied, so source edits need no
# rebuild. Only a rockspec change needs `docker compose build`.
FROM debian:bookworm-slim

# build-essential + liblua5.4-dev compile the C rocks (luasocket, luasec, busted's luasystem);
# libssl-dev is for luasec; git/unzip/curl let luarocks fetch and unpack rocks.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      lua5.4 liblua5.4-dev luarocks \
      build-essential libssl-dev ca-certificates git unzip curl \
 && rm -rf /var/lib/apt/lists/* \
 && update-alternatives --set lua-interpreter /usr/bin/lua5.4 \
 && update-alternatives --set lua-compiler /usr/bin/luac5.4

# Debian's luarocks package pulls in lua5.1 and points `lua` at it; the alternatives above make
# plain `lua` (what hosts run) Lua 5.4. Fail the build if that ever regresses.
RUN lua -v | grep -q '^Lua 5\.4'

# Same dependency list as the native Linux/WSL path: one rockspec, two consumers.
COPY market-dev-1.rockspec /tmp/market-dev-1.rockspec
RUN luarocks --lua-version=5.4 install --only-deps /tmp/market-dev-1.rockspec \
 && rm -rf /tmp/market-dev-1.rockspec /root/.cache/luarocks

WORKDIR /app
CMD ["lua", "market.lua"]
