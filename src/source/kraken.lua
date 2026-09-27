-- Kraken adapter (ADR 0006). Verified only with fixtures: the live API is blocked from the dev
-- network. Kraken sends prices as JSON strings.
--
-- Fields used from /0/public/Ticker:
--   c[1]  last trade price                       -> price
--   v[2]  volume over the last 24 h, base asset  -> volume_24h (Kraken has no quote volume)
--   o     today's opening price (since 00:00 UTC) -> change_24h_pct = (last - o) / o * 100
-- The change is computed with decimal.lua and rounded half-even to 2 decimals (CHANGE_SCALE),
-- the precision exchanges usually quote a percentage change with. Note that Kraken's "o" is the
-- UTC-day open, not a rolling 24 h open, so this is "change since 00:00 UTC".
local json = require("src.vendor.dkjson")
local decimal = require("src.decimal")
local source = require("src.source")

local M = {}

M.name = "kraken"
M.DEFAULT_URL = "https://api.kraken.com"
M.CHANGE_SCALE = 2

-- Our symbol -> Kraken asset code. Unknown pairs make Kraken reject the whole batch
-- ("EQuery:Unknown asset pair"), so anything else is UNKNOWN_SYMBOL without asking.
M.ASSETS = {
   BTC = "XBT", ETH = "ETH", SOL = "SOL", XRP = "XRP", ADA = "ADA", DOGE = "XDG", LTC = "LTC",
   DOT = "DOT", LINK = "LINK", AVAX = "AVAX", XLM = "XLM", ATOM = "ATOM", USDT = "USDT", USDC = "USDC",
}

function M.effective_quote(quote)
   return quote
end

local function unknown(symbol, why)
   return { symbol = symbol, code = "UNKNOWN_SYMBOL", detail = why }
end

-- Kraken names result pairs inconsistently: legacy assets get X/Z prefixes (XXBTZUSD,
-- XETHZUSD), newer ones don't (SOLUSD). Try every spelling.
local function result_keys(asset, quote)
   return { "X" .. asset .. "Z" .. quote, asset .. quote, "X" .. asset .. quote, asset .. "Z" .. quote }
end

local function change_pct(last, open)
   if not (decimal.parse(last) and decimal.parse(open)) or decimal.is_zero(open) then
      return nil
   end
   local diff100 = decimal.mul(decimal.sub(last, open), "100")
   return tostring(decimal.div(diff100, open, M.CHANGE_SCALE))
end

local function error_kind(errs)
   local text = table.concat(errs, "; ")
   if text:find("Rate limit", 1, true) or text:find("Too many requests", 1, true) then
      return "rate_limited", text
   end
   if text:find("EService", 1, true) then
      return "server_error", text
   end
   return "bad_payload", text
end

local function fetch(base_url, symbols, quote, timeout_ms)
   local rows, errors, pairs_, wanted = {}, {}, {}, {}
   local quote_code = M.ASSETS[quote] or quote
   for _, s in ipairs(symbols) do
      local asset = M.ASSETS[s]
      if asset and s ~= quote then
         pairs_[#pairs_ + 1] = asset .. quote_code
         wanted[#wanted + 1] = s
      else
         errors[#errors + 1] = unknown(s, "not supported by kraken")
      end
   end
   if #pairs_ == 0 then
      return rows, errors, { kind = "ok", http_ms = 0 }
   end

   local url = base_url .. "/0/public/Ticker?pair=" .. table.concat(pairs_, ",")
   local res, failed, info = source.request(M.name, url, timeout_ms)
   if failed then
      return {}, errors, failed
   end

   local ok, data = pcall(json.decode, res.body)
   if not ok or type(data) ~= "table" or type(data.error) ~= "table" then
      info.kind, info.detail = "bad_payload", "kraken: undecodable or unexpected response body"
      return {}, errors, info
   end
   if #data.error > 0 then
      local kind, text = error_kind(data.error)
      info.kind, info.detail = kind, "kraken: " .. text
      return {}, errors, info
   end
   if type(data.result) ~= "table" then
      info.kind, info.detail = "bad_payload", "kraken: response has no result"
      return {}, errors, info
   end

   info.kind = "ok"
   for _, s in ipairs(wanted) do
      local t
      for _, k in ipairs(result_keys(M.ASSETS[s], quote_code)) do
         t = t or data.result[k]
      end
      if type(t) ~= "table" then
         errors[#errors + 1] = unknown(s, "not returned by kraken")
      else
         local last = type(t.c) == "table" and t.c[1] or nil
         local vol = type(t.v) == "table" and t.v[2] or nil
         rows[#rows + 1] = {
            symbol = s,
            quote = quote,
            price = last,
            volume_24h = vol,
            change_24h_pct = (type(last) == "string" and type(t.o) == "string") and change_pct(last, t.o) or nil,
         }
      end
   end
   return rows, errors, info
end

function M.new(base_url)
   base_url = (base_url or M.DEFAULT_URL):gsub("/+$", "")
   return {
      name = M.name,
      base_url = base_url,
      fetch = function(symbols, quote, timeout_ms) return fetch(base_url, symbols, quote, timeout_ms) end,
      effective_quote = M.effective_quote,
   }
end

return M
