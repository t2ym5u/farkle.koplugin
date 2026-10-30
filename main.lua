local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = _dir .. "?.lua;" .. _dir .. "common/?.lua;" .. package.path

local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local PluginBase = require("plugin_base")
local _          = require("i18n")

require("i18n").extend(lrequire("i18n_fr"))
local FarkleScreen = lrequire("screen")

-- Seed the dice once per session, when the plugin is loaded -- not per roll,
-- which within the same second would replay the same faces.
math.randomseed(os.time())

local Farkle = PluginBase:extend{
    name      = "farkle",
    menu_text = _("Farkle"),
    menu_hint = "tools",
}

function Farkle:createScreen()
    return FarkleScreen:new{ plugin = self }
end

return Farkle
