# bidcache

Ashita v4 addon: remembers your last auction house bid and writes its price straight back into
the bid box when you bid on the same item again, so you can press Enter at once instead of
building the number up from 0 with the arrows again. No keys are pressed.

- **One bid, only while the game runs.** Opening the bid box for a different item, or for the
  other kind (a single after a stack, or a stack after a single), forgets it and leaves the box
  at 0, so a big price never lands on a cheap item. Prices are never saved to disk.
- **The bid** comes from the auction house's reply (incoming packet 0x04C, command 0x0E), which
  echoes the price you entered, the item and the quantity, won or outbid.
- **The box** is the game's `moneyctr` menu. Its number sits at +40 in the object that a pointer
  at +12 of the menu points to, and bidcache writes the price there as the box opens (only while
  the box still reads 0). That location is built in.
- **Which item the box is for**, and whether it's a stack, are read from the game's memory too.
  Where the game keeps them is found from your bids: every place in the box's memory (and the
  menu it was opened from) that held the item you bid on is a candidate, and bids on two
  different items narrow it to one; a bid on a single and one on a stack do the same for the
  quantity. Until the item's place is found, the game's selected item is used, once a bid has
  shown it matches. A box whose item can't be told is left at 0.
- **Singles and stacks.** Until bidcache can tell which the box is for, a stack's price is never
  filled: in a single's box it would pay far too much.
- **Kept up to date.** Every bid checks each of these places. One that doesn't match stops being
  used straight away, and a second miss makes bidcache find it again from your next bids, in
  case a client update moves something or renames the box. Where they are is the only thing
  bidcache saves.
- **Only at the auction house.** The same box is used for trading gil and setting prices, so it's
  only filled after the auction house has sent something since every menu was last closed, and,
  once a bid has shown which menu you bid from, only when opened from that menu.

Nothing is sent to the server and no packet is changed: bidcache reads incoming packets and
client memory, and writes only the bid box's own number.

## Commands

    /addon load bidcache
    /bidcache (or /bc)          the last bid, what's been found so far, and help
    /bidcache on|off            fill the bid box or not
    /bidcache price <n>         the price the box opens at, 0 to 99,999,999; 0 forgets the last
                                bid. With no bid behind it, it's for the next item you bid on
    /bidcache relearn           find the bid box and its item again
    /bidcache debug [on|off]    print menu names, each box's item, and what learning finds

## Tests

    python tests/test_core.py   the last bid and place finding, under LuaJIT via lupa
    python -c "from lupa import luajit21; r=luajit21.LuaRuntime(); r.execute(\"package.path='./?.lua;'..package.path\"); r.execute(open('tests/smoke.lua').read())"
