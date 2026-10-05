--[[
* bidcache - core
* The price book, and finding things in the game's menu memory, kept free of Ashita so they can
* be tested on their own.
*
* Each frame the addon copies the open menus' memory (a snapshot). When the auction house replies
* to a bid, the price you entered, the item and whether it was a stack are known, so every place
* in the snapshot that held one of those is a candidate for where the game keeps it. Bids with
* different values narrow the candidates down to one.
--]]

local core = {};

core.MAX_PRICE = 999999999;

function core.valid_price(p)
    return type(p) == 'number' and p >= 1 and p <= core.MAX_PRICE and p == math.floor(p);
end

--[[ Price book ]]

--[[
* prices: { [tostring(item id)] = { single = n, stack = n } }; the latest bid on each kind wins.
--]]
function core.record(prices, id, stack, price)
    if (type(id) ~= 'number' or id <= 0 or id >= 0xFFFF or not core.valid_price(price)) then
        return false;
    end
    local key = tostring(id);
    local e = prices[key] or {};
    e[stack and 'stack' or 'single'] = price;
    prices[key] = e;
    return true;
end

--[[
* The price to put in the box for an item, or nil to leave it at 0. stack is true or false when
* the game says which kind the bid is for, nil when it doesn't. Not knowing, only a single's
* price is used, and only when it's the only one saved: in a stack's box that just bids too
* little, while a stack's price in a single's box would pay far too much.
--]]
function core.lookup(prices, id, stack)
    local e = id ~= nil and prices[tostring(id)] or nil;
    if (e == nil) then
        return nil;
    end
    if (stack == true) then
        return e.stack;
    elseif (stack == false) then
        return e.single;
    elseif (e.stack == nil) then
        return e.single;
    end
    return nil;
end

function core.forget(prices, id)
    local key = tostring(id);
    local had = prices[key] ~= nil;
    prices[key] = nil;
    return had;
end

--[[ Finding things in menu memory ]]

local function u32(s, o)
    local a, b, c, d = s:byte(o + 1, o + 4);
    return a + b * 256 + c * 65536 + d * 16777216;
end
core.u32 = u32;

-- The width-byte (1, 2 or 4) little-endian value at offset o of s.
function core.value(s, o, width)
    if (width == 1) then
        return s:byte(o + 1);
    elseif (width == 2) then
        local a, b = s:byte(o + 1, o + 2);
        return a + b * 256;
    end
    return u32(s, o);
end

--[[
* snap: { [region] = bytes } where region is 'v' (the menu object), 'h' (its header), or 'v@<off>'
* (the object a pointer at that offset in the menu object points to), each optionally prefixed
* with 'p:' for the menu the bid box was opened from.
* Returns a set { ['<region>|<offset>'] = true } of the places holding value, as width-byte
* (default 4) values aligned to their width.
--]]
function core.find(snap, value, width)
    width = width or 4;
    local out = {};
    for region, data in pairs(snap) do
        for o = 0, #data - width, width do
            if (core.value(data, o, width) == value) then
                out[region .. '|' .. o] = true;
            end
        end
    end
    return out;
end

local function count(set)
    local n = 0;
    for _ in pairs(set) do
        n = n + 1;
    end
    return n;
end
core.count = count;

--[[
* Narrows the candidates with a bid whose snapshot held its value (price, item...) at found.
* learn: { cands = set or nil, prices = { [value] = true } }. Returns the place once only one is
* left after bids with two or more different values, else nil.
--]]
function core.narrow(learn, found, price)
    if (learn.cands == nil) then
        learn.cands, learn.prices = found, { [price] = true };
    else
        local keep = {};
        for k in pairs(learn.cands) do
            if (found[k]) then
                keep[k] = true;
            end
        end
        if (count(keep) == 0) then
            -- Nothing survived (a different box, or the client moved things): start over from this bid.
            learn.cands, learn.prices = found, { [price] = true };
        else
            learn.cands = keep;
            learn.prices[price] = true;
        end
    end
    if (count(learn.prices) >= 2 and count(learn.cands) == 1) then
        return (next(learn.cands));
    end
    return nil;
end

-- '<region>|<offset>' -> region, offset
function core.parse(place)
    local region, off = tostring(place):match('^(.-)|(%d+)$');
    return region, tonumber(off);
end

return core;
