"""Tests for bidcache's price book and place finding (core.lua), run under LuaJIT via lupa.

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


class PriceBookTests(unittest.TestCase):
    def setUp(self):
        self.lua, self.core = runtime()
        self.prices = self.lua.eval("{}")

    def look(self, id, stack=None):
        return self.core.lookup(self.prices, id, stack)

    def test_single(self):
        self.assertTrue(self.core.record(self.prices, 4096, False, 1500))
        self.assertEqual(self.look(4096, False), 1500)
        self.assertEqual(self.look(4096), 1500)
        self.assertIsNone(self.look(4096, True))

    def test_latest_wins(self):
        self.core.record(self.prices, 4096, False, 1500)
        self.core.record(self.prices, 4096, False, 1800)
        self.assertEqual(self.look(4096, False), 1800)

    def test_stack_price_never_used_when_kind_unknown(self):
        self.core.record(self.prices, 4096, True, 20000)
        self.assertIsNone(self.look(4096))
        self.assertEqual(self.look(4096, True), 20000)
        self.core.record(self.prices, 4096, False, 1500)
        self.assertIsNone(self.look(4096))
        self.assertEqual(self.look(4096, False), 1500)

    def test_unknown_item(self):
        self.assertIsNone(self.look(17))
        self.assertIsNone(self.look(None))

    def test_rejects_bad_bids(self):
        self.assertFalse(self.core.record(self.prices, 4096, False, 0))
        self.assertFalse(self.core.record(self.prices, 0, False, 100))
        self.assertFalse(self.core.record(self.prices, 0xFFFF, False, 100))

    def test_forget(self):
        self.core.record(self.prices, 4096, False, 1500)
        self.assertTrue(self.core.forget(self.prices, 4096))
        self.assertIsNone(self.look(4096))
        self.assertFalse(self.core.forget(self.prices, 4096))

    def test_find_widths(self):
        data = bytes([0x10, 0x00, 12, 1, 0xE8, 0x03, 0, 0])
        t = self.lua.eval("{}")
        t['v'] = data
        keys = self.lua.eval("function (t) local o = {} for k in pairs(t) do o[#o + 1] = k end table.sort(o) return o end")
        self.assertEqual(list(keys(self.core.find(t, 16, 2)).values()), ['v|0'])
        self.assertEqual(list(keys(self.core.find(t, 12, 1)).values()), ['v|2'])
        self.assertEqual(list(keys(self.core.find(t, 1000, 2)).values()), ['v|4'])
        self.assertEqual(list(keys(self.core.find(t, 1000)).values()), ['v|4'])


if __name__ == '__main__':
    unittest.main()
