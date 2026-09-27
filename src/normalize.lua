-- Validates canonical vendor rows and builds ticker.v1 items (ADR 0021 "Vendor payload
-- validation", ADR 0010, ADR 0003). Structural checks only, no sanity band against previous
-- prices. Nothing that fails here is ever cached.
local decimal = require("src.decimal")
local log = require("src.log")

local M = {}

local REQUIRED = { "symbol", "quote", "price", "volume_24h", "change_24h_pct" }
local DECIMALS = { "price", "volume_24h", "change_24h_pct" }

-- row -> ticker.v1 item, or nil, detail. Numbers keep the vendor's original text.
function M.validate_row(row, as_of_unix)
   if math.type(as_of_unix) ~= "integer" then
      error("as_of_unix must be an integer")
   end
   if type(row) ~= "table" then
      return nil, "row is not an object"
   end
   for _, f in ipairs(REQUIRED) do
      if row[f] == nil then
         return nil, "missing field " .. f
      end
      if type(row[f]) ~= "string" then
         return nil, f .. " is not a string"
      end
   end
   if not row.symbol:match("^[A-Z0-9]+$") or #row.symbol > 15 then
      return nil, "symbol is invalid"
   end
   if not row.quote:match("^[A-Z]+$") or #row.quote > 10 then
      return nil, "quote is invalid"
   end
   for _, f in ipairs(DECIMALS) do
      if not decimal.parse(row[f]) then
         return nil, f .. " is not a decimal"
      end
   end
   if not decimal.is_positive(row.price) then
      return nil, "price must be > 0"
   end
   return {
      symbol = row.symbol,
      quote = row.quote,
      price = row.price,
      volume_24h = row.volume_24h,
      change_24h_pct = row.change_24h_pct,
      as_of_unix = as_of_unix,
      stale = false,
   }
end

-- The row's symbol for errors[], if it has a valid one. Protected: a poison row may throw on
-- any field access.
local function row_symbol(row)
   local ok, s = pcall(function() return type(row) == "table" and row.symbol end)
   if ok and type(s) == "string" and #s <= 15 and s:match("^[A-Z0-9]+$") then
      return s
   end
   return nil
end

-- rows -> items[], errors[]. Each row is checked in its own pcall, so a poison row costs one
-- symbol, never the batch.
function M.build_items(rows, as_of_unix)
   local items, errors = {}, {}
   for _, row in ipairs(rows) do
      local ok, item, detail = pcall(M.validate_row, row, as_of_unix)
      if not ok then
         item, detail = nil, "row could not be validated: " .. tostring(item)
      end
      if item then
         items[#items + 1] = item
      else
         local symbol = row_symbol(row)
         errors[#errors + 1] = { symbol = symbol, code = "BAD_PAYLOAD", detail = detail }
         log.warn("symbol_error", { symbol = symbol, code = "BAD_PAYLOAD", detail = detail })
      end
   end
   return items, errors
end

return M
