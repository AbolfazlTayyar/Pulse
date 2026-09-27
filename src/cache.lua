-- Bounded in-process LRU of ticker items (ADR 0014). Meaningful in daemon mode only: a one-shot
-- process exits after one command, so its cache is always empty and Redis is the real cache.
-- O(1) get/put: a hash map from key to node plus a doubly linked list in recency order.
local json = require("src.vendor.dkjson")

local M = {}

local Cache = {}
Cache.__index = Cache

function M.new(max_entries, max_bytes)
   local head, tail = {}, {} -- sentinels: head.next is the most recently used entry
   head.next, tail.prev = tail, head
   return setmetatable({
      max_entries = max_entries,
      max_bytes = max_bytes,
      map = {},
      head = head,
      tail = tail,
      entries = 0,
      bytes = 0,
      hits = 0,
      misses = 0,
      evictions = 0,
   }, Cache)
end

local function unlink(node)
   node.prev.next = node.next
   node.next.prev = node.prev
end

function Cache:_push_front(node)
   node.prev, node.next = self.head, self.head.next
   self.head.next.prev = node
   self.head.next = node
end

function Cache:_remove(node)
   unlink(node)
   self.map[node.key] = nil
   self.entries = self.entries - 1
   self.bytes = self.bytes - node.size
end

local function copy(item)
   local c = {}
   for k, v in pairs(item) do c[k] = v end
   return c
end

-- Stores a copy of item under key (e.g. "coingecko:BTC"). Its size is the length of its encoded
-- JSON. Evicts least-recently-used entries until both limits hold; an item larger than
-- max_bytes on its own is not stored. Returns true when stored.
function Cache:put(key, item)
   local ok, encoded = pcall(json.encode, item)
   if not ok or type(encoded) ~= "string" then
      return false
   end
   local size = #encoded
   local old = self.map[key]
   if old then
      self:_remove(old)
   end
   if size > self.max_bytes then
      return false
   end
   while self.entries >= self.max_entries or self.bytes + size > self.max_bytes do
      self:_remove(self.tail.prev)
      self.evictions = self.evictions + 1
   end
   local node = { key = key, item = copy(item), size = size }
   self:_push_front(node)
   self.map[key] = node
   self.entries = self.entries + 1
   self.bytes = self.bytes + size
   return true
end

-- The item while it is younger than fresh_s (now - as_of_unix < fresh_s), else nil. A hit
-- counts as a use for LRU order; an entry found too old is dropped.
function Cache:get(key, now, fresh_s)
   local node = self.map[key]
   if not node then
      self.misses = self.misses + 1
      return nil
   end
   if now - node.item.as_of_unix >= fresh_s then
      self:_remove(node)
      self.misses = self.misses + 1
      return nil
   end
   unlink(node)
   self:_push_front(node)
   self.hits = self.hits + 1
   local item = copy(node.item)
   item.stale = false
   return item
end

function Cache:stats()
   return { entries = self.entries, bytes = self.bytes, hits = self.hits, misses = self.misses,
      evictions = self.evictions }
end

-- Keys from most to least recently used (for tests and debugging).
function Cache:keys()
   local out, node = {}, self.head.next
   while node ~= self.tail do
      out[#out + 1] = node.key
      node = node.next
   end
   return out
end

return M
