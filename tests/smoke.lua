-- Loads bidcache.lua against stubbed Ashita globals and a fake bid box in fake memory, laid out
-- like the real one (number at +40 of the object a pointer at +12 of the menu points to).
--   python -c "from lupa import luajit21; r=luajit21.LuaRuntime(); r.execute(\"package.path='./?.lua;'..package.path\"); r.execute(open('tests/smoke.lua').read())"
local events = {}
addon = {}

-- Fake memory: menu pointer 0x1000 -> 0x2000 -> menu object; object + 4 -> header (name at + 0x46).
local m = {}
local function w32(a, v) for i = 0, 3 do m[a + i] = v % 256; v = math.floor(v / 256) end end
local function r32(a) local v = 0 for i = 3, 0, -1 do v = v * 256 + (m[a + i] or 0) end return v end
local obj, num = 0, 0
local NUM_OFF = 40 -- where the fake box keeps its number in the child object
local function open_menu(name, at)
    for k in pairs(m) do m[k] = nil end
    obj = at
    local hdr, child = at + 0x1000, at + 0x2000
    num = child + NUM_OFF
    w32(0x1000, 0x2000)
    w32(0x2000, obj)
    w32(obj + 4, hdr)
    w32(obj + 12, child)
    local s = 'menu    ' .. name
    for i = 1, #s do m[hdr + 0x46 + i - 1] = s:byte(i) end
end
local function close_menu() w32(0x2000, 0) end
local writes = 0
package.loaded['safemem'] = {
    u32 = function (a) return r32(a) end,
    read = function (a, n)
        if (a < 0x10000) then return nil end
        local t = {} for i = 0, n - 1 do t[#t + 1] = string.char(m[a + i] or 0) end
        return table.concat(t)
    end,
}
local clock = 0
os.clock = function () return clock end
ashita = {
    events = { register = function (name, _, fn) events[name] = fn end },
    memory = { find = function () return 0x1000 end, write_uint32 = function (a, v) writes = writes + 1 w32(a, v) end },
}
struct = { unpack = function (fmt, s, pos)
    local v = 0
    for i = 4, 1, -1 do v = v * 256 + s:byte(pos + i - 1) end
    return v
end }
function T(t) return t end
string.args = function (s) local a = {} for w in s:gmatch('%S+') do a[#a + 1] = w end return a end
string.any = function (s, ...) for _, v in ipairs({ ... }) do if s == v then return true end end return false end
string.fmt = string.format
local function chain() local o = {} o.append = function () return o end return o end
package.loaded['common'] = true
package.loaded['chat'] = { header = chain, message = chain, error = chain, success = chain }
local store = nil
package.loaded['settings'] = {
    load = function (d) store = { enabled = d.enabled, menus = { d.menus[1] }, place = d.place, parents = {}, last_price = 0, debug = true } return store end,
    save = function () end, register = function () end }
print = function () end

dofile('bidcache.lua')

local function frames(n) for _ = 1, n or 1 do clock = clock + 0.016 events.d3d_present() end end
local function le(v) local t = {} for i = 1, 4 do t[i] = string.char(v % 256) v = math.floor(v / 256) end return table.concat(t) end
local function packet(cmd, price)
    local d = '\x4C\x0A\0\0' .. string.char(cmd) .. '\xFF\x01\0' .. le(price or 0) .. ('\0'):rep(0x40)
    events.packet_in({ id = 0x04C, size = #d, data = d })
end
local base = 0x00600000
local function open(name) base = base + 0x10000 open_menu(name, base) frames(4) end

-- Walk up to the auction house: it sends 0x04C as it opens.
open('auclist')
packet(0x0A)
-- First bid: nothing remembered yet, so the box opens at 0 and you enter 1200.
open('moneyctr')
assert(r32(num) == 0)
w32(num, 1200)
frames(2)
open('auclist')
packet(0x0E, 1200)
assert(store.last_price == 1200)
assert(store.parents[1] == 'auclist', 'parent not learned: ' .. tostring(store.parents[1]))
-- Next time the box opens it already holds 1200, with no keys pressed.
open('moneyctr')
assert(r32(num) == 1200, 'not filled')
open('auclist')
-- A box you've already changed is left alone.
open_menu('moneyctr', base + 0x10000) base = base + 0x10000
w32(num, 7)
frames(4)
assert(r32(num) == 7)
open('auclist')
-- Opened from some other menu (say, selling from your inventory at the counter): not filled.
open('inventor')
open('moneyctr')
assert(r32(num) == 0, 'filled a box opened from elsewhere')
-- Leave the auction house (every menu closed), then trade gil to someone: not filled either.
close_menu()
frames(120)
open('auclist') -- the same menu name as the AH list, but no auction house packet this time
open('moneyctr')
assert(r32(num) == 0, 'filled away from the auction house')

-- A client update moves the number: two bids that don't match drop the old place, and the next
-- two bids at different prices find the new one.
local function at_ah_bid(entered)
    open('auclist')
    packet(0x0A)
    open('moneyctr')
    w32(num, entered)
    frames(2)
    open('auclist')
    packet(0x0E, entered)
end
NUM_OFF = 48
store.place, store.menus, store.parents = 'v@12|40', { 'moneyctr' }, { 'auclist' }
at_ah_bid(500)
assert(store.place == 'v@12|40')
open('auclist')
packet(0x0A)
open('moneyctr')
assert(r32(num - 8) == 0, 'wrote to a place that just failed to match')
at_ah_bid(600)
assert(store.place == '', 'stale place kept')
at_ah_bid(700)
at_ah_bid(800)
assert(store.place == 'v@12|48', 'new place not found: ' .. store.place)
open('auclist')
packet(0x0A)
open('moneyctr')
assert(r32(num) == 800, 'not filled at the new place')
open('auclist')
-- The box's menu renamed too: it's found again from scratch.
local real_open = open
open = function (name) real_open(name == 'moneyctr' and 'moneyct2' or name) end
at_ah_bid(900)
at_ah_bid(1000)
assert(#store.menus == 0 and store.place == '', 'stale menu kept')
at_ah_bid(1100)
at_ah_bid(1300)
assert(store.menus[1] == 'moneyct2' and store.place == 'v@12|48', 'renamed box not found')
open = real_open

local w = writes
for _, c in ipairs({ '/bidcache', '/bidcache off', '/bidcache on', '/bidcache price 999', '/bidcache price x',
                     '/bidcache debug off', '/bidcache relearn' }) do
    local e = { command = c }
    events.command(e)
    assert(e.blocked, c)
end
assert(store.last_price == 999 and store.place == '' and #store.menus == 0 and #store.parents == 0)
assert(writes == w)
events.unload()
io.write('smoke ok\n')
