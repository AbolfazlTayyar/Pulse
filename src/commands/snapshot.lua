-- snapshot --symbols A,B: cached prices only (ADR 0022). Never calls the vendor, never takes the
-- lock, never touches the rate limit. Stale data is still ok: true, marked stale per item.
local redis = require("src.redis_client")
local snapshot = require("src.snapshot")
local source_registry = require("src.source")
local log = require("src.log")

local M = {}

local function ms(x) return math.floor(x + 0.5) end

function M.run(req, ctx)
   local cfg = ctx.config
   local source = cfg.market_source
   local quote = assert(source_registry.get(source, cfg.source_url)).effective_quote(cfg.market_quote)
   local now = os.time()
   local found, missing = {}, {}

   -- Daemon only (E8): fresh entries from the in-process LRU. In one-shot mode ctx.cache is nil.
   if ctx.cache then
      for _, s in ipairs(req.symbols) do
         found[s] = ctx.cache:get(source .. ":" .. s, now, cfg.snapshot_fresh_s)
      end
   end
   local need = {}
   for _, s in ipairs(req.symbols) do
      if not found[s] then need[#need + 1] = s end
   end
   local from_memory = #need == 0

   local redis_ms = 0
   if #need > 0 then
      local client, r0 = redis.from_context(ctx)
      if not client then
         return redis.unavailable(r0)
      end
      local res, err = snapshot.read(client, source, need, now, cfg.snapshot_fresh_s, quote)
      redis_ms = ms(client.redis_ms - r0)
      if not res then
         return redis.unavailable(err)
      end
      for _, s in ipairs(need) do
         if res[s] ~= snapshot.MISSING then
            found[s] = res[s]
            if ctx.cache then ctx.cache:put(source .. ":" .. s, res[s]) end
         end
      end
   end

   local items, errors, stale = {}, {}, {}
   for _, s in ipairs(req.symbols) do
      local item = found[s]
      if item then
         items[#items + 1] = item
         if item.stale then stale[#stale + 1] = s end
      else
         missing[#missing + 1] = s
         errors[#errors + 1] = { symbol = s, code = "PRICE_UNAVAILABLE", detail = "no cached price for " .. s }
      end
   end
   if #items > 0 then log.debug("cache_hit", { symbols = req.symbols, layer = from_memory and "memory" or "redis" }) end
   if #missing > 0 then log.debug("cache_miss", { symbols = missing, layer = "redis" }) end
   if #stale > 0 then log.warn("stale_served", { symbols = stale }) end

   local body = snapshot.ticker_body({
      ok = #items > 0,
      source = source,
      items = items,
      errors = errors,
      cache = from_memory and "memory" or nil,
      redis_ms = redis_ms,
      http_ms = 0,
   })
   if #items == 0 then
      body.code = "PRICE_UNAVAILABLE"
      body.detail = "no cached price for " .. table.concat(missing, ", ")
      return body, 1
   end
   return body, 0
end

return M
