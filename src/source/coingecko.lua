-- CoinGecko adapter (ADR 0006): one /simple/price call for every symbol. Prices arrive as JSON
-- numbers and stay as their original text via the patched dkjson (ADR 0007).
local json = require("src.vendor.dkjson")
local source = require("src.source")

local M = {}

M.name = "coingecko"
M.DEFAULT_URL = "https://api.coingecko.com/api/v3"

-- Our symbol -> CoinGecko coin id.
M.IDS = {
   BTC = "bitcoin", ETH = "ethereum", SOL = "solana", USDT = "tether", USDC = "usd-coin",
   BNB = "binancecoin", XRP = "ripple", ADA = "cardano", DOGE = "dogecoin", TRX = "tron",
   DOT = "polkadot", LTC = "litecoin", LINK = "chainlink", AVAX = "avalanche-2",
   MATIC = "matic-network", DAI = "dai", XLM = "stellar", ATOM = "cosmos",
}

local function unknown(symbol, why)
   return { symbol = symbol, code = "UNKNOWN_SYMBOL", detail = why }
end

-- rows (canonical, unvalidated), errors (per symbol), info ({kind, status, http_ms, ...}).
local function fetch(base_url, symbols, quote, timeout_ms)
   local rows, errors, ids, wanted = {}, {}, {}, {}
   for _, s in ipairs(symbols) do
      local id = M.IDS[s]
      if id then
         ids[#ids + 1] = id
         wanted[#wanted + 1] = s
      else
         errors[#errors + 1] = unknown(s, "not supported by coingecko")
      end
   end
   if #ids == 0 then
      return rows, errors, { kind = "ok", http_ms = 0 } -- nothing to ask the vendor
   end

   local q = quote:lower()
   local url = base_url .. "/simple/price?ids=" .. table.concat(ids, ",") .. "&vs_currencies=" .. q
      .. "&include_24hr_vol=true&include_24hr_change=true"
   local res, failed, info = source.request(M.name, url, timeout_ms)
   if failed then
      return {}, errors, failed
   end

   local ok, data = pcall(json.decode, res.body)
   if not ok or type(data) ~= "table" or data[1] ~= nil or data.status ~= nil or data.error ~= nil then
      info.kind, info.detail = "bad_payload", "coingecko: undecodable or unexpected response body"
      return {}, errors, info
   end

   info.kind = "ok"
   for _, s in ipairs(wanted) do
      local entry = data[M.IDS[s]]
      if type(entry) ~= "table" then
         errors[#errors + 1] = unknown(s, "not returned by coingecko")
      else
         -- Missing or null fields stay nil; normalize.lua turns them into BAD_PAYLOAD.
         rows[#rows + 1] = {
            symbol = s,
            quote = quote,
            price = entry[q],
            volume_24h = entry[q .. "_24h_vol"],
            change_24h_pct = entry[q .. "_24h_change"],
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
      effective_quote = function(quote) return quote end,
   }
end

return M
