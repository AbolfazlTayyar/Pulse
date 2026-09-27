-- Binance adapter (ADR 0006). Verified only with fixtures: the live API is blocked from the dev
-- network. Binance sends prices as JSON strings already.
--
-- Quote currency (ADR 0024): Binance's global API has no USD pairs. With MARKET_QUOTE=USD we
-- fetch the USDT pairs and label every item "USDT", never "USD": USDT is not USD, and the item
-- says what was actually priced. Any other quote is used as-is (BTCEUR, BTCUSDC, ...).
--
-- volume_24h is quoteVolume (traded value in the quote currency), matching CoinGecko's
-- usd_24h_vol, not `volume` (base-asset units).
local json = require("src.vendor.dkjson")
local source = require("src.source")

local M = {}

M.name = "binance"
M.DEFAULT_URL = "https://api.binance.com"

-- Symbols we know Binance lists. An unlisted pair in a batch makes Binance reject the whole
-- request (400, code -1121), so anything else is UNKNOWN_SYMBOL without asking.
M.ASSETS = {
   BTC = true, ETH = true, SOL = true, BNB = true, XRP = true, ADA = true, DOGE = true, TRX = true,
   DOT = true, LTC = true, LINK = true, AVAX = true, XLM = true, ATOM = true, USDC = true,
}

function M.effective_quote(quote)
   if quote == "USD" then
      return "USDT"
   end
   return quote
end

local function unknown(symbol, why)
   return { symbol = symbol, code = "UNKNOWN_SYMBOL", detail = why }
end

local function url_encode(s)
   return (s:gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function fetch(base_url, symbols, quote, timeout_ms)
   local q = M.effective_quote(quote)
   local rows, errors, pairs_, by_pair = {}, {}, {}, {}
   for _, s in ipairs(symbols) do
      if M.ASSETS[s] and s ~= q then
         local pair = s .. q
         pairs_[#pairs_ + 1] = '"' .. pair .. '"'
         by_pair[pair] = s
      else
         errors[#errors + 1] = unknown(s, "not supported by binance")
      end
   end
   if #pairs_ == 0 then
      return rows, errors, { kind = "ok", http_ms = 0 }
   end

   local url = base_url .. "/api/v3/ticker/24hr?symbols=" .. url_encode("[" .. table.concat(pairs_, ",") .. "]")
   local res, failed, info = source.request(M.name, url, timeout_ms)
   if failed then
      return {}, errors, failed
   end

   local ok, data = pcall(json.decode, res.body)
   if not ok or type(data) ~= "table" or (data[1] == nil and next(data) ~= nil) then
      info.kind, info.detail = "bad_payload", "binance: undecodable or unexpected response body"
      return {}, errors, info
   end

   info.kind = "ok"
   local seen = {}
   for _, t in ipairs(data) do
      local s = type(t) == "table" and by_pair[t.symbol]
      if s and not seen[s] then
         seen[s] = true
         rows[#rows + 1] = {
            symbol = s,
            quote = q,
            price = t.lastPrice,
            volume_24h = t.quoteVolume,
            change_24h_pct = t.priceChangePercent,
         }
      end
   end
   for pair, s in pairs(by_pair) do
      if not seen[s] then
         errors[#errors + 1] = unknown(s, "not returned by binance (" .. pair .. ")")
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
      supports = function(symbol, quote) return M.ASSETS[symbol] ~= nil and symbol ~= M.effective_quote(quote) end,
   }
end

return M
