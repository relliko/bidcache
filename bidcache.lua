--[[
* bidcache
*
* Remembers the last price you entered in the auction house's bid box and writes it straight back
* into the box the next time it opens, so you can press Enter at once instead of building the
* number up from 0 with the arrows again.
*
* - The price comes from the auction house's reply to a bid (incoming packet 0x04C, command 0x0E),
*   which echoes the price you entered, whether the bid won or not.
* - The box is the game's 'moneyctr' menu, and its number sits at +40 in the object a pointer at
*   +12 of the menu points to. That's the default; if a client update moves it, bidcache finds it
*   again by itself from your bids (see core.narrow), with no keys pressed.
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
addon.version = '0.3';
addon.desc    = 'Puts your last auction house bid price back in the bid box.';
addon.link    = 'https://github.com/relliko/bidcache';

require('common');
local chat     = require('chat');
local settings = require('settings');
local core     = require('core');
local safemem  = require('safemem');

local defaults = T{
    enabled = true,
    menus = T{ 'moneyctr' }, -- the bid box's menu name(s); learned from a bid if empty
    place = 'v@12|40',       -- where the box keeps its number ('<region>|<offset>'); relearned if it moves
    parents = T{},           -- menus the bid box has been opened from; learned from your bids
    last_price = 0,
    debug = false,           -- print menu changes and what learning finds
};

local OBJ_SIZE, HDR_SIZE, CHILD_SIZE, MAX_CHILDREN = 0x400, 0x200, 0x100, 64;
local RECENT = 5;        -- seconds a closed menu's copy is kept for matching a bid reply
local AH_CLOSE_WAIT = 1; -- seconds with no menu open before the auction house counts as left

local ap = {
    settings = settings.load(defaults),
    menu = '', obj = 0, hdr = 0,
    snap = nil,       -- copy of the open menu, see core.find
    closed = {},      -- { name, snap, t } of recently closed menus, newest first
    learn = {},       -- see core.narrow
    misses = 0,       -- bid replies the place didn't match
    fill = nil,       -- { polls, writes } while writing the price into the box
    at_ah = false,    -- the auction house has sent something since every menu was last closed
    no_menu_since = nil,
    parent = '',      -- the menu open before the current one
    box_parent = nil, -- the menu the bid box was last opened from
};

local function msg(text)
    print(chat.header(addon.name):append(chat.message(text)));
end

local function gil(n)
    local s = tostring(n):reverse():gsub('(%d%d%d)', '%1,'):reverse();
    return (s:gsub('^,', '')) .. ' gil';
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

-- A copy of the menu object, its header, and what the object's pointers point to.
local function snapshot(obj, hdr)
    local snap = {};
    local o = safemem.read(obj, OBJ_SIZE);
    if (o == nil) then
        return nil;
    end
    snap.v = o;
    snap.h = safemem.read(hdr, HDR_SIZE);
    local n = 0;
    for off = 8, OBJ_SIZE - 4, 4 do
        local p = core.u32(o, off);
        if (looks_like_ptr(p) and p ~= hdr and p ~= obj) then
            local c = safemem.read(p, CHILD_SIZE);
            if (c ~= nil) then
                snap['v@' .. off] = c;
                n = n + 1;
                if (n >= MAX_CHILDREN) then
                    break;
                end
            end
        end
    end
    return snap;
end

-- The address of a place in the open menu, or nil.
local function resolve(place, obj, hdr)
    local region, off = core.parse(place);
    if (region == 'v') then
        return obj + off;
    elseif (region == 'h') then
        return hdr + off;
    end
    local poff = region ~= nil and tonumber(region:match('^v@(%d+)$'));
    local p = poff ~= nil and safemem.u32(obj + poff) or nil;
    if (p == nil or not looks_like_ptr(p)) then
        return nil;
    end
    return p + off;
end

-- The bid box just opened: fill it if it's the auction house's.
local function on_open()
    local s = ap.settings;
    ap.box_parent = ap.parent;
    -- After a bid that didn't match the place, nothing is written until it's confirmed or found again.
    if (not core.valid_price(s.last_price) or s.place == '' or not ap.at_ah or ap.misses > 0) then
        return;
    end
    if (#s.parents > 0 and not listed(s.parents, ap.parent)) then
        if (s.debug) then
            msg(('Not filling: opened from "%s", not a menu you\'ve bid from.'):fmt(ap.parent));
        end
        return;
    end
    ap.fill = { polls = 0, writes = 0 };
end

-- Writes the price into the open box while it still reads 0 (the box may zero itself as it opens).
local function fill_step()
    local f, s = ap.fill, ap.settings;
    f.polls = f.polls + 1;
    if (f.polls < 2) then
        return;
    end
    local addr = resolve(s.place, ap.obj, ap.hdr);
    local cur = addr ~= nil and safemem.u32(addr) or nil;
    if (cur == 0 and f.writes < 3) then
        ashita.memory.write_uint32(addr, s.last_price);
        f.writes = f.writes + 1;
    elseif (cur == s.last_price and f.writes > 0) then
        if (s.debug) then
            msg(('Set the box to %s.'):fmt(gil(s.last_price)));
        end
        ap.fill = nil;
    else
        -- Gone, or holding something else (you changed it): leave it alone.
        ap.fill = nil;
    end
end

-- A bid reply: remember the price, and check the bid box's last copy still keeps it at the place.
local function on_bid(price)
    local s = ap.settings;
    s.last_price = price;

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
            msg(('Bid of %s: no recent menu held that number.'):fmt(gil(price)));
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
    if (ap.box_parent ~= nil and ap.box_parent ~= '' and not listed(s.parents, ap.box_parent)) then
        table.insert(s.parents, ap.box_parent);
    end

    if (s.place == '') then
        local place = core.narrow(ap.learn, found, price);
        if (s.debug) then
            msg(('Bid of %s: %d place(s) in "%s" still match.'):fmt(gil(price), core.count(ap.learn.cands), entry.name));
        end
        if (place ~= nil) then
            s.place = place;
            ap.misses = 0;
            msg('Found where the bid box keeps its number again: it fills in as the box opens.');
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
end);

--[[
* event: packet_in
* desc : 0x04C is the auction house's reply, also sent as it opens. For a bid (command 0x0E) it
*        echoes the price you entered at 0x08, whether you won (result 0x01) or were outbid.
*        Read only.
--]]
ashita.events.register('packet_in', 'bidcache_packet_in', function (e)
    if (e.id ~= 0x04C) then
        return;
    end
    ap.at_ah = true;
    if (e.size < 0x0C or e.data:byte(0x04 + 1) ~= 0x0E) then
        return;
    end
    local price = struct.unpack('I4', e.data, 0x08 + 1);
    if (core.valid_price(price)) then
        on_bid(price);
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
            table.insert(ap.closed, 1, { name = ap.menu, snap = ap.snap, t = os.clock() });
            ap.closed[5] = nil;
        end
        if (ap.menu ~= '' and ap.menu ~= name) then
            ap.parent = ap.menu;
        end
        ap.menu, ap.obj, ap.hdr = name, obj, hdr;
        ap.snap, ap.fill = nil, nil;
        if (s.debug) then
            msg(('Menu "%s" (from "%s")%s.'):fmt(name, ap.parent, ap.at_ah and ', at the auction house' or ''));
        end
    end
    if (name == '') then
        ap.no_menu_since = ap.no_menu_since or os.clock();
        if (os.clock() - ap.no_menu_since >= AH_CLOSE_WAIT) then
            ap.at_ah, ap.parent = false, '';
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
    end
    if (ap.fill ~= nil) then
        fill_step();
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
        if (not core.valid_price(n)) then
            msg('/bidcache price <1-999999999>');
            return;
        end
        s.last_price = n;
        settings.save();
        msg(('Next bid box opens at %s.'):fmt(gil(n)));
    elseif (cmd == 'relearn') then
        s.menus, s.place, s.parents, ap.learn, ap.misses = T{}, '', T{}, {}, 0;
        settings.save();
        msg('Forgot the bid box; your next two bids at different prices will find it again.');
    else
        local how = s.place ~= '' and 'fills as it opens' or 'not found: make two bids at different prices';
        msg(('Last price %s; bid box %s.'):fmt(core.valid_price(s.last_price) and gil(s.last_price) or 'none yet', how));
        msg('/bidcache on|off            fill the bid box (now ' .. (s.enabled and 'on' or 'off') .. ')');
        msg('/bidcache price <n>         set the price the box opens at');
        msg('/bidcache relearn           find the bid box again');
        msg('/bidcache debug [on|off]    print menu names and what learning finds');
    end
end);
