local _ = require("gettext")
-- KOReader's catalog lacks these; Czech is kept here, as _meta.lua can't require the plugin's modules.
local cs = (_.current_lang or ""):match("^cs") ~= nil
return {
    name = "battleships",
    version = "0.1.2",
    fullname = cs and "Lodě" or _("Battleships"),
    description = cs and "Klasická hra Lodě pro dva hráče, každý na své čtečce, přes Wi-Fi."
        or _([[The classic Battleships game for two players, each on their own e-reader, over Wi-Fi.]]),
}
