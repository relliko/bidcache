--[[
* bidcache - core
* Finding where the bid box keeps its number, kept free of Ashita so it can be tested on its own.
*
* Each frame the addon copies the open menu's memory (a snapshot). When the auction house replies
* to a bid, the price you entered is known, so every place in the bid box's last snapshot that
* held that number is a candidate. Bids at different prices narrow the candidates down to one.
--]]

local core = {};

core.MAX_PRICE = 999999999;

function core.valid_price(p)
    return type(p) == 'number' and p >= 1 and p <= core.MAX_PRICE and p == math.floor(p);
end

--[[ Finding the box's number ]]

local function u32(s, o)
    local a, b, c, d = s:byte(o + 1, o + 4);
    return a + b * 256 + c * 65536 + d * 16777216;
end
core.u32 = u32;

--[[
* snap: { [region] = bytes } where region is 'v' (the menu object), 'h' (its header), or 'v@<off>'
* (the object a pointer at that offset in the menu object points to).
* Returns a set { ['<region>|<offset>'] = true } of the 4-byte-aligned places holding price.
--]]
function core.find(snap, price)
    local out = {};
    for region, data in pairs(snap) do
        for o = 0, #data - 4, 4 do
            if (u32(data, o) == price) then
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
* Narrows the candidates with a bid at price whose snapshot held price at found.
* learn: { cands = set or nil, prices = { [price] = true } }. Returns the place once only one is
* left after bids at two or more different prices, else nil.
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
