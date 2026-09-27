-- convert --from A --to B --amount X: convert.v1 (ADR 0020, ADR 0015). Cache only: never calls
-- the vendor. All math is exact in decimal.lua; result and rate are each rounded once, half to
-- even, to CONVERT_SCALE decimals. result is not amount * rate (that would round twice).
local decimal = require("src.decimal")
local redis = require("src.redis_client")
local snapshot = require("src.snapshot")
local source_registry = require("src.source")
local output = require("src.output")
local log = require("src.log")

local M = {}

local ARRAY = { __jsontype = "array" }

local function ms(x) return math.floor(x + 0.5) end

-- Prices for the legs, from the daemon LRU (E8) or Redis. Returns legs_by_symbol, all_memory,
-- redis_ms; or nil, err on Redis failure.
local function load_legs(ctx, name, quote, symbols, now)
   local cfg = ctx.config
   local found, need = {}, {}
   for _, s in ipairs(symbols) do
      local item = ctx.cache and ctx.cache:get(name .. ":" .. s, now, cfg.snapshot_fresh_s)
      if item and item.quote == quote then found[s] = item else need[#need + 1] = s end
   end
   local redis_ms = 0
   if #need > 0 then
      local client, r0 = redis.from_context(ctx)
      if not client then
         return nil, r0
      end
      local res, err = snapshot.read(client, name, need, now, cfg.snapshot_fresh_s, quote)
      redis_ms = ms(client.redis_ms - r0)
      if not res then
         return nil, err
      end
      for _, s in ipairs(need) do
         if res[s] ~= snapshot.MISSING then
            found[s] = res[s]
            if ctx.cache and not res[s].stale then ctx.cache:put(name .. ":" .. s, res[s]) end
         end
      end
   end
   return found, #need == 0, redis_ms
end

function M.run(req, ctx)
   local cfg = ctx.config
   local scale = cfg.convert_scale
   local name = cfg.market_source
   local quote = assert(source_registry.get(name, cfg.source_url)).effective_quote(cfg.market_quote)
   local a, b, x = req.from, req.to, req.amount
   local now = os.time()

   -- Which prices are needed (ADR 0020 table): none when A == B, else every side that isn't the quote.
   local symbols = {}
   if a ~= b then
      if a ~= quote then symbols[#symbols + 1] = a end
      if b ~= quote then symbols[#symbols + 1] = b end
   end

   local legs_by, all_memory, redis_ms
   if #symbols > 0 then
      local err
      legs_by, err, redis_ms = load_legs(ctx, name, quote, symbols, now)
      if not legs_by then
         return redis.unavailable(err)
      end
      all_memory = err
   else
      -- A == B: no price needed. Still fail closed without Redis, like every command (ADR 0009).
      local client, err = redis.from_context(ctx)
      if not client then
         return redis.unavailable(err)
      end
      legs_by, all_memory, redis_ms = {}, false, ms(client.redis_ms - err)
   end

   for _, s in ipairs(symbols) do
      if not legs_by[s] then
         log.debug("cache_miss", { symbols = { s }, layer = "redis" })
         return output.error_body("PRICE_UNAVAILABLE", "no cached price for " .. s), 1
      end
   end

   local result, rate
   if a == b then
      result, rate = decimal.round(x, scale), decimal.round("1", scale)
   elseif b == quote then
      local pa = legs_by[a].price
      result = decimal.round(decimal.mul(x, pa), scale)
      rate = decimal.round(pa, scale)
   elseif a == quote then
      local pb = legs_by[b].price
      result = decimal.div(x, pb, scale)
      rate = decimal.div("1", pb, scale)
   else
      local pa, pb = legs_by[a].price, legs_by[b].price
      result = decimal.div(decimal.mul(x, pa), pb, scale)
      rate = decimal.div(pa, pb, scale)
   end
   if not result or not rate then
      -- Only a zero price could get here, and normalize never caches one.
      return output.error_body("PRICE_UNAVAILABLE", "cached price is zero"), 1
   end

   local legs, stale_syms = {}, {}
   for _, s in ipairs(symbols) do
      local item = legs_by[s]
      legs[#legs + 1] = { symbol = item.symbol, quote = item.quote, price = item.price,
         as_of_unix = item.as_of_unix, stale = item.stale }
      if item.stale then stale_syms[#stale_syms + 1] = s end
   end
   local as_of, cache = snapshot.summarize(legs)
   if #symbols > 0 and all_memory then cache = "memory" end
   if #stale_syms > 0 then log.warn("stale_served", { symbols = stale_syms }) end
   if #legs > 0 then log.debug("cache_hit", { symbols = symbols, layer = all_memory and "memory" or "redis" }) end

   return {
      ok = true,
      schema = "convert.v1",
      as_of_unix = as_of or now,
      source = name,
      from = a,
      to = b,
      amount = x,
      result = tostring(result),
      rate = tostring(rate),
      stale = #stale_syms > 0,
      legs = setmetatable(legs, ARRAY),
      meta = { cache = cache or "hit", redis_ms = redis_ms, http_ms = 0 },
   }, 0
end

return M
