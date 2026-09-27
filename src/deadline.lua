-- Time budget for one invocation (CLAUDE.md: every wait respects deadline.lua; ADR 0021 retry
-- rules). Clock and sleep are injectable so specs run without real sleeping.
local socket = require("socket")

local M = {}

local Deadline = {}
Deadline.__index = Deadline

-- Wall clock in milliseconds (float).
function M.now_ms()
   return socket.gettime() * 1000
end

local function real_sleep(ms)
   socket.sleep(ms / 1000)
end

-- budget_ms: total budget. opts.clock() -> ms, opts.sleep(ms), opts.start (ms, default now) so
-- the budget can count from process start rather than from when config was loaded.
function M.new(budget_ms, opts)
   opts = opts or {}
   local clock = opts.clock or M.now_ms
   return setmetatable({
      budget = budget_ms,
      clock = clock,
      sleeper = opts.sleep or real_sleep,
      start = opts.start or clock(),
   }, Deadline)
end

function Deadline:elapsed_ms()
   return math.floor(self.clock() - self.start)
end

function Deadline:remaining_ms()
   local r = math.floor(self.budget - (self.clock() - self.start))
   return r > 0 and r or 0
end

function Deadline:expired()
   return self:remaining_ms() <= 0
end

-- True only if strictly more than ms is left (ADR 0021: retry only if the budget exceeds the
-- timeout of the attempt).
function Deadline:allows(ms)
   return self:remaining_ms() > ms
end

-- Sleeps min(ms, remaining) and never past the deadline. Returns the ms actually slept.
function Deadline:sleep(ms)
   local s = math.min(ms, self:remaining_ms())
   if s <= 0 then
      return 0
   end
   self.sleeper(s)
   return s
end

return M
