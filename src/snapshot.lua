-- Last-good ticker per symbol in Redis, plus fetch metadata (ADR 0008, ADR 0003, CLAUDE.md
-- "Redis keys"). Freshness is decided at read time from as_of_unix, never stored.
local json = require("src.vendor.dkjson")
local decimal = require("src.decimal")
local redis = require("src.redis_client")
local log = require("src.log")

local M = {}

M.MISSING = "missing"

local DECIMAL_FIELDS = { "price", "volume_24h", "change_24h_pct" }

function M.key(source, symbol)
   return "mkt:snapshot:" .. source .. ":" .. symbol
end

local function last_fetch_key(source)
   return "mkt:meta:last_fetch:" .. source
end

local function vendor_calls_key(source)
   return "mkt:stats:vendor_calls:" .. source
end

-- nil when the item has every ticker.v1 field with the right type, else a reason.
local function check_item(item)
   if type(item) ~= "table" then
      return "item is not a table"
   end
   if type(item.symbol) ~= "string" or not item.symbol:match("^[A-Z0-9]+$") then
      return "bad symbol"
   end
   if type(item.quote) ~= "string" or item.quote == "" then
      return "bad quote"
   end
   for _, f in ipairs(DECIMAL_FIELDS) do
      if type(item[f]) ~= "string" or not decimal.parse(item[f]) then
         return f .. " is not a decimal string"
      end
   end
   if math.type(item.as_of_unix) ~= "integer" then
      return "as_of_unix is not an integer"
   end
   return nil
end

-- Writes one SET ... EX keep_s per item. Items must already be validated (normalize.lua); a
-- malformed item is a bug, so nothing is written and nil, err is returned.
-- Returns true, or nil, err.
function M.write(client, source, items, keep_s)
   for _, item in ipairs(items) do
      local why = check_item(item)
      if why then
         return nil, "refusing to cache invalid item: " .. why
      end
   end
   for _, item in ipairs(items) do
      local value = json.encode({
         symbol = item.symbol,
         quote = item.quote,
         price = item.price,
         volume_24h = item.volume_24h,
         change_24h_pct = item.change_24h_pct,
         as_of_unix = item.as_of_unix,
      })
      local ok, err = client:call_idempotent("SET", M.key(source, item.symbol), value, "EX", keep_s)
      if ok == nil then
         return nil, err
      end
   end
   return true
end

-- Stored JSON -> item, or nil, reason. as_of_unix comes back as text from the patched decoder.
local function decode_item(raw, symbol)
   local ok, t = pcall(json.decode, raw)
   if not ok or type(t) ~= "table" then
      return nil, "not JSON"
   end
   if type(t.as_of_unix) == "string" and t.as_of_unix:match("^%d+$") and #t.as_of_unix <= 12 then
      t.as_of_unix = math.tointeger(tonumber(t.as_of_unix))
   end
   local why = check_item(t)
   if why then
      return nil, why
   end
   if t.symbol ~= symbol then
      return nil, "symbol mismatch"
   end
   return {
      symbol = t.symbol,
      quote = t.quote,
      price = t.price,
      volume_24h = t.volume_24h,
      change_24h_pct = t.change_24h_pct,
      as_of_unix = t.as_of_unix,
   }
end

-- One MGET. Returns { [symbol] = item | M.MISSING }, or nil, err on Redis failure.
-- item.stale = (now - as_of_unix >= fresh_s). A corrupt stored value counts as missing.
function M.read(client, source, symbols, now, fresh_s)
   local result = {}
   if #symbols == 0 then
      return result
   end
   local keys = {}
   for i, s in ipairs(symbols) do keys[i] = M.key(source, s) end
   local values, err = client:call_idempotent("MGET", table.unpack(keys))
   if values == nil then
      return nil, err
   end
   if type(values) ~= "table" then
      return nil, "unexpected reply to MGET"
   end
   for i, symbol in ipairs(symbols) do
      local raw = values[i]
      if type(raw) ~= "string" then
         result[symbol] = M.MISSING
      else
         local item, why = decode_item(raw, symbol)
         if item then
            item.stale = (now - item.as_of_unix) >= fresh_s
            result[symbol] = item
         else
            log.warn("symbol_error", { symbol = symbol, code = "BAD_PAYLOAD", detail = "corrupt snapshot: " .. why })
            result[symbol] = M.MISSING
         end
      end
   end
   return result
end

-- Top-level as_of_unix (the oldest item's) and meta.cache (hit / stale / mixed) for a set of
-- items read from snapshots. Both are nil for an empty list.
function M.summarize(items)
   local oldest, fresh, stale = nil, 0, 0
   for _, item in ipairs(items) do
      if oldest == nil or item.as_of_unix < oldest then
         oldest = item.as_of_unix
      end
      if item.stale then stale = stale + 1 else fresh = fresh + 1 end
   end
   if oldest == nil then
      return nil, nil
   end
   local cache = (stale == 0 and "hit") or (fresh == 0 and "stale") or "mixed"
   return oldest, cache
end

-- Unix time of the last successful vendor fetch (for health). Returns true or nil, err.
function M.set_last_fetch(client, source, now)
   local ok, err = client:call_idempotent("SET", last_fetch_key(source), now)
   if ok == nil then
      return nil, err
   end
   return true
end

-- Integer unix time, false when never fetched, or nil, err.
function M.get_last_fetch(client, source)
   local v, err = client:call_idempotent("GET", last_fetch_key(source))
   if v == nil then
      return nil, err
   end
   if v == redis.null or not v:match("^%d+$") then
      return false
   end
   return math.tointeger(tonumber(v))
end

-- Counts one real vendor HTTP attempt (no TTL). INCR is never retried (ADR 0021).
function M.incr_vendor_calls(client, source)
   return client:call("INCR", vendor_calls_key(source))
end

-- Integer count (0 when never incremented), or nil, err.
function M.get_vendor_calls(client, source)
   local v, err = client:call_idempotent("GET", vendor_calls_key(source))
   if v == nil then
      return nil, err
   end
   if v == redis.null or not v:match("^%d+$") then
      return 0
   end
   return math.tointeger(tonumber(v))
end

return M
