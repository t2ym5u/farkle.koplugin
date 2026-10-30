local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")
local T               = require("ffi/util").template

local ScreenBase = require("screen_base")
local MenuHelper = require("menu_helper")

local FarkleBoard       = lrequire("board")
local FarkleBoardWidget = lrequire("board_widget")
local FarkleAI          = lrequire("ai")

local GAME_RULES_EN = _([[
Farkle — Rules

Be the first to reach 10,000 points. On your turn, roll the six dice, then tap the scoring dice you want to set aside (they turn black). Then either Roll the remaining dice to add more, or Bank to add the turn's points to your score. Each roll must set aside at least one scoring die.

Scoring (only the dice selected in one roll combine):
• Each 1: 100 — each 5: 50
• Three of a kind: face × 100 (three 1s: 1,000)
• Four of a kind: 1,000 — five: 2,000 — six: 3,000
• Straight 1-2-3-4-5-6: 1,500
• Three pairs: 1,500 (four of a kind with a pair counts)
• Two triplets: 2,500

Farkle: a roll with no scoring die loses all the points of the turn, and the turn passes.

Hot dice: once all six dice are set aside, Roll throws all six again, and the turn goes on.

End: when a player banks 10,000 or more, every other player has one last turn. The highest score wins.

Dice set aside earlier in the turn are shown in grey. Two to four players share the device; up to three of them can be computer players, at three levels: Easy banks early, Medium follows a table of safe stopping points, Hard plays the odds exactly.
]])

local GAME_RULES_FR = [[
Dix mille (Farkle) — Règles

Soyez le premier à atteindre 10 000 points. À votre tour, lancez les six dés, puis touchez les dés qui marquent et que vous voulez mettre de côté (ils deviennent noirs). Ensuite, Lancez les dés restants pour marquer davantage, ou Encaissez pour ajouter les points du tour à votre score. Chaque lancer doit mettre de côté au moins un dé qui marque.

Points (seuls les dés choisis dans un même lancer se combinent) :
• Chaque 1 : 100 — chaque 5 : 50
• Brelan : face × 100 (trois 1 : 1 000)
• Carré : 1 000 — cinq identiques : 2 000 — six identiques : 3 000
• Suite 1-2-3-4-5-6 : 1 500
• Trois paires : 1 500 (un carré avec une paire compte)
• Deux brelans : 2 500

Farkle : un lancer sans aucun dé qui marque fait perdre tous les points du tour, et la main passe.

Dés brûlants : une fois les six dés mis de côté, Lancer relance les six, et le tour continue.

Fin : quand un joueur encaisse 10 000 points ou plus, chaque autre joueur joue un dernier tour. Le plus haut score l'emporte.

Les dés mis de côté plus tôt dans le tour sont gris. De deux à quatre joueurs partagent l'appareil ; jusqu'à trois d'entre eux peuvent être l'ordinateur, à trois niveaux : Facile encaisse tôt, Moyen suit une table de points d'arrêt prudents, Difficile joue les probabilités au plus juste.
]]

local AI_DELAY       = 1.0   -- seconds between the computer's visible steps
local AI_AFTER_TURN  = 2.0   -- pause after a turn ends, to read what happened

local LEVEL_LABELS = {
    easy   = _("Easy"),
    medium = _("Medium"),
    hard   = _("Hard"),
}

local FarkleScreen = ScreenBase:extend{}

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function FarkleScreen:init()
    self.board = FarkleBoard:new{ players = self:_playerSetup() }
    if not self.board:load(self.plugin:loadState()) then
        self.board:newGame(self:_playerSetup())
    end
    ScreenBase.init(self)
    self:maybeRunAI()
end

function FarkleScreen:serializeState()
    return self.board:serialize()
end

function FarkleScreen:closeScreen()
    self.closed = true
    if self._ai_step then UIManager:unschedule(self._ai_step) end
    ScreenBase.closeScreen(self)
end

function FarkleScreen:save()
    self.plugin:saveState(self.board:serialize())
end

-- ---------------------------------------------------------------------------
-- Players
-- ---------------------------------------------------------------------------

function FarkleScreen:_humans()
    return self.plugin:getSetting("players", 1)
end

-- Two to four players in all: a lone human always gets a computer.
function FarkleScreen:_computers()
    local h = self:_humans()
    local c = self.plugin:getSetting("computers", 1)
    return math.max(FarkleBoard.MIN_PLAYERS - h, math.min(c, FarkleBoard.MAX_PLAYERS - h))
end

function FarkleScreen:_level()
    return self.plugin:getSetting("difficulty", "medium")
end

function FarkleScreen:_playerSetup()
    local list = {}
    for _ = 1, self:_humans() do list[#list + 1] = { ai = false } end
    for _ = 1, self:_computers() do list[#list + 1] = { ai = true, level = self:_level() } end
    return list
end

function FarkleScreen:_playerName(i)
    local players = self.board.players
    local p = players[i]
    local nth, of = 0, 0
    for j, q in ipairs(players) do
        if q.ai == p.ai then
            of = of + 1
            if j <= i then nth = nth + 1 end
        end
    end
    if p.ai then
        if of == 1 then return _("Computer") end
        return T(_("Computer %1"), nth)
    end
    if of == 1 then return _("You") end
    return T(_("Player %1"), nth)
end

function FarkleScreen:_names()
    local out = {}
    for i = 1, #self.board.players do out[i] = self:_playerName(i) end
    return out
end

local function count_items(from, to)
    local items = {}
    for n = from, to do items[#items + 1] = { id = n, text = tostring(n) } end
    return items
end

function FarkleScreen:openPlayersMenu()
    MenuHelper.openPickerMenu{
        title      = _("Players"),
        items      = count_items(1, FarkleBoard.MAX_PLAYERS),
        current_id = self:_humans(),
        on_select  = function(id)
            self.plugin:saveSetting("players", id)
            self:onNewGame()
        end,
        parent = self,
    }
end

function FarkleScreen:openComputersMenu()
    local h = self:_humans()
    MenuHelper.openPickerMenu{
        title      = _("Computer players"),
        items      = count_items(math.max(0, FarkleBoard.MIN_PLAYERS - h), FarkleBoard.MAX_PLAYERS - h),
        current_id = self:_computers(),
        on_select  = function(id)
            self.plugin:saveSetting("computers", id)
            self:onNewGame()
        end,
        parent = self,
    }
end

function FarkleScreen:openDifficultyMenu()
    local items = {}
    for _, id in ipairs(FarkleAI.LEVELS) do items[#items + 1] = { id = id, text = LEVEL_LABELS[id] } end
    MenuHelper.openPickerMenu{
        title      = _("Difficulty"),
        items      = items,
        current_id = self:_level(),
        on_select  = function(id)
            self.plugin:saveSetting("difficulty", id)
            -- Takes effect at once: the computers of the game in progress
            -- switch level, no restart needed.
            for _, p in ipairs(self.board.players) do
                if p.ai then p.level = id end
            end
            self:save()
            self:updateStatus(T(_("Difficulty: %1"), LEVEL_LABELS[id]))
        end,
        parent = self,
    }
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

function FarkleScreen:buildLayout()
    local is_landscape = self:isLandscape()

    local title_bar = self:buildTitleBar(_("Farkle"), function()
        return {
            { text = _("New game"), callback = function() self:onNewGame() end },
            { text = T(_("Players: %1"), self:_humans()),
              callback = function() self:openPlayersMenu() end },
            { text = T(_("Computers: %1"), self:_computers()),
              callback = function() self:openComputersMenu() end },
            { text = T(_("Difficulty: %1"), LEVEL_LABELS[self:_level()] or self:_level()),
              callback = function() self:openDifficultyMenu() end },
            self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
        }
    end)

    self.status_text:setMaxWidth(self:getControlsWidth())
    local controls = VerticalGroup:new{
        align = "center",
        self.status_text,
        VerticalSpan:new{ width = Size.span.vertical_large },
        self:buildActionBar({
            { text = _("Roll"), callback = function() self:onRoll() end },
            { text = _("Bank"), callback = function() self:onBank() end },
        }),
    }

    local padding     = Size.padding.large
    local frame_extra = 2 * (padding + Size.border.window)
    local budget_w, budget_h = self:getBoardBudget(title_bar, controls)

    self.board_widget = FarkleBoardWidget:new{
        board      = self.board,
        names      = self:_names(),
        max_width  = budget_w - frame_extra,
        max_height = budget_h - frame_extra,
        onDieTap   = function(i) self:onDieTap(i) end,
    }

    local board_frame = FrameContainer:new{
        padding = padding,
        margin  = 0,
        self.board_widget,
    }

    if is_landscape then
        self:buildLandscapeLayout(title_bar, HorizontalGroup:new{
            align = "center",
            board_frame,
            HorizontalSpan:new{ width = self:getGutter() },
            controls,
        })
    else
        self:buildPortraitLayout(title_bar, board_frame,
            VerticalGroup:new{ align = "center", controls, VerticalSpan:new{ width = self:getGutter() } })
    end
    self:updateStatus()
end

function FarkleScreen:_redraw(msg)
    self.board_widget:refresh()
    self:updateStatus(msg)
    self:refreshActionBar()
end

-- ---------------------------------------------------------------------------
-- Human actions
-- ---------------------------------------------------------------------------

function FarkleScreen:_humanTurn()
    local board = self.board
    return not board.game_over and not board:currentPlayer().ai
end

function FarkleScreen:onDieTap(i)
    local board = self.board
    if not self:_humanTurn() then return end
    if board.phase ~= "choose" then
        self:updateStatus(_("Roll the dice first."))
        return
    end
    if not board:toggleSelect(i) then
        self:updateStatus(_("That die is already set aside."))
        return
    end
    self:save()
    self:_redraw()
end

-- Why a Roll/Bank with the current selection is refused, or nil.
function FarkleScreen:_selectionProblem()
    local board = self.board
    if board.phase ~= "choose" then return nil end
    if board:selectionScore() then return nil end
    for i = 1, board.NUM_DICE do
        if board.selected[i] then return _("Every selected die must score.") end
    end
    return _("Select at least one scoring die.")
end

function FarkleScreen:onRoll()
    if self.board.game_over then return end
    if not self:_humanTurn() then
        self:updateStatus(_("Wait for the computer."))
        return
    end
    local problem = self:_selectionProblem()
    if problem then
        self:updateStatus(problem)
        return
    end
    self:_doRoll()
    self:maybeRunAI(AI_AFTER_TURN)
end

function FarkleScreen:onBank()
    local board = self.board
    if board.game_over then return end
    if not self:_humanTurn() then
        self:updateStatus(_("Wait for the computer."))
        return
    end
    if board.phase ~= "choose" then
        self:updateStatus(_("Roll the dice first."))
        return
    end
    local problem = self:_selectionProblem()
    if problem then
        self:updateStatus(problem)
        return
    end
    self:_doBank()
    self:maybeRunAI(AI_AFTER_TURN)
end

-- Shared by both kinds of player.
function FarkleScreen:_doRoll()
    local board = self.board
    local name = self:_playerName(board.current)
    local res = board:roll()
    self:save()
    if res == "farkle" then
        self:_redraw(self:joinStatus(
            T(_("Farkle! %1 loses %2."), name, board.last_event.lost),
            self:_nextUp()))
    elseif res == "hot" then
        self:_redraw(_("Hot dice! All six rolled again."))
    else
        self:_redraw()
    end
end

function FarkleScreen:_doBank()
    local board = self.board
    local name = self:_playerName(board.current)
    local gained = board:bank()
    self:save()
    if board.game_over then
        self:_redraw()
    else
        self:_redraw(self:joinStatus(T(_("%1 banks %2."), name, gained), self:_nextUp()))
    end
end

-- "Next: <name>" (with the last-round warning when it applies).
function FarkleScreen:_nextUp()
    local board = self.board
    if board.game_over then return nil end
    local s = T(_("Next: %1"), self:_playerName(board.current))
    if board:isFinalRound() then s = self:joinStatus(_("Last round!"), s) end
    return s
end

function FarkleScreen:isRoundOver()
    return self.board.game_over
end

function FarkleScreen:onNewGame()
    if self._ai_step then UIManager:unschedule(self._ai_step) end
    self._ai_step, self.ai_decision = nil, nil
    self.board = FarkleBoard:new{ players = self:_playerSetup() }
    self:save()
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    self:maybeRunAI()
end

-- ---------------------------------------------------------------------------
-- Computer players
--
-- One visible step at a time: roll; show the dice it sets aside; then roll
-- on or bank. Each step is followed by a pause.
-- ---------------------------------------------------------------------------

function FarkleScreen:maybeRunAI(delay)
    local board = self.board
    if self.closed or self._ai_step or board.game_over or not board:currentPlayer().ai then
        return
    end
    self._ai_step = function()
        self._ai_step = nil
        if self.closed then return end
        local before = board.current
        self:_aiStep()
        -- A finished turn gets a longer pause, so its result can be read.
        self:maybeRunAI(board.current ~= before and AI_AFTER_TURN or nil)
    end
    UIManager:scheduleIn(delay or AI_DELAY, self._ai_step)
end

function FarkleScreen:_aiStep()
    local board = self.board
    if board.game_over or not board:currentPlayer().ai then return end
    if board.phase ~= "choose" then
        self.ai_decision = nil
        self:_doRoll()
        return
    end
    if not self.ai_decision then
        self.ai_decision = FarkleAI.decide(board)
        board:setSelection(self.ai_decision.select)
        self:save()
        self:_redraw()
        return
    end
    local d = self.ai_decision
    self.ai_decision = nil
    board:setSelection(d.select)
    if d.bank then self:_doBank() else self:_doRoll() end
end

-- ---------------------------------------------------------------------------
-- Status
-- ---------------------------------------------------------------------------

function FarkleScreen:updateStatus(msg)
    local board = self.board
    local status = msg
    if not status then
        if board.game_over then
            local leaders, best = board:leaders()
            if #leaders > 1 then
                local names = {}
                for _, i in ipairs(leaders) do names[#names + 1] = self:_playerName(i) end
                status = self:joinStatus(T(_("Tie: %1"), table.concat(names, ", ")),
                                         T(_("Score: %1"), best))
            else
                status = self:joinStatus(T(_("%1 wins!"), self:_playerName(leaders[1])),
                                         T(_("Score: %1"), best))
            end
        else
            local what
            if board:currentPlayer().ai then
                what = _("Computer playing…")
            elseif board.phase ~= "choose" then
                what = _("Tap Roll")
            else
                what = _("Select scoring dice, then Roll or Bank")
            end
            status = self:joinStatus(
                board:isFinalRound() and _("Last round!") or nil,
                self:_playerName(board.current), what)
        end
    end
    ScreenBase.updateStatus(self, status)
end

return FarkleScreen
