-- Proves the test runner works and runs on the Lua version the project targets (ADR 0004).
-- busted picks its own interpreter, so this does not prove plain `lua` is 5.4; the Dockerfile
-- checks that.
describe("test runner", function()
   it("runs on Lua 5.4", function()
      assert.are.equal("Lua 5.4", _VERSION)
   end)
end)
