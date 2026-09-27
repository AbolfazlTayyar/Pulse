-- Arbitrary-precision decimals for money (ADR 0007, ADR 0020). A value is a sign, an unbounded
-- integer magnitude stored as base-10^7 limbs (least significant first), and a scale: the
-- value is magnitude * 10^-scale. Limb products stay below 10^14, far from 2^63, so plain
-- Lua 5.4 integers are exact. Nothing here ever goes through a float or tonumber().
local M = {}

local BASE = 10000000 -- 10^7
local BASE_DIGITS = 7
local MAX_EXPONENT = 1000 -- bounds work for hostile vendor text like "1e999999999"

local POW10 = { [0] = 1 }
for i = 1, BASE_DIGITS do POW10[i] = POW10[i - 1] * 10 end

local Decimal = {}
Decimal.__index = Decimal

---------------------------------------------------------------------------------------------
-- Magnitudes: arrays of limbs, least significant first, no high zero limbs ({} is zero).

local function trim(a)
   local n = #a
   while n > 0 and a[n] == 0 do
      a[n] = nil
      n = n - 1
   end
   return a
end

local function digits_to_int(s, i, j)
   local n = 0
   for k = i, j do
      n = n * 10 + (s:byte(k) - 48)
   end
   return n
end

-- "001234567890" -> limbs
local function mag_from_digits(s)
   local a = {}
   local j = #s
   while j >= 1 do
      local i = math.max(1, j - BASE_DIGITS + 1)
      a[#a + 1] = digits_to_int(s, i, j)
      j = i - 1
   end
   return trim(a)
end

local function mag_to_digits(a)
   if #a == 0 then
      return "0"
   end
   local parts = { string.format("%d", a[#a]) }
   for i = #a - 1, 1, -1 do
      parts[#parts + 1] = string.format("%07d", a[i])
   end
   return table.concat(parts)
end

local function mag_cmp(a, b)
   if #a ~= #b then
      return #a < #b and -1 or 1
   end
   for i = #a, 1, -1 do
      if a[i] ~= b[i] then
         return a[i] < b[i] and -1 or 1
      end
   end
   return 0
end

local function mag_add(a, b)
   local r, carry = {}, 0
   for i = 1, math.max(#a, #b) do
      local s = (a[i] or 0) + (b[i] or 0) + carry
      r[i] = s % BASE
      carry = s // BASE
   end
   if carry > 0 then r[#r + 1] = carry end
   return r
end

-- a - b, requires a >= b
local function mag_sub(a, b)
   local r, borrow = {}, 0
   for i = 1, #a do
      local s = a[i] - (b[i] or 0) - borrow
      if s < 0 then
         s = s + BASE
         borrow = 1
      else
         borrow = 0
      end
      r[i] = s
   end
   return trim(r)
end

local function mag_mul(a, b)
   if #a == 0 or #b == 0 then
      return {}
   end
   local r = {}
   for i = 1, #a + #b do r[i] = 0 end
   for i = 1, #a do
      local carry, ai = 0, a[i]
      for j = 1, #b do
         local t = r[i + j - 1] + ai * b[j] + carry
         r[i + j - 1] = t % BASE
         carry = t // BASE
      end
      local k = i + #b
      while carry > 0 do
         local t = r[k] + carry
         r[k] = t % BASE
         carry = t // BASE
         k = k + 1
      end
   end
   return trim(r)
end

-- a * m for 0 <= m < BASE, plus an optional small addend
local function mag_mul_small(a, m, add)
   local r, carry = {}, add or 0
   for i = 1, #a do
      local t = a[i] * m + carry
      r[i] = t % BASE
      carry = t // BASE
   end
   while carry > 0 do
      r[#r + 1] = carry % BASE
      carry = carry // BASE
   end
   return trim(r)
end

-- a * 10^k
local function mag_shift(a, k)
   if k == 0 or #a == 0 then
      return a
   end
   local r = {}
   for _ = 1, k // BASE_DIGITS do r[#r + 1] = 0 end
   for i = 1, #a do r[#r + 1] = a[i] end
   return mag_mul_small(r, POW10[k % BASE_DIGITS])
end

-- Long division, one decimal digit at a time: returns quotient, remainder of n / d (d ~= 0).
local function mag_divmod(n, d)
   local digits = mag_to_digits(n)
   local q, r = {}, {}
   for i = 1, #digits do
      r = mag_mul_small(r, 10, digits:byte(i) - 48)
      local qd = 0
      while mag_cmp(r, d) >= 0 do
         r = mag_sub(r, d)
         qd = qd + 1
      end
      q[i] = string.char(48 + qd)
   end
   return mag_from_digits(table.concat(q)), r
end

-- round(n / d) half to even, on magnitudes
local function mag_div_round(n, d)
   local q, r = mag_divmod(n, d)
   local c = mag_cmp(mag_add(r, r), d)
   if c > 0 or (c == 0 and #q > 0 and q[1] % 2 == 1) then
      q = mag_add(q, { 1 })
   end
   return q
end

---------------------------------------------------------------------------------------------
-- Decimals

local function make(neg, mag, scale)
   trim(mag)
   return setmetatable({ neg = neg and #mag > 0, mag = mag, scale = scale }, Decimal)
end

local function parse_exponent(s)
   if s == "" then
      return 0
   end
   local sign, digits = s:match("^[eE]([%+%-]?)(%d+)$")
   if not digits or #digits > 4 then
      return nil
   end
   local e = digits_to_int(digits, 1, #digits)
   return sign == "-" and -e or e
end

-- "-12.3400", "1e3", "2.5E-4" -> decimal, or nil, err
function M.parse(s)
   if getmetatable(s) == Decimal then
      return s
   end
   if type(s) ~= "string" then
      return nil, "not a decimal string"
   end
   local sign, int, frac, exp = s:match("^(%-?)(%d+)%.(%d+)([eE]?[%+%-]?%d*)$")
   if not int then
      sign, int, exp = s:match("^(%-?)(%d+)([eE]?[%+%-]?%d*)$")
      frac = ""
   end
   if not int then
      return nil, "not a decimal: " .. (#s > 40 and s:sub(1, 40) .. "..." or s)
   end
   local e = parse_exponent(exp)
   if not e or e > MAX_EXPONENT or e < -MAX_EXPONENT then
      return nil, "bad exponent"
   end
   local mag = mag_from_digits(int .. frac)
   local scale = #frac - e
   if scale < 0 then
      mag = mag_shift(mag, -scale)
      scale = 0
   end
   return make(sign == "-", mag, scale)
end

local function coerce(x)
   local d, err = M.parse(x)
   if not d then
      error("decimal: " .. err, 3)
   end
   return d
end

-- Same value at a larger scale.
local function rescale(d, scale)
   if scale == d.scale then
      return d
   end
   return make(d.neg, mag_shift(d.mag, scale - d.scale), scale)
end

function Decimal:__tostring()
   local digits = mag_to_digits(self.mag)
   if self.scale > 0 then
      if #digits <= self.scale then
         digits = string.rep("0", self.scale - #digits + 1) .. digits
      end
      digits = digits:sub(1, -self.scale - 1) .. "." .. digits:sub(-self.scale)
   end
   return (self.neg and "-" or "") .. digits
end

M.tostring = function(d) return tostring(coerce(d)) end

function M.add(a, b)
   a, b = coerce(a), coerce(b)
   local scale = math.max(a.scale, b.scale)
   a, b = rescale(a, scale), rescale(b, scale)
   if a.neg == b.neg then
      return make(a.neg, mag_add(a.mag, b.mag), scale)
   end
   local c = mag_cmp(a.mag, b.mag)
   if c >= 0 then
      return make(a.neg, mag_sub(a.mag, b.mag), scale)
   end
   return make(b.neg, mag_sub(b.mag, a.mag), scale)
end

function M.neg(a)
   a = coerce(a)
   return make(not a.neg, a.mag, a.scale)
end

function M.sub(a, b)
   return M.add(a, M.neg(b))
end

-- Exact product; scale is the sum of the scales.
function M.mul(a, b)
   a, b = coerce(a), coerce(b)
   return make(a.neg ~= b.neg, mag_mul(a.mag, b.mag), a.scale + b.scale)
end

-- -1, 0 or 1
function M.compare(a, b)
   local d = M.sub(a, b)
   if #d.mag == 0 then
      return 0
   end
   return d.neg and -1 or 1
end

function M.is_zero(a)
   return #coerce(a).mag == 0
end

function M.is_positive(a)
   a = coerce(a)
   return #a.mag > 0 and not a.neg
end

-- Round half to even to `scale` decimal places (pads with zeros when scale is larger).
function M.round(a, scale)
   a = coerce(a)
   if scale >= a.scale then
      return rescale(a, scale)
   end
   local q = mag_div_round(a.mag, mag_shift({ 1 }, a.scale - scale))
   return make(a.neg, q, scale)
end

-- String with exactly `scale` decimals, rounded half to even.
function M.format(a, scale)
   return tostring(M.round(a, scale))
end

-- a / b rounded half to even to `scale` decimals, computed from the exact inputs with one
-- rounding. The long division keeps the exact remainder, which decides the rounding exactly
-- (as if there were unlimited guard digits). Division by zero returns nil, err.
function M.div(a, b, scale)
   a, b = coerce(a), coerce(b)
   if #b.mag == 0 then
      return nil, "division by zero"
   end
   -- a/b * 10^scale = (A * 10^(sb + scale)) / (B * 10^sa)
   local n = mag_shift(a.mag, b.scale + scale)
   local d = mag_shift(b.mag, a.scale)
   return make(a.neg ~= b.neg, mag_div_round(n, d), scale)
end

M.Decimal = Decimal

return M
