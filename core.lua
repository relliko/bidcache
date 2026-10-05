--[[
* bidcache - core
* The remembered bid, and finding things in the game's menu memory, kept free of Ashita so they can
* be tested on their own.
*
* Each frame the addon copies the open menus' memory (a snapshot). When the auction house replies
* to a bid, the price you entered, the item and whether it was a stack are known, so every place
* in the snapshot that held one of those is a candidate for where the game keeps it. Bids with
* different values narrow the candidates down to one.
--]]

local core = {};

core.MAX_PRICE = 99999999; -- the bid box has eight digits

function core.valid_price(p)
    return type(p) == 'number' and p >= 1 and p <= core.MAX_PRICE and p == math.floor(p);
end

--[[ The remembered bid ]]

--[[
* last: { id = item id (nil: whichever item the next box is for), stack = true/false/nil, price }.
* The price to put in a box for item id (stack: true or false when the game says which kind the
* box is for, nil when it doesn't), and whether the remembered bid should be wiped because the
* box is for a different item. Not knowing the box's kind, a stack's price is never used: in a
* single's box it would pay far too much.
--]]
function core.match(last, id, stack)
    if (last == nil or id == nil) then
        return nil, false;
    end
    if (last.id ~= nil and last.id ~= id) then
        return nil, true;
    end
    if (stack ~= nil and last.stack ~= nil and stack ~= last.stack) then
        return nil, true;
    end
    if (stack == nil and last.stack == true) then
        return nil, false;
    end
    return last.price, false;
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
