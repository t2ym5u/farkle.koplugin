local Blitbuffer     = require("ffi/blitbuffer")
local Font           = require("ui/font")
local GestureRange   = require("ui/gesturerange")
local Geom           = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderText     = require("ui/rendertext")
local Screen         = require("device").screen
local UIManager      = require("ui/uimanager")
local _              = require("i18n")
local T              = require("ffi/util").template

local C_BG    = Blitbuffer.COLOR_WHITE
local C_INK   = Blitbuffer.COLOR_BLACK
local C_ASIDE = Blitbuffer.COLOR_GRAY_D   -- dice set aside earlier this turn
local C_FAINT = Blitbuffer.COLOR_GRAY_4

-- Standard pip layout (fractions of the die's side) for faces 1-6.
local PIP_LAYOUT = {
    [1] = { {0.5, 0.5} },
    [2] = { {0.27, 0.27}, {0.73, 0.73} },
    [3] = { {0.27, 0.27}, {0.5, 0.5}, {0.73, 0.73} },
    [4] = { {0.27, 0.27}, {0.73, 0.27}, {0.27, 0.73}, {0.73, 0.73} },
    [5] = { {0.27, 0.27}, {0.73, 0.27}, {0.5, 0.5}, {0.27, 0.73}, {0.73, 0.73} },
    [6] = { {0.27, 0.25}, {0.73, 0.25}, {0.27, 0.5}, {0.73, 0.5}, {0.27, 0.75}, {0.73, 0.75} },
}

-- Font:getFace() scales its size argument by DPI; this takes a pixel size.
local DPI_SCALE = Screen:scaleBySize(1000) / 1000
local function face_px(name, px)
    return Font:getFace(name, math.max(6, math.floor(px / DPI_SCALE)))
end

local function text_width(face, text)
    return RenderText:sizeUtf8Text(0, 9999, face, text, true, false).x
end

-- Largest face (at most max_px) whose rendering of every text fits in width.
local function fit_face(name, max_px, width, texts)
    local px = math.floor(max_px)
    while px > 8 do
        local face = face_px(name, px)
        local ok = true
        for _, t in ipairs(texts) do
            if text_width(face, t) > width then ok = false; break end
        end
        if ok then return face end
        px = px - 1
    end
    return face_px(name, 8)
end

local function draw_centered(bb, face, text, cx, cy, color)
    local m = RenderText:sizeUtf8Text(0, 9999, face, text, true, false)
    local tx = cx - math.floor(m.x / 2)
    local ty = cy + math.floor((m.y_top - m.y_bottom) / 2)
    RenderText:renderUtf8Text(bb, tx, ty, face, text, true, false, color)
end

-- ---------------------------------------------------------------------------
-- FarkleBoardWidget — scoreboard, the turn's points, and the six dice
--
-- Dice read by fill: white = on the table, black = selected to set aside
-- (tap to toggle), grey = already set aside this turn. Selection is the
-- state that matters most, so it gets the strongest contrast.
-- ---------------------------------------------------------------------------

local FarkleBoardWidget = InputContainer:extend{
    board      = nil,
    names      = nil,    -- display name per player
    max_width  = 400,
    max_height = 600,
    onDieTap   = nil,
}

function FarkleBoardWidget:init()
    local w, h  = self.max_width, self.max_height
    local board = self.board
    local np    = #board.players
    local nd    = board.NUM_DICE

    local gap     = math.max(4, math.floor(w / 40))
    -- Scoreboard: one box per player, name over score.
    local score_h = math.floor(math.min(h * 0.16, w / np * 0.6))
    local turn_h  = math.floor(score_h * 0.55)
    local dice_h  = h - score_h - turn_h - 3 * gap

    -- Dice: try 6x1, 3x2 and 2x3 and keep the largest die.
    local best, cols = 0, 3
    for _, c in ipairs({ 6, 3, 2 }) do
        local rows = math.ceil(nd / c)
        local s = math.min(math.floor((w - (c + 1) * gap) / c),
                           math.floor((dice_h - (rows + 1) * gap) / rows))
        if s > best then best, cols = s, c end
    end
    best = math.min(best, math.floor(w / 3.4))   -- keep dice from looming
    self.die, self.cols, self.rows = best, cols, math.ceil(nd / cols)
    self.gap, self.score_h, self.turn_h = gap, score_h, turn_h
    self.dice_h = self.rows * best + (self.rows + 1) * gap

    self.w = w
    self.h = score_h + turn_h + self.dice_h + 2 * gap
    self.dimen      = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    self.paint_rect = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }

    local box_w = math.floor(w / np)
    self.box_w = box_w
    self.name_face  = fit_face("cfont", score_h * 0.3, box_w - 2 * gap, self.names or { "M" })
    self.score_face = fit_face("tfont", score_h * 0.42, box_w - 2 * gap, { "88888" })
    self.turn_face  = fit_face("cfont", turn_h * 0.7, w - 2 * gap,
        { T(_("This turn: %1"), 88888) .. "   " .. T(_("Selected: %1"), "+8888") })

    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = function() return self.paint_rect end } },
    }
end

function FarkleBoardWidget:refresh()
    local rect = self.paint_rect
    UIManager:setDirty(self, function()
        return "ui", Geom:new{ x = rect.x, y = rect.y, w = rect.w, h = rect.h }
    end)
end

function FarkleBoardWidget:_diceTop()
    return self.score_h + self.turn_h + 2 * self.gap
end

-- Local x, y of die i's top-left corner (rows centred).
function FarkleBoardWidget:_diePos(i)
    local cols, s = self.cols, self.die
    local col = (i - 1) % cols
    local row = math.floor((i - 1) / cols)
    local g = math.floor((self.w - cols * s) / (cols + 1))
    return g + col * (s + g), self:_diceTop() + self.gap + row * (s + self.gap)
end

function FarkleBoardWidget:onTap(_, ges)
    if not (ges and ges.pos) then return false end
    local lx = ges.pos.x - self.paint_rect.x
    local ly = ges.pos.y - self.paint_rect.y
    if lx < 0 or ly < 0 or lx >= self.w or ly >= self.h then return false end
    if ly < self:_diceTop() then return true end
    -- The dice area is split into equal cells, so a tap between two dice
    -- still lands on one.
    local col = math.min(self.cols - 1, math.floor(lx / (self.w / self.cols)))
    local row = math.min(self.rows - 1,
        math.floor((ly - self:_diceTop()) / (self.dice_h / self.rows)))
    local i = row * self.cols + col + 1
    if i <= self.board.NUM_DICE and self.onDieTap then self.onDieTap(i) end
    return true
end

function FarkleBoardWidget:_paintDie(bb, dx, dy, s, value, state)
    local radius = math.max(2, math.floor(s * 0.14))
    local border = math.max(2, math.floor(s * 0.04))
    local fill, pip = C_BG, C_INK
    if state == "selected" then fill, pip = C_INK, C_BG
    elseif state == "aside" then fill = C_ASIDE end
    bb:paintRoundedRect(dx, dy, s, s, fill, radius)
    bb:paintBorder(dx, dy, s, s, border, C_INK, radius)
    local layout = PIP_LAYOUT[value]
    if not layout then return end   -- not rolled yet: a blank die
    local pr = math.max(3, math.floor(s * 0.085))
    for _, p in ipairs(layout) do
        bb:paintCircle(dx + math.floor(s * p[1]), dy + math.floor(s * p[2]), pr, pip)
    end
end

function FarkleBoardWidget:paintTo(bb, x, y)
    self.paint_rect = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    local board = self.board
    bb:paintRect(x, y, self.w, self.h, C_BG)

    -- Scoreboard: the player to move is inverted.
    local np, box_w, sh = #board.players, self.box_w, self.score_h
    local border = math.max(2, math.floor(sh / 30))
    for i, p in ipairs(board.players) do
        local bx = x + (i - 1) * box_w
        local w = (i == np) and (self.w - (np - 1) * box_w) or box_w
        -- Neighbouring boxes share one border instead of doubling it.
        if i > 1 then bx, w = bx - border, w + border end
        local cur = not board.game_over and i == board.current
        local fg = cur and C_BG or C_INK
        if cur then bb:paintRect(bx, y, w, sh, C_INK) end
        bb:paintBorder(bx, y, w, sh, border, C_INK)
        local name = (self.names and self.names[i]) or tostring(i)
        draw_centered(bb, self.name_face, name, bx + math.floor(w / 2), y + math.floor(sh * 0.3), fg)
        draw_centered(bb, self.score_face, tostring(p.score), bx + math.floor(w / 2),
                      y + math.floor(sh * 0.7), fg)
    end

    -- The turn's points, and what the selection would add.
    local ty = y + sh + self.gap + math.floor(self.turn_h / 2)
    if not board.game_over then
        local line = T(_("This turn: %1"), board.turn_points)
        if board.phase == "choose" then
            local sel = board:selectionScore()
            local any = false
            for i = 1, board.NUM_DICE do if board.selected[i] then any = true end end
            if any then
                line = line .. "   " .. T(_("Selected: %1"), sel and ("+" .. sel) or "–")
            end
        end
        draw_centered(bb, self.turn_face, line, x + math.floor(self.w / 2), ty,
                      board.phase == "choose" and C_INK or C_FAINT)
    end

    -- Dice. Between turns the last turn's dice stay on show, with what was
    -- set aside, so a farkle can be seen before the next roll.
    local aside = board.phase == "choose" and board.set_aside or board.shown_set_aside or {}
    for i = 1, board.NUM_DICE do
        local dx, dy = self:_diePos(i)
        local state = "live"
        if board.phase == "choose" and board.selected[i] then state = "selected"
        elseif aside[i] then state = "aside" end
        self:_paintDie(bb, x + dx, y + dy, self.die, board.dice[i], state)
    end
end

return FarkleBoardWidget
