-- fetch SYMS: fresh prices, with one vendor call shared by every concurrent process
-- (CLAUDE.md "fetch flow", ADR 0008, 0010, 0011, 0012, 0018, 0021).
--
--   1. Fresh snapshots for every symbol           -> cache "hit", no lock, no vendor.
--   2. Take mkt:lock:{source}:
--      leader   -> cooldown? -> rate limit -> count call -> HTTP (<= 1 retry) -> validate ->
--                  write snapshots -> release lock -> cache "miss"
--      follower -> poll snapshots every 100 ms -> fresh: cache "coalesced"
--   3. Vendor failure, rate limit, cooldown or deadline -> ok: false, exit 1, with last-good
--      items attached and marked stale (ADR 0011).
local redis = require("src.redis_client")
local lock = require("src.lock")
local limiter = require("src.limiter")
local snapshot = require("src.snapshot")
local normalize = require("src.normalize")
local source = require("src.source")
local log = require("src.log")

local M = {}

M.POLL_MS = 100     -- follower poll interval (ADR 0017)
M.RESERVE_MS = 100  -- kept back from the deadline to build and print the answer

local CODE_FOR_KIND = {
   timeout = "SOURCE_UNAVAILABLE",
   connect = "SOURCE_UNAVAILABLE",
   server_error = "SOURCE_UNAVAILABLE",
   http_error = "SOURCE_UNAVAILABLE",
   rate_limited = "RATE_LIMITED",
   bad_payload = "BAD_PAYLOAD",
}

local function ms(x) return math.floor(x + 0.5) end

-- One invocation's state: the request, its budget and everything measured on the way.
local Run = {}
Run.__index = Run

function Run:redis_ms()
   return ms(self.client.redis_ms - self.r0)
end

-- Reads snapshots for the known symbols into self.snaps. Returns true, or nil, err.
function Run:read()
   local now = os.time()
   local need = {}
   for _, s in ipairs(self.known) do
      local item = self.ctx.cache and self.ctx.cache:get(self.name .. ":" .. s, now, self.cfg.snapshot_fresh_s)
      if item then
         self.snaps[s] = item
         self.from_memory[s] = true
      else
         need[#need + 1] = s
         self.from_memory[s] = nil
      end
   end
   if #need == 0 then
      return true
   end
   local res, err = snapshot.read(self.client, self.name, need, now, self.cfg.snapshot_fresh_s)
   if not res then
      return nil, err
   end
   for _, s in ipairs(need) do
      local item = res[s]
      self.snaps[s] = item ~= snapshot.MISSING and item or nil
      if self.snaps[s] and not item.stale and self.ctx.cache then
         self.ctx.cache:put(self.name .. ":" .. s, item)
      end
   end
   return true
end

function Run:all_fresh()
   for _, s in ipairs(self.known) do
      local item = self.snaps[s]
      if not item or item.stale then
         return false
      end
   end
   return true
end

-- Items in request order from self.snaps (fresh or last-good).
function Run:snapshot_items()
   local items = {}
   for _, s in ipairs(self.known) do
      if self.snaps[s] then items[#items + 1] = self.snaps[s] end
   end
   return items
end

function Run:body(t)
   t.source = self.name
   t.redis_ms = self:redis_ms()
   t.http_ms = self.http_ms
   local errors = {}
   for _, e in ipairs(self.unknown) do errors[#errors + 1] = e end
   for _, e in ipairs(t.errors or {}) do errors[#errors + 1] = e end
   t.errors = errors
   return snapshot.ticker_body(t)
end

-- Success from snapshots: "hit", "coalesced" or "memory".
function Run:served(cache)
   local items = self:snapshot_items()
   local all_memory = true
   for _, s in ipairs(self.known) do
      if not self.from_memory[s] then all_memory = false end
   end
   if all_memory then cache = "memory" end
   log.debug("cache_hit", { symbols = self.known, layer = all_memory and "memory" or "redis" })
   return self:body({ ok = true, items = items, cache = cache }), 0
end

-- ADR 0011: ok false, exit 1, full ticker.v1 body with the last-good items marked stale, and
-- symbols without any data in errors[].
function Run:failed(code, detail)
   local items, errors, stale = {}, {}, {}
   for _, s in ipairs(self.known) do
      local item = self.snaps[s]
      if item then
         items[#items + 1] = item
         if item.stale then stale[#stale + 1] = s end
      else
         errors[#errors + 1] = { symbol = s, code = code, detail = "no cached data for " .. s }
      end
   end
   if #stale > 0 then log.warn("stale_served", { symbols = stale }) end
   return self:body({ ok = false, code = code, detail = detail, items = items, errors = errors }), 1
end

function Run:deadline_exceeded(stage)
   log.error("deadline_exceeded", { stage = stage })
   return self:failed("DEADLINE_EXCEEDED", self.name .. ": no fresh data before the deadline (" .. stage .. ")")
end

function Run:release(token)
   -- A Redis error here just leaves the lock to expire (LOCK_TTL_MS); the answer stands.
   lock.release(self.client, self.name, token)
end

-- The leader's vendor call with at most one retry (ADR 0021): connect errors and 5xx only, and
-- only if both the deadline and the lock TTL still exceed SOURCE_TIMEOUT_MS. Returns rows,
-- errors, info; or nil, err on Redis failure.
function Run:call_vendor()
   local cfg, d = self.cfg, self.deadline
   local rows, errors, info
   for attempt = 1, 2 do
      -- Room for the HTTP call and the Redis writes after it, inside the deadline.
      local budget = math.min(cfg.source_timeout_ms, d:remaining_ms() - M.RESERVE_MS - 2 * cfg.redis_timeout_ms)
      if budget <= 0 then
         return {}, {}, { kind = "deadline", http_ms = 0 }
      end
      local n, err = snapshot.incr_vendor_calls(self.client, self.name) -- counts attempts
      if not n then
         return nil, err
      end
      rows, errors, info = self.adapter.fetch(self.known, self.quote, budget)
      self.http_ms = self.http_ms + (info.http_ms or 0)
      if attempt == 2 or not source.RETRYABLE[info.kind] or not d:allows(cfg.source_timeout_ms) then
         break
      end
      local ttl = lock.remaining_ttl_ms(self.client, self.name)
      if not ttl or ttl <= cfg.source_timeout_ms then
         break
      end
      log.warn("vendor_retry", { source = self.name, kind = info.kind })
   end
   return rows, errors, info
end

-- We hold the lock: refresh every known symbol with one vendor call.
function Run:lead(token)
   local cfg = self.cfg
   log.debug("cache_miss", { symbols = self.known, layer = "redis" })

   local cooling, err = limiter.cooldown_active(self.client, self.name)
   if cooling == nil then
      return redis.unavailable(err)
   end
   if cooling then
      self:release(token)
      return self:failed("RATE_LIMITED", self.name .. ": cooling down after a 429")
   end
   local allowed, count = limiter.take(self.client, self.name, cfg.rate_limit_window_s, cfg.rate_limit_per_window)
   if allowed == nil then
      return redis.unavailable(count)
   end
   if not allowed then
      self:release(token)
      return self:failed("RATE_LIMITED", self.name .. ": shared rate limit reached (" .. cfg.rate_limit_per_window
         .. " calls / " .. cfg.rate_limit_window_s .. " s)")
   end

   local rows, adapter_errors, info = self:call_vendor()
   if rows == nil then
      return redis.unavailable(adapter_errors)
   end
   if info.kind == "deadline" then
      self:release(token)
      return self:deadline_exceeded("leader")
   end
   if info.kind ~= "ok" then
      self:release(token)
      if info.kind == "rate_limited" then
         limiter.set_cooldown(self.client, self.name, info.retry_after)
      end
      return self:failed(CODE_FOR_KIND[info.kind] or "SOURCE_UNAVAILABLE", info.detail or (self.name .. ": " .. info.kind))
   end

   local as_of = os.time()
   local items, bad = normalize.build_items(rows, as_of)
   local ok, werr = snapshot.write(self.client, self.name, items, cfg.snapshot_keep_s)
   if not ok then
      return redis.unavailable(werr)
   end
   snapshot.set_last_fetch(self.client, self.name, as_of)
   self:release(token)
   if self.ctx.cache then
      for _, item in ipairs(items) do self.ctx.cache:put(self.name .. ":" .. item.symbol, item) end
   end

   local by_symbol = {}
   for _, item in ipairs(items) do by_symbol[item.symbol] = item end
   local ordered = {}
   for _, s in ipairs(self.known) do
      if by_symbol[s] then ordered[#ordered + 1] = by_symbol[s] end
   end
   local errors = {}
   for _, e in ipairs(adapter_errors) do errors[#errors + 1] = e end
   for _, e in ipairs(bad) do errors[#errors + 1] = e end
   for _, e in ipairs(errors) do log.warn("symbol_error", { symbol = e.symbol, code = e.code }) end

   -- ADR 0010: unknown symbols and bad rows are partial success; exit 1 only with no items.
   local body = self:body({ ok = #ordered > 0, items = ordered, errors = errors, cache = "miss" })
   if #ordered == 0 then
      body.code = body.errors[1] and body.errors[1].code or "BAD_PAYLOAD"
      body.detail = self.name .. ": no usable data for any requested symbol"
      return body, 1
   end
   return body, 0
end

function M.run(req, ctx)
   local cfg, d = ctx.config, ctx.deadline
   local adapter = assert(source.get(cfg.market_source, cfg.source_url))
   local client, r0 = redis.from_context(ctx)
   if not client then
      return redis.unavailable(r0)
   end
   local self = setmetatable({
      ctx = ctx, cfg = cfg, deadline = d, client = client, r0 = r0, adapter = adapter,
      name = adapter.name, quote = adapter.effective_quote(cfg.market_quote),
      known = {}, unknown = {}, snaps = {}, from_memory = {}, http_ms = 0,
   }, Run)

   -- Symbols the adapter can't map are answered without Redis or the vendor; they would never
   -- be cached, so letting them through would make every such request a vendor call.
   for _, s in ipairs(req.symbols) do
      if adapter.supports(s, cfg.market_quote) then
         self.known[#self.known + 1] = s
      else
         self.unknown[#self.unknown + 1] = { symbol = s, code = "UNKNOWN_SYMBOL", detail = "not supported by " .. self.name }
         log.warn("symbol_error", { symbol = s, code = "UNKNOWN_SYMBOL" })
      end
   end
   if #self.known == 0 then
      local body = self:body({ ok = false, items = {} })
      body.code, body.detail = "UNKNOWN_SYMBOL", "no requested symbol is supported by " .. self.name
      return body, 1
   end

   local ok, err = self:read()
   if not ok then
      return redis.unavailable(err)
   end
   if self:all_fresh() then
      return self:served("hit")
   end

   -- Leader or follower. A follower that sees the lock disappear while its data is still not
   -- fresh (the leader failed, or fetched other symbols) tries to become leader itself: waiting
   -- for a lock nobody holds would only burn the deadline. This stays bounded: the loop ends at
   -- the deadline, only one process can hold the lock, and the rate limit and cooldown still cap
   -- the vendor calls a chain of leaders can make.
   local waited_since = d:elapsed_ms()
   local was_follower = false
   while d:remaining_ms() > M.RESERVE_MS do
      local token, lerr = lock.acquire(client, self.name, cfg.lock_ttl_ms)
      if token == nil then
         return redis.unavailable(lerr)
      end
      if token then
         -- Someone may have written between our last read and getting the lock.
         if was_follower then
            ok, err = self:read()
            if not ok then return redis.unavailable(err) end
            if self:all_fresh() then
               self:release(token)
               log.info("lock_busy", { source = self.name, wait_ms = d:elapsed_ms() - waited_since })
               return self:served("coalesced")
            end
         end
         return self:lead(token)
      end

      was_follower = true
      repeat
         d:sleep(math.min(M.POLL_MS, d:remaining_ms() - M.RESERVE_MS))
         ok, err = self:read()
         if not ok then return redis.unavailable(err) end
         if self:all_fresh() then
            log.info("lock_busy", { source = self.name, wait_ms = d:elapsed_ms() - waited_since })
            return self:served("coalesced")
         end
         local ttl = lock.remaining_ttl_ms(client, self.name)
         if ttl == nil then return redis.unavailable("lock ttl") end
      until ttl == 0 or d:remaining_ms() <= M.RESERVE_MS
   end
   log.info("lock_busy", { source = self.name, wait_ms = d:elapsed_ms() - waited_since })
   return self:deadline_exceeded("follower")
end

return M
