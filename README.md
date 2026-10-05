# bidcache

Ashita v4 addon: remembers the last price you entered in the auction house's bid box and writes
it straight back into the box the next time it opens, on any listing, so you can press Enter at
once instead of building the number up from 0 with the arrows again. No keys are pressed.

- **The price** comes from the auction house's reply to each bid (incoming packet 0x04C,
  command 0x0E), which echoes what you entered, won or outbid. It's saved, so it carries over
  between sessions.
- **The box** is the game's `moneyctr` menu. Its number sits at +40 in the object that a pointer
  at +12 of the menu points to, and bidcache writes the price there as the box opens (only while
  the box still reads 0). That location is built in, so nothing has to be learned. If a client
  update ever moves it (or renames the box), bidcache notices: every bid is checked against
  the box's memory, a bid that doesn't match stops the writing, and a second one makes it find
  the box again from your next two bids at different prices.
- **Only at the auction house.** The same box is used for trading gil and setting prices, so it's
  only filled after the auction house has sent something since every menu was last closed, and,
  once your first bid has shown which menu you bid from, only when opened from that menu.

Nothing is sent to the server and no packet is changed: bidcache reads incoming packets and
client memory, and writes only the bid box's own number.

## Commands

    /addon load bidcache
    /bidcache (or /bc)          status and help
    /bidcache on|off             fill the bid box or not
    /bidcache price <n>          set the price the box opens at
    /bidcache relearn            find the bid box again
    /bidcache debug [on|off]     print menu names and what learning finds

## Tests

    python tests/test_core.py   place finding, under LuaJIT via lupa
    python -c "from lupa import luajit21; r=luajit21.LuaRuntime(); r.execute(\"package.path='./?.lua;'..package.path\"); r.execute(open('tests/smoke.lua').read())"
