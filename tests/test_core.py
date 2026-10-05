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


class LastBidTests(unittest.TestCase):
    def setUp(self):
        self.lua, self.core = runtime()
        self.match = self.lua.eval("function (c, last, id, stack, row) local p, w = c.match(last, id, stack, row) return {p, w} end")

    def last(self, id, stack, price):
        t = self.lua.eval("{}")
        t['id'], t['stack'], t['price'] = id, stack, price
        return t

    def m(self, last, id, stack=None, row=None):
        r = self.match(self.core, last, id, stack, row)
        return r[1], r[2]

    def test_same_item(self):
        self.assertEqual(self.m(self.last(4096, False, 1500), 4096, False), (1500, False))
        self.assertEqual(self.m(self.last(4096, False, 1500), 4096), (1500, False))

    def test_other_item_wipes(self):
        self.assertEqual(self.m(self.last(4096, False, 1500), 17), (None, True))

    def test_other_kind_wipes(self):
        self.assertEqual(self.m(self.last(4096, False, 1500), 4096, True), (None, True))
        self.assertEqual(self.m(self.last(4096, True, 20000), 4096, False), (None, True))
        self.assertEqual(self.m(self.last(4096, True, 20000), 4096, True), (20000, False))

    def test_stack_price_never_used_when_kind_unknown(self):
        self.assertEqual(self.m(self.last(4096, True, 20000), 4096), (None, False))

    def test_unknown_box_item_keeps_it(self):
        self.assertEqual(self.m(self.last(4096, False, 1500), None), (None, False))

    def test_price_for_any_item(self):
        self.assertEqual(self.m(self.last(None, None, 800), 17, True), (800, False))

    def test_nothing_remembered(self):
        self.assertEqual(self.m(None, 4096), (None, False))

    def test_other_row_wipes(self):
        last = self.last(4096, None, 1500)
        last['row'] = 1
        self.assertEqual(self.m(last, 4096, None, 1), (1500, False))
        self.assertEqual(self.m(last, 4096, None, 2), (None, True))
        self.assertEqual(self.m(last, 4096, None, None), (None, False))

    def test_price_range(self):
        self.assertTrue(self.core.valid_price(99999999))
        self.assertFalse(self.core.valid_price(100000000))
        self.assertFalse(self.core.valid_price(0))

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
