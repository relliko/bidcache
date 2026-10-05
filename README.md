# bidcache

Ashita v4 addon: remembers what you last bid on each item at the auction house, singles and
stacks apart, and writes it straight back into the bid box the next time you bid on that item,
so you can press Enter at once instead of building the number up from 0 with the arrows again.
Items you haven't bid on yet open at 0 as usual. No keys are pressed.

- **Prices** come from the auction house's reply to each bid (incoming packet 0x04C,
  command 0x0E), which echoes the price you entered, the item and the quantity, won or outbid.
  They're saved per character, so they carry over between sessions.
- **The box** is the game's `moneyctr` menu. Its number sits at +40 in the object that a pointer
  at +12 of the menu points to, and bidcache writes the price there as the box opens (only while
  the box still reads 0). That location is built in.
- **Which item the box is for**, and whether it's a stack, are read from the game's memory too.
  Where the game keeps them is found from your bids: every place in the box's memory (and the
  menu it was opened from) that held the item you bid on is a candidate, and bids on two
  different items narrow it to one; a bid on a single and one on a stack do the same for the
  quantity. Until the item's place is found, the game's selected item is used, once a bid has
  shown it matches.
- **Singles and stacks.** Until bidcache can tell which the box is for, only a single's price is
  filled, and only for an item you've never bid on as a stack: in a stack's box a single's price
  just bids too little, while a stack's price in a single's box would pay far too much.
- **Kept up to date.** Every bid checks each of these places. One that doesn't match stops being
  used straight away, and a second miss makes bidcache find it again from your next bids, in
  case a client update moves something or renames the box.
- **Only at the auction house.** The same box is used for trading gil and setting prices, so it's
  only filled after the auction house has sent something since every menu was last closed, and,
  once a bid has shown which menu you bid from, only when opened from that menu.

Nothing is sent to the server and no packet is changed: bidcache reads incoming packets and
client memory, and writes only the bid box's own number.

## Commands

    /addon load bidcache
    /bidcache (or /bc)          what's been found so far, and help
    /bidcache on|off            fill the bid box or not
    /bidcache list              prices saved for each item
    /bidcache forget <item>     drop an item's prices (item id or name)
    /bidcache relearn           find the bid box and its item again
    /bidcache debug [on|off]    print menu names, each box's item, and what learning finds

## Tests

    python tests/test_core.py   price book and place finding, under LuaJIT via lupa
    python -c "from lupa import luajit21; r=luajit21.LuaRuntime(); r.execute(\"package.path='./?.lua;'..package.path\"); r.execute(open('tests/smoke.lua').read())"
