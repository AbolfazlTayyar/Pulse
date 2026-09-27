-- argv parsing and validation (CLAUDE.md "CLI contract", ADR 0002, ADR 0021 "Fatal — caller").
-- Whitelists only; returns a request table or nil, "BAD_ARGS", detail. Never raises.
local M = {}

M.MAX_SYMBOLS = 50
local MAX_INT_DIGITS = 30
local MAX_FRAC_DIGITS = 18

local USAGE = "usage: fetch SYMS | snapshot --symbols SYMS | convert --from X --to Y --amount N"
   .. " | health | daemon"

-- Shell metacharacters and quotes; whitespace and control characters are checked separately.
local FORBIDDEN = ";|&$`()<>\\'\""

local function bad(detail)
   return nil, "BAD_ARGS", detail
end

-- Returns a description of the first forbidden character in s, or nil.
local function forbidden_char(s)
   for i = 1, #s do
      local c = s:sub(i, i)
      if FORBIDDEN:find(c, 1, true) then
         return "forbidden character '" .. c .. "'"
      end
   end
   if s:find("[%s%c]") then
      return "whitespace or control character"
   end
   return nil
end

-- Echo user input in details only in a bounded form.
local function shown(s)
   if #s > 20 then
      s = s:sub(1, 20) .. "..."
   end
   return "'" .. s .. "'"
end

function M.validate_symbol(s)
   if type(s) ~= "string" or s == "" then
      return bad("empty symbol")
   end
   local c = forbidden_char(s)
   if c then
      return bad("symbol contains " .. c)
   end
   if not s:match("^[A-Z0-9]+$") or #s > 15 then
      return bad("symbol " .. shown(s) .. " must match ^[A-Z0-9]{1,15}$")
   end
   return s
end

-- A list of symbols (from argv or a daemon request): validated, duplicates removed in order.
function M.validate_symbol_list(list)
   if type(list) ~= "table" or #list == 0 then
      return bad("at least one symbol is required")
   end
   local out, seen = {}, {}
   for _, s in ipairs(list) do
      local ok, code, detail = M.validate_symbol(s)
      if not ok then
         return nil, code, detail
      end
      if not seen[s] then
         seen[s] = true
         out[#out + 1] = s
      end
   end
   if #out > M.MAX_SYMBOLS then
      return bad("at most " .. M.MAX_SYMBOLS .. " symbols per request")
   end
   return out
end

-- "BTC,ETH,BTC" -> {"BTC", "ETH"}
function M.parse_symbols(s)
   if type(s) ~= "string" or s == "" then
      return bad("at least one symbol is required")
   end
   local c = forbidden_char(s)
   if c then
      return bad("symbol contains " .. c)
   end
   local list = {}
   for part in (s .. ","):gmatch("([^,]*),") do
      list[#list + 1] = part
   end
   return M.validate_symbol_list(list)
end

-- Positive decimal string, <= 30 integer digits and <= 18 decimals; no sign, exponent or space.
function M.validate_amount(s)
   if type(s) ~= "string" or s == "" then
      return bad("amount is required")
   end
   local c = forbidden_char(s)
   if c then
      return bad("amount contains " .. c)
   end
   local int, frac = s:match("^(%d+)%.(%d+)$")
   if not int then
      int, frac = s:match("^(%d+)$"), ""
   end
   if not int then
      return bad("amount must be a positive decimal")
   end
   if not (int .. frac):find("[1-9]") then
      return bad("amount must be a positive decimal")
   end
   if #(int:gsub("^0+", "")) > MAX_INT_DIGITS then
      return bad("amount has more than " .. MAX_INT_DIGITS .. " integer digits")
   end
   if #frac > MAX_FRAC_DIGITS then
      return bad("amount has more than " .. MAX_FRAC_DIGITS .. " decimals")
   end
   return s
end

-- Parses "--flag value" pairs from argv[first..]. Each allowed flag must appear exactly once.
local function parse_flags(argv, first, allowed)
   local flags = {}
   local i = first
   while i <= #argv do
      local name = argv[i]
      if not allowed[name] then
         if name:sub(1, 2) == "--" then
            return bad("unknown flag " .. shown(name))
         end
         return bad("unexpected argument " .. shown(name))
      end
      if flags[name] then
         return bad("duplicate flag " .. name)
      end
      local value = argv[i + 1]
      if value == nil or value:sub(1, 2) == "--" then
         return bad("missing value for " .. name)
      end
      flags[name] = value
      i = i + 2
   end
   for name in pairs(allowed) do
      if not flags[name] then
         return bad("missing flag " .. name)
      end
   end
   return flags
end

local function no_extra(argv, n, command)
   if #argv > n then
      return bad(command .. " takes no further arguments, got " .. shown(argv[n + 1]))
   end
   return true
end

local parsers = {}

function parsers.fetch(argv)
   if argv[2] == nil then
      return bad("fetch needs a comma-separated symbol list, e.g. fetch BTC,ETH")
   end
   local ok, code, detail = no_extra(argv, 2, "fetch")
   if not ok then return nil, code, detail end
   local symbols
   symbols, code, detail = M.parse_symbols(argv[2])
   if not symbols then return nil, code, detail end
   return { command = "fetch", symbols = symbols }
end

function parsers.snapshot(argv)
   local flags, code, detail = parse_flags(argv, 2, { ["--symbols"] = true })
   if not flags then return nil, code, detail end
   local symbols
   symbols, code, detail = M.parse_symbols(flags["--symbols"])
   if not symbols then return nil, code, detail end
   return { command = "snapshot", symbols = symbols }
end

function parsers.convert(argv)
   local flags, code, detail = parse_flags(argv, 2, { ["--from"] = true, ["--to"] = true, ["--amount"] = true })
   if not flags then return nil, code, detail end
   local from, to, amount
   from, code, detail = M.validate_symbol(flags["--from"])
   if not from then return nil, code, detail end
   to, code, detail = M.validate_symbol(flags["--to"])
   if not to then return nil, code, detail end
   amount, code, detail = M.validate_amount(flags["--amount"])
   if not amount then return nil, code, detail end
   return { command = "convert", from = from, to = to, amount = amount }
end

function parsers.health(argv)
   local ok, code, detail = no_extra(argv, 1, "health")
   if not ok then return nil, code, detail end
   return { command = "health" }
end

function parsers.daemon(argv)
   local ok, code, detail = no_extra(argv, 1, "daemon")
   if not ok then return nil, code, detail end
   return { command = "daemon" }
end

-- Role of argv[i], so a forbidden character is reported as a "symbol" or "amount" problem.
local function role(argv, i)
   local prev = argv[i - 1]
   if prev == "--amount" then return "amount" end
   if prev == "--symbols" or prev == "--from" or prev == "--to" then return "symbol" end
   if i == 2 and argv[1] == "fetch" then return "symbol" end
   return "argument"
end

function M.parse(argv)
   local ok, req, code, detail = pcall(function()
      if type(argv) ~= "table" or argv[1] == nil then
         return bad("missing command; " .. USAGE)
      end
      for i = 1, #argv do
         if type(argv[i]) ~= "string" then
            return bad("arguments must be strings")
         end
         local c = forbidden_char(argv[i])
         if c then
            return bad(role(argv, i) .. " contains " .. c)
         end
      end
      local parser = parsers[argv[1]]
      if not parser then
         return bad("unknown command " .. shown(argv[1]) .. "; " .. USAGE)
      end
      return parser(argv)
   end)
   if not ok then
      return bad("cannot parse arguments")
   end
   return req, code, detail
end

return M
