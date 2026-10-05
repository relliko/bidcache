-- Loads bidcache.lua against stubbed Ashita globals and a fake bid box in fake memory, laid out
-- like the real one (number at +40 of the object a pointer at +12 of the menu points to). The
-- fake box also keeps its item (2 bytes) at +44 and quantity (1 byte) at +46 of that object.
--   python -c "from lupa import luajit21; r=luajit21.LuaRuntime(); r.execute(\"package.path='./?.lua;'..package.path\"); r.execute(open('tests/smoke.lua').read())"
local events = {}
addon = {}

-- Fake memory: menu pointer 0x1000 -> 0x2000 -> menu object; object + 4 -> header (name at + 0x46).
local m = {}
local function w8(a, v) m[a] = v end
local function w16(a, v) m[a] = v % 256; m[a + 1] = math.floor(v / 256) % 256 end
local function w32(a, v) for i = 0, 3 do m[a + i] = v % 256; v = math.floor(v / 256) end end
local function r32(a) local v = 0 for i = 3, 0, -1 do v = v * 256 + (m[a + i] or 0) end return v end
local obj, num = 0, 0
local NUM_OFF = 40
local base = 0x00600000
-- Puts a menu on screen (a new object each time; the old one stays in memory, like a parent menu).
local function show(name, item, qty)
    base = base + 0x10000
    obj = base
    local hdr, child = obj + 0x1000, obj + 0x2000
    num = child + NUM_OFF
    w32(0x2000, obj)
    w32(obj + 4, hdr)
    w32(obj + 12, child)
    w32(obj + 0x40, 300) -- some other number
    if (item ~= nil) then
        w16(child + 44, item)
        w8(child + 46, qty or 1)
    end
    local s = 'menu    ' .. name
    for i = 1, #s do m[hdr + 0x46 + i - 1] = s:byte(i) end
end
local function close_all() w32(0x2000, 0) end
w32(0x1000, 0x2000)
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
local writes = 0
ashita = {
    events = { register = function (name, _, fn) events[name] = fn end },
    fs = { create_dir = function () end },
    memory = { find = function () return 0x1000 end, write_uint32 = function (a, v) writes = writes + 1 w32(a, v) end },
}
local selected = 0
AshitaCore = {
    GetMemoryManager = function () return { GetInventory = function () return {
        GetSelectedItemId = function () return selected end, GetSelectedItemIndex = function () return 0 end,
        GetSelectedItemName = function () return '' end } end } end,
    GetResourceManager = function () return {
        GetItemById = function (_, id) return { Name = { 'Item' .. id } } end,
    } end,
}
struct = { unpack = function (fmt, s, pos)
    local n = fmt == 'H' and 2 or 4
    local v = 0
    for i = n, 1, -1 do v = v * 256 + s:byte(pos + i - 1) end
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
    load = function (d)
        store = { enabled = true, menus = { d.menus[1] }, place = d.place, item_place = '', qty_place = '',
                  sel_ok = false, parents = {}, debug = true }
        return store
    end,
    save = function () end, register = function () end, settings_path = function () return 'cfg' end }
-- Debug dumps go nowhere.
local dumped = 0
io.open = function () dumped = dumped + 1 return { write = function () end, close = function () end } end
print = function () end

dofile('bidcache.lua')

local function frames(n) for _ = 1, n or 4 do clock = clock + 0.016 events.d3d_present() end end
local function le(v, n) local t = {} for i = 1, n do t[i] = string.char(v % 256) v = math.floor(v / 256) end return table.concat(t) end
local function packet(cmd, price, item, qty)
    local d = '\x4C\x0A\0\0' .. string.char(cmd) .. '\xFF\x01\0' .. le(price or 0, 4) .. le(item or 0, 2) .. '\0\0'
        .. le(qty or 0, 4) .. ('\0'):rep(0x40)
    events.packet_in({ id = 0x04C, size = #d, data = d })
end

-- At the auction house: the list is up, and the auction house has sent something.
local function at_ah()
    show('auclist') frames()
    packet(0x0A)
end
-- Opens the bid box for an item picked from the list (at row: 1 by default) through its item
-- window, like the game; returns what the box shows.
local function open_box(item, qty, row)
    show('auclist')
    w32(obj + 0x4C, row or 1)
    frames()
    show('auc3') frames()
    show('moneyctr', item, qty) frames()
    return r32(num)
end
-- Bids what's in the box (or what you enter), and goes back to the list.
local function bid(entered, item, qty)
    if (entered ~= nil) then w32(num, entered) end
    frames(2)
    local price = r32(num)
    show('auclist') frames()
    packet(0x0E, price, item, qty or 1)
    return price
end

local function cmd(c) local e = { command = c } events.command(e) assert(e.blocked, c) end

at_ah()
-- First bid on item 100: nothing remembered, so the box opens at 0 and you enter 1200.
selected = 100
assert(open_box(100) == 0)
bid(1200, 100)
assert(store.sel_ok and store.parents[1] == 'auc3')
assert(store.prices == nil, 'prices must not be saved')
-- Bidding on item 100 again: it already holds 1200 (from the game's selected item, for now).
assert(open_box(100) == 1200, 'not filled from the selected item')
bid(nil, 100)
-- A different item, 200: the box opens at 0 and the 1200 is forgotten. You bid 500.
selected = 200
assert(open_box(200) == 0, 'filled a different item')
bid(500, 200)
assert(store.item_place == 'v@12|44', 'item place not learned: ' .. store.item_place)
-- Now the item comes from the box's own memory, even if the selected item says otherwise.
selected = 999
assert(open_box(200) == 500, 'item 200 not filled from the box')
bid(nil, 200)
-- Back to item 100: 0, and the 500 is gone too, so item 200 is at 0 again as well.
assert(open_box(100) == 0, 'a big price landed on another item')
assert(open_box(200) == 0, 'the last bid was not forgotten')
-- A single of item 100 at 1200, then its stack. Not knowing yet that the box is for a stack, it
-- gets the single's price (too low for a stack, never too high). You enter 20000.
open_box(100) bid(1200, 100)
assert(open_box(100, 12) == 1200)
bid(20000, 100, 12)
assert(store.qty_place == 'v@12|46', 'quantity place not learned: ' .. store.qty_place)
assert(open_box(100, 12) == 20000, 'stack price not filled')
bid(nil, 100, 12)
-- The single after the stack is the other kind: 0, so the stack's price can't land on a single.
assert(open_box(100, 1) == 0, 'stack price landed on a single')

-- A single at row 1 and its stack at row 2 of the list: picking the other row is another listing,
-- so the box opens at 0 even before bidcache could tell a stack's box from a single's.
store.qty_place = ''
open_box(300, 1, 1) bid(150, 300)
assert(open_box(300, 1, 1) == 150, 'same row not filled')
bid(nil, 300)
assert(open_box(300, 12, 2) == 0, 'single price landed on the stack row')
bid(1700, 300, 12)
assert(open_box(300, 12, 2) == 1700, 'stack row not filled')
bid(nil, 300, 12)
assert(open_box(300, 1, 1) == 0, 'stack price landed on the single row')

-- /bidcache price: 0 forgets the bid; a price with no bid behind it is for whichever item is next.
open_box(100) bid(900, 100)
cmd('/bc price 0')
assert(open_box(100) == 0, 'price 0 did not forget the bid')
cmd('/bc price 300')
assert(open_box(200) == 300, 'set price not filled')
assert(open_box(100) == 0, 'set price used for a second item')
cmd('/bc price 99999999')
assert(open_box(100) == 99999999, 'top price not accepted')
cmd('/bc price 100000000')

-- A box you've already changed is left alone.
open_box(100) bid(900, 100)
show('auclist') frames()
show('moneyctr', 100, 1)
w32(num, 7)
frames()
assert(r32(num) == 7)
-- Opened from some other menu (selling from your inventory at the counter): not filled.
open_box(100) bid(900, 100)
show('inventor') frames()
show('moneyctr', 100, 1) frames()
assert(r32(num) == 0, 'filled a box opened from elsewhere')
-- Leave the auction house (every menu closed), then trade gil: not filled either.
open_box(100) bid(900, 100)
close_all() frames(120)
assert(open_box(100, 1) == 0, 'filled away from the auction house')

-- A client update moves the number: two bids that don't match stop the writing and drop the old
-- place; two bids at different prices find the new one.
at_ah()
NUM_OFF = 48
open_box(100) bid(1500, 100)
assert(store.place == 'v@12|40')
assert(open_box(100) == 0 and r32(num - 8) == 0, 'wrote after a mismatch')
bid(1600, 100)
assert(store.place == '', 'stale place kept')
open_box(100) bid(1700, 100)
open_box(100) bid(1800, 100)
assert(store.place == 'v@12|48', 'new place not found: ' .. store.place)
assert(open_box(100) == 1800)
bid(nil, 100)

local w = writes
for _, c in ipairs({ '/bidcache', '/bc off', '/bc on', '/bc debug off', '/bc price x', '/bc relearn' }) do
    cmd(c)
end
assert(store.place == '' and store.item_place == '' and store.qty_place == '' and #store.menus == 0)
assert(writes == w)
events.unload()
io.write('smoke ok\n')
