# bidcache

Ashita v4 addon: remembers your last auction house bid and writes its price straight back into
the bid box when you bid on the same item again, so you can press Enter at once instead of
building the number up from 0 with the arrows again. No keys are pressed.

- **One bid, only while the game runs.** Opening the bid box for a different listing forgets it
  and leaves the box at 0, so a big price never lands on a cheap item. A single and a stack of
  the same item are different rows of the auction list, and the list keeps the row you picked
  (at +0x4C of the list menu), so switching between them counts as a different listing. Prices
  are never saved to disk.
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

## Selling

The same goes for listings: sell an item and its price goes back in the sell price box the next
time you sell that item. Selling a different item forgets it. Nothing is saved to disk.

- **The listing** comes from what you ask the auction house (outgoing packet 0x04E, command
  0x04: the price you typed, the item, its inventory slot, single or stack). It's kept once the
  auction house says the item is up (incoming 0x04C, command 0x0B, result 1); a failed listing
  is ignored.
- **The sell price box** is the same `moneyctr` box, opened from a different menu. That menu is
  learned from your first listing; a box opened from it only ever gets a listing's price, never
  a bid's, and the bid box never gets a listing's price.
- **Which item** is the game's selected item, once a listing has shown it matches.
- **Singles and stacks.** A slot holding less than a full stack (or an item that doesn't stack)
  can only be sold as a single. A full stack could be either, so there a single's price is never
  filled (it would sell the whole stack far too cheap), while a stack's price is (at worst a
  single asks too much, and you see it before agreeing to the fee).

Nothing is sent to the server and no packet is changed: bidcache reads packets and client
memory, and writes only the price box's own number.

## Commands

    /addon load bidcache
    /bidcache (or /bc)          the last bid and listing, what's been found so far, and help
    /bidcache on|off            fill the bid box or not
    /bidcache price <n>         the price the box opens at, 0 to 99,999,999; 0 forgets the last
                                bid. With no bid behind it, it's for the next item you bid on
    /bidcache relearn           find the bid box, its item and the sell price box again
    /bidcache debug [on|off]    print menu names, each box's item and list row, and what
                                learning finds; also saves the bid box's memory to files in
                                bidcache's settings folder each time it opens

## Tests

    python tests/test_core.py   the last bid and place finding, under LuaJIT via lupa
    python -c "from lupa import luajit21; r=luajit21.LuaRuntime(); r.execute(\"package.path='./?.lua;'..package.path\"); r.execute(open('tests/smoke.lua').read())"
