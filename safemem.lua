--[[
* bidcache - safemem (from scouter)
* Reads the game's memory without touching it: ReadProcessMemory on our own process, which fails
* cleanly on an address the game has freed or never mapped, where a direct read (ashita.memory's
* read_*) takes the whole client down with no message. Pointer chains into game objects that come
* and go (menus) must be read this way.
--]]

local ffi = require('ffi');

local safemem = {
    rpm = nil,   -- (tests) stands in for ReadProcessMemory: function (addr, n) -> string or nil
};

local win = nil;
local function kernel()
    if (win == nil) then
        pcall(ffi.cdef, [[
            void* __stdcall GetCurrentProcess(void);
            int __stdcall ReadProcessMemory(void* process, const void* address, void* buffer, size_t size, size_t* read);
        ]]);
        win = { buf = ffi.new('uint8_t[4096]'), got = ffi.new('size_t[1]'), process = ffi.C.GetCurrentProcess() };
    end
    return win;
end

-- n (1-4096) bytes at addr as a string, or nil when any of them can't be read.
function safemem.read(addr, n)
    if (type(addr) ~= 'number' or addr < 0x10000 or addr >= 0x100000000 or n < 1 or n > 4096) then
        return nil;
    end
    if (safemem.rpm ~= nil) then
        return safemem.rpm(addr, n);
    end
    local ok, s = pcall(function ()
        local k = kernel();
        if (ffi.C.ReadProcessMemory(k.process, ffi.cast('const void*', addr), k.buf, n, k.got) == 0 or tonumber(k.got[0]) ~= n) then
            return nil;
        end
        return ffi.string(k.buf, n);
    end);
    return ok and s or nil;
end

function safemem.u32(addr)
    local s = safemem.read(addr, 4);
    if (s == nil) then
        return nil;
    end
    local a, b, c, d = s:byte(1, 4);
    return a + b * 256 + c * 65536 + d * 16777216;
end

function safemem.float(addr)
    local s = safemem.read(addr, 4);
    if (s == nil) then
        return nil;
    end
    local f = ffi.new('float[1]');
    ffi.copy(f, s, 4);
    return tonumber(f[0]);
end

return safemem;
