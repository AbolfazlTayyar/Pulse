-- deadline.lua with a fake clock: no real sleeping.
local deadline = require("src.deadline")

local function fake_clock(start)
   local now = start or 0
   local c = {}
   function c.clock() return now end
   function c.advance(ms) now = now + ms end
   function c.sleep(ms) now = now + ms end
   return c
end

describe("deadline", function()
   it("counts down from the budget", function()
      local c = fake_clock(1000)
      local d = deadline.new(4000, { clock = c.clock, sleep = c.sleep })
      assert.are.equal(4000, d:remaining_ms())
      c.advance(1200)
      assert.are.equal(2800, d:remaining_ms())
      assert.are.equal(1200, d:elapsed_ms())
      assert.is_false(d:expired())
   end)

   it("allows(ms) is true only when strictly more than ms is left", function()
      local c = fake_clock()
      local d = deadline.new(4000, { clock = c.clock, sleep = c.sleep })
      c.advance(1200)
      assert.is_true(d:allows(2000))
      assert.is_false(d:allows(3000))
      assert.is_false(d:allows(2800))
      assert.is_true(d:allows(2799))
   end)

   it("expires and never reports negative time", function()
      local c = fake_clock()
      local d = deadline.new(100, { clock = c.clock, sleep = c.sleep })
      c.advance(150)
      assert.is_true(d:expired())
      assert.are.equal(0, d:remaining_ms())
      assert.is_false(d:allows(0))
   end)

   it("sleeps min(ms, remaining) and never past the deadline", function()
      local c = fake_clock()
      local d = deadline.new(4000, { clock = c.clock, sleep = c.sleep })
      c.advance(1200)
      assert.are.equal(100, d:sleep(100))
      assert.are.equal(1300, d:elapsed_ms())
      assert.are.equal(2700, d:sleep(10000))
      assert.are.equal(4000, d:elapsed_ms())
      assert.is_true(d:expired())
      assert.are.equal(0, d:sleep(100))
   end)

   it("can count from an earlier start (process start)", function()
      local c = fake_clock(5000)
      local d = deadline.new(4000, { clock = c.clock, sleep = c.sleep, start = 4000 })
      assert.are.equal(1000, d:elapsed_ms())
      assert.are.equal(3000, d:remaining_ms())
   end)

   it("uses a real millisecond clock by default", function()
      local d = deadline.new(4000)
      assert.is_true(d:remaining_ms() <= 4000 and d:remaining_ms() > 3900)
      assert.is_true(deadline.now_ms() > 1.7e12)
   end)
end)
