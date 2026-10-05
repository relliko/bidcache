"""Tests for bidcache's place finding (core.lua), run under LuaJIT via lupa.

    python tests/test_core.py
"""
import os
import struct
import unittest

from lupa import luajit21

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.dirname(HERE)

def runtime():
    lua = luajit21.LuaRuntime()
    lua.execute(f"package.path = [[{ADDON}]] .. '/?.lua;' .. package.path")
    return lua, lua.eval("require('core')")


def snap(lua, regions):
    t = lua.eval("{}")
    for k, v in regions.items():
        t[k] = v
    return t


def mem(*words):
    return b''.join(struct.pack('<I', w) for w in words)


class FindTests(unittest.TestCase):
    def setUp(self):
        self.lua, self.core = runtime()
        self.keys = self.lua.eval("function (t) local o = {} for k in pairs(t) do o[#o + 1] = k end table.sort(o) return o end")

    def found(self, regions, price):
        return list(self.keys(self.core.find(snap(self.lua, regions), price)).values())

    def test_finds_aligned_words(self):
        self.assertEqual(self.found({'v': mem(7, 300, 0, 300), 'v@16': mem(300)}, 300), ['v@16|0', 'v|12', 'v|4'])

    def test_narrows_to_one_place_over_two_prices(self):
        learn = self.lua.eval("{}")
        f1 = self.core.find(snap(self.lua, {'v': mem(0, 300, 300, 1)}), 300)
        self.assertIsNone(self.core.narrow(learn, f1, 300))
        f2 = self.core.find(snap(self.lua, {'v': mem(0, 450, 300, 1)}), 450)
        self.assertEqual(self.core.narrow(learn, f2, 450), 'v|4')

    def test_same_price_twice_is_not_enough(self):
        learn = self.lua.eval("{}")
        f = self.core.find(snap(self.lua, {'v': mem(0, 300)}), 300)
        self.assertIsNone(self.core.narrow(learn, f, 300))
        self.assertIsNone(self.core.narrow(learn, f, 300))

    def test_starts_over_when_nothing_survives(self):
        learn = self.lua.eval("{}")
        self.core.narrow(learn, self.core.find(snap(self.lua, {'v': mem(300)}), 300), 300)
        self.assertIsNone(self.core.narrow(learn, self.core.find(snap(self.lua, {'h': mem(0, 450)}), 450), 450))
        self.assertEqual(self.core.narrow(learn, self.core.find(snap(self.lua, {'h': mem(0, 600)}), 600), 600), 'h|4')

    def test_parse(self):
        r = self.lua.eval("function (c, p) local a, b = c.parse(p) return {a, b} end")(self.core, 'v@24|8')
        self.assertEqual((r[1], r[2]), ('v@24', 8))


if __name__ == '__main__':
    unittest.main()
