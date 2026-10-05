--[[
* bidcache
*
* Remembers your last auction house bid and writes its price straight back into the bid box when
* you bid on the same item again, so you can press Enter at once instead of building the number
* up from 0 with the arrows again. Opening the box for a different listing forgets it, so a big
* price never lands on a cheap item. A single and a stack of the same item are different rows of
* the auction list, and the list keeps the row you picked, so they count as different listings.
* It's only kept while the game runs.
*
* - The bid comes from the auction house's reply (incoming packet 0x04C, command 0x0E), which
*   echoes the price you entered, the item and the quantity, whether the bid won or not.
* - The box is the game's 'moneyctr' menu, and its number sits at +40 in the object a pointer at
*   +12 of the menu points to. That's the default.
* - Which item (and whether a stack) the box is for is read from the game's memory too. Where the
*   game keeps those is found from your bids, the same way: every place in the box's memory (and
*   the menu it was opened from) that held the item you bid on is a candidate, and bids on
*   different items narrow it to one. Until then the game's selected item is used, once a bid has
*   shown it matches. A box whose item can't be told is left at 0. Not knowing whether it's a
*   stack, a stack's price is never filled.
* - Every bid checks all of these places. One that doesn't match stops being used, and a second
*   miss makes bidcache find it again from your next bids (a client update may move them).
* - The same box is used for other amounts (trading gil, setting prices), so it is only filled at
*   the auction house: after the auction house has sent something since every menu was last
*   closed, and, once a bid has shown which menu you bid from, only when opened from that menu.
*   It only writes while the box still reads 0.
*
* Nothing is ever sent to the server, no packet is changed, and no key is pressed: bidcache reads
* incoming packets and client memory, and writes only the bid box's own number.
--]]

addon.name    = 'bidcache';
addon.author  = 'Relli';
addon.version = '0.6.1';
addon.desc    = 'Puts your last auction house bid price back in the bid box when you bid on the same item again.';
addon.link    = 'https://github.com/relliko/bidcache';

require('common');
local chat     = require('chat');
local settings = require('settings');
local core     = require('core');
local safemem  = require('safemem');

local defaults = T{
    enabled = true,
    menus = T{ 'moneyctr' }, -- the bid box's menu name(s); learned from a bid if empty
    place = 'v@12|40',       -- where the box keeps its number ('<region>|<offset>')
    item_place = '',         -- where the game keeps the item the box is for; learned
    qty_place = '',          -- where it keeps the quantity (1, or the stack size); learned
    sel_ok = false,          -- the game's selected item matched the last bid's item
    parents = T{},           -- menus the bid box has been opened from; learned from your bids
    debug = false,           -- print menu changes and what learning finds
};

local OBJ_SIZE, HDR_SIZE, CHILD_SIZE, MAX_CHILDREN = 0x400, 0x200, 0x100, 64;
local LIST_ROW = 0x4C;   -- in the auction list menu: the row you picked (a single and its stack are different rows)
local RECENT = 5;        -- seconds a closed menu's copy is kept for matching a bid reply
local AH_CLOSE_WAIT = 1; -- seconds with no menu open before the auction house counts as left

-- The places learned from bids: the setting each is saved in, its width in bytes, and what it's called.
local PLACES = {
    { key = 'item_place', width = 2, what = 'which item the bid box is for' },
    { key = 'qty_place',  width = 1, what = 'whether the bid box is for a stack' },
};

local ap = {
    settings = settings.load(defaults),
    menu = '', obj = 0, hdr = 0,
    snap = nil,       -- copy of the open menu, see core.find
    closed = {},      -- { name, snap, t } of recently closed menus, newest first
    learn = {},       -- see core.narrow, for the box's number
    misses = 0,       -- bid replies the box's place didn't match
    places = {},      -- [key] = { learn, misses } for each of PLACES
    fill = nil,       -- { polls, writes, price } while writing the price into the box
    at_ah = false,    -- the auction house has sent something since every menu was last closed
    no_menu_since = nil,
    parent = '', parent_obj = 0, parent_hdr = 0, -- the menu open before the current one
    box_parent = nil, -- the menu the bid box was last opened from
    box_psnap = nil,  -- a copy of it, taken as the box opened
    last = nil,       -- your last bid, see core.match; never saved
    seen = {},        -- [menu name] = { obj, hdr } of the latest of each menu (for debug dumps)
    from = {},        -- [menu name] = { obj } of the menu it was last opened from
    box_row = nil,    -- the auction list row the bid box was last opened for
};

local function reset_places()
    for _, p in ipairs(PLACES) do
        ap.places[p.key] = { learn = {}, misses = 0 };
    end
end
reset_places();

local function msg(text)
    print(chat.header(addon.name):append(chat.message(text)));
end

local function gil(n)
    local s = tostring(n):reverse():gsub('(%d%d%d)', '%1,'):reverse();
    return (s:gsub('^,', '')) .. ' gil';
end

local function item_name(id)
    local item = AshitaCore:GetResourceManager():GetItemById(id);
    return (item ~= nil and item.Name[1] ~= nil and item.Name[1] ~= '') and item.Name[1] or ('item ' .. tostring(id));
end

local function listed(list, name)
    for _, v in ipairs(list) do
        if (v == name) then
            return true;
        end
    end
    return false;
end

local function price_menu(name)
    return listed(ap.settings.menus, name);
end

--[[
* The game's open menu: its name without the 'menu' prefix (or ''), the menu object and its
* header (same pointer path as HXUI's GetMenuName). Read with safemem, so a menu freed mid-read
* gives '' instead of a crash.
--]]
local menu_ptr = nil;
local function menu_info()
    if (menu_ptr == nil) then
        menu_ptr = ashita.memory.find('FFXiMain.dll', 0, '8B480C85C974??8B510885D274??3B05', 16, 0) or 0;
    end
    if (menu_ptr == 0) then
        return '', 0, 0;
    end
    local sub = safemem.u32(menu_ptr);
    local obj = sub ~= nil and sub ~= 0 and safemem.u32(sub) or nil;
    local hdr = obj ~= nil and obj ~= 0 and safemem.u32(obj + 4) or nil;
    local name = hdr ~= nil and hdr ~= 0 and safemem.read(hdr + 0x46, 16) or nil;
    if (name == nil) then
        return '', 0, 0;
    end
    name = name:gsub('%z', '');
    return name:match('^menu%s+(%S+)') or name, obj, hdr;
end

local function looks_like_ptr(p)
    return p >= 0x00400000 and p < 0x7FFF0000 and p % 4 == 0;
end

-- A copy of a menu object, its header, and what the object's pointers point to; regions get prefix.
local function snapshot(obj, hdr, prefix, into)
    local snap = into or {};
    prefix = prefix or '';
    local o = obj ~= 0 and safemem.read(obj, OBJ_SIZE) or nil;
    if (o == nil) then
        return nil;
    end
    snap[prefix .. 'v'] = o;
    snap[prefix .. 'h'] = safemem.read(hdr, HDR_SIZE);
    local n = 0;
    for off = 8, OBJ_SIZE - 4, 4 do
        local p = core.u32(o, off);
        if (looks_like_ptr(p) and p ~= hdr and p ~= obj) then
            local c = safemem.read(p, CHILD_SIZE);
            if (c ~= nil) then
                snap[prefix .. 'v@' .. off] = c;
                n = n + 1;
                if (n >= MAX_CHILDREN) then
                    break;
                end
            end
        end
    end
    return snap;
end

-- The address of a place in the open bid box ('p:' places: in the menu it was opened from), or nil.
local function resolve(place)
    local region, off = core.parse(place);
    if (region == nil) then
        return nil;
    end
    local obj, hdr = ap.obj, ap.hdr;
    if (region:sub(1, 2) == 'p:') then
        region, obj, hdr = region:sub(3), ap.parent_obj, ap.parent_hdr;
    end
    if (region == 'v') then
        return obj + off;
    elseif (region == 'h') then
        return hdr + off;
    end
    local poff = tonumber(region:match('^v@(%d+)$') or '');
    local p = poff ~= nil and safemem.u32(obj + poff) or nil;
    if (p == nil or not looks_like_ptr(p)) then
        return nil;
    end
    return p + off;
end

-- The width-byte value at a place, or nil.
local function read_place(place, width)
    local addr = place ~= '' and resolve(place) or nil;
    local s = addr ~= nil and safemem.read(addr, width) or nil;
    return s ~= nil and core.value(s, 0, width) or nil;
end

-- A learned place that's usable now (found, and not missed since), or nil.
local function usable(key)
    local place = ap.settings[key];
    return (place ~= '' and ap.places[key].misses == 0) and place or nil;
end

-- The item the open box is for, and whether it's a stack (nil when not known).
local function box_item()
    local s = ap.settings;
    local id = nil;
    local ip = usable('item_place');
    if (ip ~= nil) then
        id = read_place(ip, 2);
    elseif (s.sel_ok) then
        id = AshitaCore:GetMemoryManager():GetInventory():GetSelectedItemId();
    end
    if (id == nil or id == 0 or id == 0xFFFF) then
        return nil, nil;
    end
    local stack = nil;
    local qp = usable('qty_place');
    local q = qp ~= nil and read_place(qp, 1) or nil;
    if (q ~= nil and q >= 1) then
        stack = q > 1;
    end
    return id, stack;
end

--[[
* The auction list row the open bid box is for, or nil: the box opens from the item's window
* (auc3), which opens from the list (auclist), and the list keeps the row you picked.
--]]
local function box_row()
    local list = ap.from[ap.parent];
    local row = list ~= nil and safemem.u32(list.obj + LIST_ROW) or nil;
    if (row == nil or row > 0xFFFF) then
        return nil;
    end
    return row;
end

-- The bid box just opened: fill it if it's the auction house's and you last bid on this listing.
local function on_open()
    local s = ap.settings;
    ap.box_parent = ap.parent;
    ap.box_row = box_row();
    ap.box_psnap = snapshot(ap.parent_obj, ap.parent_hdr, 'p:');
    -- After a bid that didn't match the box's place, nothing is written until it's found again.
    if (s.place == '' or not ap.at_ah or ap.misses > 0) then
        return;
    end
    if (#s.parents > 0 and not listed(s.parents, ap.parent)) then
        if (s.debug) then
            msg(('Not filling: opened from "%s", not a menu you\'ve bid from.'):fmt(ap.parent));
        end
        return;
    end
    local id, stack = box_item();
    local price, wipe = core.match(ap.last, id, stack, ap.box_row);
    if (wipe) then
        ap.last = nil;
    elseif (price ~= nil and ap.last.id == nil) then
        -- A price set with /bidcache price is for this listing.
        ap.last.id, ap.last.stack, ap.last.row = id, stack, ap.box_row;
    end
    if (s.debug) then
        local kind = stack == true and 'stack' or stack == false and 'single' or 'single or stack';
        kind = kind .. (ap.box_row ~= nil and (', list row %d'):fmt(ap.box_row) or ', list row unknown');
        msg(('Box for %s (%s): %s.'):fmt(id ~= nil and item_name(id) or 'an unknown item', kind,
            price ~= nil and gil(price) or 'no price to fill'));
    end
    if (price ~= nil) then
        ap.fill = { polls = 0, writes = 0, price = price };
    end
end

--[[
* With debug on: writes the open bid box's memory and the menu it was opened from to a file in
* bidcache's settings folder, so a single's box and a stack's box can be compared to find where
* the game says which it is. Read only.
--]]
local dumps = 0;
-- Copies a menu and what its pointers point to, two levels deep, into snap under prefix.
local function deep_snapshot(obj, hdr, prefix, snap)
    local o = obj ~= 0 and safemem.read(obj, 0x200) or nil;
    if (o == nil) then
        return;
    end
    snap[prefix .. 'v'] = o;
    snap[prefix .. 'h'] = safemem.read(hdr, HDR_SIZE);
    local seen, n = { [obj] = true, [hdr] = true }, 0;
    local function walk(data, name, depth)
        for off = 0, #data - 4, 4 do
            local p = core.u32(data, off);
            if (n < 400 and looks_like_ptr(p) and not seen[p]) then
                seen[p] = true;
                local c = safemem.read(p, 0x100);
                if (c ~= nil) then
                    n = n + 1;
                    local key = name .. '@' .. off;
                    snap[prefix .. key] = c;
                    if (depth < 2) then
                        walk(c, key, depth + 1);
                    end
                end
            end
        end
    end
    walk(o, 'v', 1);
end

local function dump_box()
    local snap = snapshot(ap.obj, ap.hdr);
    if (snap == nil) then
        return;
    end
    snapshot(ap.parent_obj, ap.parent_hdr, 'p:', snap);
    for name, m in pairs(ap.seen) do
        if (name:match('^auc') ~= nil) then
            deep_snapshot(m.obj, m.hdr, name .. ':', snap);
        end
    end
    local id = box_item();
    local inv = AshitaCore:GetMemoryManager():GetInventory();
    snap['selected'] = ('%d %d %s'):fmt(inv:GetSelectedItemId() or -1, inv:GetSelectedItemIndex() or -1,
        tostring(inv:GetSelectedItemName()));
    local dir = settings.settings_path() .. '\\dumps';
    ashita.fs.create_dir(dir);
    dumps = dumps + 1;
    local path = ('%s\\%s_%d_%s.txt'):fmt(dir, os.date('%Y%m%d-%H%M%S'), dumps, tostring(id or 'unknown'));
    local f = io.open(path, 'w');
    if (f == nil) then
        return;
    end
    f:write(('item %s from "%s"\n'):fmt(tostring(id), ap.box_parent or ''));
    local keys = {};
    for k in pairs(snap) do keys[#keys + 1] = k; end
    table.sort(keys);
    for _, k in ipairs(keys) do
        f:write(k, ' ', (snap[k]:gsub('.', function (c) return ('%02X'):format(c:byte()); end)), '\n');
    end
    f:close();
    msg(('Saved the bid box\'s memory to %s.'):fmt(path));
end

-- Writes the price into the open box while it still reads 0 (the box may zero itself as it opens).
local function fill_step()
    local f, s = ap.fill, ap.settings;
    f.polls = f.polls + 1;
    if (f.polls < 2) then
        return;
    end
    local addr = resolve(s.place);
    local cur = addr ~= nil and safemem.u32(addr) or nil;
    if (cur == 0 and f.writes < 3) then
        ashita.memory.write_uint32(addr, f.price);
        f.writes = f.writes + 1;
    else
        -- Done, gone, or holding something else (you changed it): leave it alone.
        ap.fill = nil;
    end
end

-- Checks a learned place against a bid, or learns it from the bid when it isn't known.
local function check_place(p, found, value)
    local s, st = ap.settings, ap.places[p.key];
    if (s[p.key] == '') then
        local place = core.narrow(st.learn, found, value);
        if (s.debug) then
            msg(('Learning %s: %d place(s) still match.'):fmt(p.what, core.count(st.learn.cands)));
        end
        if (place ~= nil) then
            s[p.key], st.misses = place, 0;
            msg(('Found %s.'):fmt(p.what));
        end
    elseif (found[s[p.key]]) then
        st.misses = 0;
    else
        st.misses = st.misses + 1;
        if (st.misses >= 2) then
            s[p.key], st.learn, st.misses = '', {}, 0;
            msg(('Lost track of %s; your next bids will find it again.'):fmt(p.what));
        end
    end
end

-- A bid reply: remember the price, and check (or learn) where the game keeps the box's values.
local function on_bid(price, id, qty)
    local s = ap.settings;
    local stack = qty > 1;
    ap.last = { id = id, stack = stack, price = price, row = ap.box_row };
    s.sel_ok = AshitaCore:GetMemoryManager():GetInventory():GetSelectedItemId() == id;
    if (s.debug) then
        msg(('Bid %s on %s%s.'):fmt(gil(price), item_name(id), stack and (' (stack of %d)'):fmt(qty) or ''));
    end

    local now, entry, found = os.clock(), nil, nil;
    for _, c in ipairs(ap.closed) do
        if (now - c.t <= RECENT and (#s.menus == 0 or price_menu(c.name))) then
            local f = core.find(c.snap, price);
            if (core.count(f) > 0) then
                entry, found = c, f;
                break;
            end
        end
    end
    if (entry == nil) then
        if (s.debug) then
            msg('No recent menu held that price.');
        end
        if (#s.menus > 0) then
            -- The bid box may have been renamed too (a client update): look at every menu again.
            ap.misses = ap.misses + 1;
            if (ap.misses >= 2) then
                s.menus, s.place, s.parents, ap.learn, ap.misses = T{}, '', T{}, {}, 0;
                msg('The bid box has changed (a client update?); your next two bids at different prices will find it.');
            end
        end
        settings.save();
        return;
    end
    if (#s.menus == 0) then
        table.insert(s.menus, entry.name);
        msg(('Found the bid box ("%s").'):fmt(entry.name));
    end
    if (entry.parent ~= nil and entry.parent ~= '' and not listed(s.parents, entry.parent)) then
        table.insert(s.parents, entry.parent);
    end

    if (s.place == '') then
        local place = core.narrow(ap.learn, found, price);
        if (place ~= nil) then
            s.place, ap.misses = place, 0;
            msg('Found where the bid box keeps its number again.');
        end
    elseif (found[s.place]) then
        ap.misses = 0;
    else
        ap.misses = ap.misses + 1;
        if (ap.misses >= 2) then
            s.place, ap.learn, ap.misses = '', {}, 0;
            msg('The bid box\'s number has moved (a client update?); your next two bids at different prices will find it.');
        end
    end

    -- The item and quantity can be in the box or in the menu it was opened from.
    local both = {};
    for k, v in pairs(entry.snap) do both[k] = v; end
    for k, v in pairs(entry.psnap or {}) do both[k] = v; end
    check_place(PLACES[1], core.find(both, id, 2), id);
    check_place(PLACES[2], core.find(both, qty, 1), qty);
    settings.save();
end

ashita.events.register('unload', 'bidcache_unload', function ()
    settings.save();
end);

settings.register('settings', 'bidcache_settings_update', function (s)
    if (s ~= nil) then
        ap.settings = s;
    end
    ap.learn, ap.misses = {}, 0;
    reset_places();
end);

--[[
* event: packet_in
* desc : 0x04C is the auction house's reply, also sent as it opens. For a bid (command 0x0E) it
*        echoes the price you entered at 0x08, the item at 0x0C, and 1 at 0x10 for a single or the
*        stack size for a stack, whether you won (result 0x01) or were outbid. Read only.
--]]
ashita.events.register('packet_in', 'bidcache_packet_in', function (e)
    if (e.id ~= 0x04C) then
        return;
    end
    ap.at_ah = true;
    if (e.size < 0x14 or e.data:byte(0x04 + 1) ~= 0x0E) then
        return;
    end
    local price = struct.unpack('I4', e.data, 0x08 + 1);
    local id = struct.unpack('H', e.data, 0x0C + 1);
    local qty = struct.unpack('I4', e.data, 0x10 + 1);
    if (core.valid_price(price) and id > 0 and id < 0xFFFF and qty >= 1 and qty <= 99) then
        on_bid(price, id, qty);
    end
end);

--[[
* event: d3d_present
* desc : Once a frame: watch the open menu.
--]]
ashita.events.register('d3d_present', 'bidcache_present', function ()
    local s = ap.settings;
    local name, obj, hdr = menu_info();
    local changed = name ~= ap.menu or obj ~= ap.obj;
    if (changed) then
        if (ap.menu ~= '' and ap.snap ~= nil) then
            table.insert(ap.closed, 1, { name = ap.menu, snap = ap.snap, psnap = ap.box_psnap,
                parent = ap.box_parent, t = os.clock() });
            ap.closed[5] = nil;
        end
        if (ap.menu ~= '' and ap.menu ~= name) then
            ap.parent, ap.parent_obj, ap.parent_hdr = ap.menu, ap.obj, ap.hdr;
            if (name ~= '' and not price_menu(ap.menu)) then
                ap.from[name] = { obj = ap.obj };
            end
        end
        ap.menu, ap.obj, ap.hdr = name, obj, hdr;
        if (name ~= '') then
            ap.seen[name] = { obj = obj, hdr = hdr };
        end
        ap.snap, ap.fill, ap.box_psnap, ap.box_parent = nil, nil, nil, nil;
        if (s.debug) then
            msg(('Menu "%s" (from "%s")%s.'):fmt(name, ap.parent, ap.at_ah and ', at the auction house' or ''));
        end
    end
    if (name == '') then
        ap.no_menu_since = ap.no_menu_since or os.clock();
        if (os.clock() - ap.no_menu_since >= AH_CLOSE_WAIT) then
            ap.at_ah, ap.parent, ap.parent_obj, ap.parent_hdr, ap.seen, ap.from = false, '', 0, 0, {}, {};
        end
        return;
    end
    ap.no_menu_since = nil;

    local box = price_menu(name);
    if (box or #s.menus == 0) then
        ap.snap = snapshot(obj, hdr) or ap.snap;
    end
    if (not s.enabled or not box) then
        return;
    end
    if (changed) then
        on_open();
        ap.dump = s.debug and 0 or nil;
    end
    if (ap.fill ~= nil) then
        fill_step();
    end
    if (ap.dump ~= nil) then
        ap.dump = ap.dump + 1;
        if (ap.dump == 3) then
            dump_box();
            ap.dump = nil;
        end
    end
end);

ashita.events.register('command', 'bidcache_command', function (e)
    local args = e.command:args();
    if (#args == 0 or not args[1]:any('/bidcache', '/bc')) then
        return;
    end
    e.blocked = true;
    local s = ap.settings;
    local cmd = (args[2] or ''):lower();

    if (cmd == 'on' or cmd == 'off') then
        s.enabled = cmd == 'on';
        settings.save();
        msg(('Filling the bid box %s.'):fmt(s.enabled and 'on' or 'off'));
    elseif (cmd == 'debug') then
        local v = (args[3] or ''):lower();
        s.debug = (v == '') and not s.debug or v == 'on';
        settings.save();
        msg(('Debug %s.'):fmt(s.debug and 'on' or 'off'));
    elseif (cmd == 'price') then
        local n = tonumber(args[3] or '');
        if (n == 0) then
            ap.last = nil;
            msg('Forgot the last bid: the box opens at 0.');
        elseif (core.valid_price(n)) then
            local l = ap.last or {};
            ap.last = { id = l.id, stack = l.stack, row = l.row, price = n };
            msg(('The box opens at %s for %s.'):fmt(gil(n), l.id ~= nil and item_name(l.id) or 'the next item you bid on'));
        else
            msg(('/bidcache price <0-%s>   0 forgets the last bid'):fmt((gil(core.MAX_PRICE):gsub(' gil', ''))));
        end
    elseif (cmd == 'relearn') then
        s.menus, s.place, s.parents, s.item_place, s.qty_place, s.sel_ok = T{}, '', T{}, '', '', false;
        ap.learn, ap.misses = {}, 0;
        reset_places();
        settings.save();
        msg('Forgot where everything is; your next bids at the auction house will find it again.');
    else
        local item = s.item_place ~= '' and 'found' or (s.sel_ok and 'using the selected item' or 'not found yet');
        msg(('Bid box %s; its item %s; stack or single %s.'):fmt(s.place ~= '' and 'found' or 'not found yet',
            item, s.qty_place ~= '' and 'found' or 'not found yet'));
        local l = ap.last;
        msg(l == nil and 'No last bid: the box opens at 0.' or ('Last bid %s on %s%s.'):fmt(gil(l.price),
            l.id ~= nil and item_name(l.id) or 'the next item', l.stack and ' (stack)' or ''));
        msg('/bidcache on|off            fill the bid box (now ' .. (s.enabled and 'on' or 'off') .. ')');
        msg('/bidcache price <n>         set the price the box opens at (0 forgets it)');
        msg('/bidcache relearn           find the bid box and its item again');
        msg('/bidcache debug [on|off]    print menu names and what learning finds');
    end
end);
