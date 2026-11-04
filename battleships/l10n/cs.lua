-- Czech translation of the plugin's strings (msgid → translation), see battleships/l10n.lua.
-- tests/run.lua checks that every _("…") in main.lua has an entry here.
return {
    -- menu
    ["Battleships"] = "Lodě",
    ["Host a game"] = "Založit hru",
    ["Find a game"] = "Najít hru",
    ["Join by address…"] = "Připojit se podle adresy…",
    ["Your name: %1"] = "Vaše jméno: %1",
    ["Your name"] = "Vaše jméno",
    ["Shown to the other player and in the list of games."] = "Zobrazí se druhému hráči a v seznamu her.",
    ["Player"] = "Hráč",
    ["Save"] = "Uložit",
    ["Rules"] = "Pravidla",
    [ [[Each player has a fleet of five ships (5, 4, 3, 3 and 2 squares) on a 10 × 10 board. Ships may not touch, not even at the corners.

Players take turns firing at a square of the opponent's board. After a hit you fire again, after a miss it's the opponent's turn. Whoever sinks the whole enemy fleet first wins.

Both devices must be on the same Wi-Fi network. One player hosts the game, the other finds it in Find a game or joins by the address shown on the host's screen.]] ] =
        [[Každý hráč má na plánu 10 × 10 flotilu pěti lodí (5, 4, 3, 3 a 2 pole). Lodě se nesmějí dotýkat, ani rohem.

Hráči se střídají ve střelbě na pole soupeřova plánu. Po zásahu střílíte znovu, po minutí je na tahu soupeř. Kdo první potopí celou nepřátelskou flotilu, vyhrává.

Obě zařízení musí být ve stejné síti Wi-Fi. Jeden hráč hru založí, druhý ji najde v Najít hru nebo se připojí podle adresy zobrazené na obrazovce zakládajícího hráče.]],

    -- joining
    ["Join by address"] = "Připojit se podle adresy",
    ["The address is shown on the host's screen."] = "Adresa je zobrazena na obrazovce zakládajícího hráče.",
    ["Cancel"] = "Zrušit",
    ["Join"] = "Připojit",
    ["Invalid address"] = "Neplatná adresa",
    ["Searching for games…"] = "Hledání her…",
    ["Cannot search for games: %1"] = "Hry nelze hledat: %1",
    ["Cannot host a game: %1"] = "Hru nelze založit: %1",
    ["Connecting to %1…"] = "Připojování k %1…",
    ["Cannot connect to %1: %2"] = "Nelze se připojit k %1: %2",
    ["Connecting…"] = "Připojování…",

    -- game screen
    ["Opponent: %1"] = "Soupeř: %1",
    ["Opponent's board"] = "Soupeřův plán",
    ["Your board"] = "Váš plán",
    ["Place your ships: tap a ship to select it, tap it again to turn it, tap the water to move it there."] =
        "Rozmístěte lodě: klepnutím loď vyberete, dalším klepnutím ji otočíte, klepnutím na vodu ji tam přesunete.",
    ["Waiting for %1 to place their ships…"] = "Čeká se, až %1 rozmístí lodě…",
    ["Waiting for an opponent. Your address: %1"] = "Čeká se na soupeře. Vaše adresa: %1",
    ["Waiting for an opponent."] = "Čeká se na soupeře.",
    ["Firing…"] = "Pálí se…",
    ["Your turn: tap a square on the opponent's board."] = "Jste na tahu: klepněte na pole soupeřova plánu.",
    ["%1 is aiming…"] = "%1 míří…",
    ["You won!"] = "Vyhráli jste!",
    ["%1 won."] = "Vyhrává %1.",
    ["Waiting for %1…"] = "Čeká se na %1…",
    ["%1 wants to play again."] = "%1 chce hrát znovu.",
    ["Close"] = "Zavřít",
    ["Random"] = "Náhodně",
    ["Ready"] = "Hotovo",
    ["Play again"] = "Hrát znovu",
    ["The ship cannot turn here."] = "Loď tady nejde otočit.",
    ["The ship does not fit there. Ships may not touch."] = "Loď se tam nevejde. Lodě se nesmějí dotýkat.",
    ["Leave the game?"] = "Opustit hru?",
    ["Leave"] = "Odejít",

    -- game events
    ["The other device has a different version of Battleships."] = "Druhé zařízení má jinou verzi hry Lodě.",
    ["This game already has two players."] = "Tato hra už má dva hráče.",
    ["The opponent"] = "Soupeř",
    ["%1 left."] = "%1 odchází.",
    ["%1 left the game."] = "%1 opouští hru.",
    ["Connection to %1 lost."] = "Spojení se soupeřem %1 bylo přerušeno.",
    ["Connection lost."] = "Spojení bylo přerušeno.",
    ["%1: miss."] = "%1: vedle.",
    ["%1: hit! Fire again."] = "%1: zásah! Střílejte znovu.",
    ["%1: hit and sunk! Fire again."] = "%1: zásah, potopeno! Střílejte znovu.",
    ["%1: hit and sunk!"] = "%1: zásah, potopeno!",
    ["%1 fired at %2: miss."] = "%1 střílí na %2: vedle.",
    ["%1 fired at %2: hit."] = "%1 střílí na %2: zásah.",
    ["%1 fired at %2: your ship is sunk."] = "%1 střílí na %2: vaše loď je potopena.",
    ["%1 fired at %2: your last ship is sunk."] = "%1 střílí na %2: vaše poslední loď je potopena.",
    ["%1 joined the game."] = "Do hry vstupuje %1.",
    ["You joined %1's game."] = "Připojeno ke hře: %1.",
    ["%1 is ready."] = "%1: připraveno.",
    ["The battle begins. You fire first."] = "Bitva začíná. Střílíte první.",
    ["The battle begins. %1 fires first."] = "Bitva začíná. Jako první střílí %1.",
    ["New game: place your ships."] = "Nová hra: rozmístěte lodě.",
}
