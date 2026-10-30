-- ---------------------------------------------------------------------------
-- FarkleBoard — Farkle (10000 / Dix mille) game logic, 2-4 players
--
-- Pure logic, no UI. One common rule set (the Smart Box / "Farkle Pack"
-- scoring, see README):
--   single 1 = 100, single 5 = 50
--   three of a kind = face x 100 (three 1s = 1000)
--   four of a kind = 1000, five = 2000, six = 3000
--   straight 1-6 = 1500, three pairs (a four of a kind plus a pair counts)
--   = 1500, two triplets = 2500
-- A turn: roll, set aside at least one scoring die, then roll the rest or
-- bank. A roll with nothing scoring is a farkle: the turn's points are lost.
-- Setting aside all six ("hot dice") rolls all six again. The first player
-- to bank 10000 or more triggers the last round: everyone else gets one more
-- turn, and the highest score wins.
--
-- Randomness comes from `rng` (math.random by default).
-- ---------------------------------------------------------------------------

local FarkleBoard = {}
FarkleBoard.__index = FarkleBoard

local NUM_DICE    = 6
local TARGET      = 10000
local MIN_PLAYERS = 2
local MAX_PLAYERS = 4

-- ---------------------------------------------------------------------------
-- Scoring (pure functions on count vectors c[1..6])
-- ---------------------------------------------------------------------------

local function counts_key(c)
    return c[1] + 7 * c[2] + 49 * c[3] + 343 * c[4] + 2401 * c[5] + 16807 * c[6]
end

local best_memo = {}

-- Best score using ALL the dice in c, or nil if some die cannot score.
local function best_score(c)
    local key = counts_key(c)
    local hit = best_memo[key]
    if hit ~= nil then return hit or nil end
    local n = c[1] + c[2] + c[3] + c[4] + c[5] + c[6]
    local best
    if n == 0 then
        best = 0
    else
        local function try(pts, rest)
            local r = best_score(rest)
            if r and (not best or pts + r > best) then best = pts + r end
        end
        -- Six-dice combinations.
        if n == 6 then
            local pairs, trips, fours = 0, 0, 0
            local straight = true
            for f = 1, 6 do
                if c[f] ~= 1 then straight = false end
                if c[f] == 2 then pairs = pairs + 1 end
                if c[f] == 3 then trips = trips + 1 end
                if c[f] == 4 then fours = fours + 1 end
            end
            local none = { 0, 0, 0, 0, 0, 0 }
            if straight then try(1500, none) end
            if pairs == 3 or (fours == 1 and pairs == 1) then try(1500, none) end
            if trips == 2 then try(2500, none) end
        end
        for f = 1, 6 do
            local k = c[f]
            if k >= 3 then
                local rest = { c[1], c[2], c[3], c[4], c[5], c[6] }
                if k >= 6 then rest[f] = k - 6; try(3000, rest) end
                rest[f] = k
                if k >= 5 then rest[f] = k - 5; try(2000, rest) end
                rest[f] = k
                if k >= 4 then rest[f] = k - 4; try(1000, rest) end
                rest[f] = k - 3
                try(f == 1 and 1000 or f * 100, rest)
            end
        end
        if c[1] > 0 then
            local rest = { c[1] - 1, c[2], c[3], c[4], c[5], c[6] }
            try(100, rest)
        end
        if c[5] > 0 then
            local rest = { c[1], c[2], c[3], c[4], c[5] - 1, c[6] }
            try(50, rest)
        end
    end
    best_memo[key] = best or false
    return best
end

-- Does any subset of c score? (A roll for which this is false is a farkle.)
local function has_score(c)
    if c[1] > 0 or c[5] > 0 then return true end
    for f = 1, 6 do if c[f] >= 3 then return true end end
    local n = c[1] + c[2] + c[3] + c[4] + c[5] + c[6]
    if n == 6 then return best_score(c) ~= nil end   -- three pairs
    return false
end

local function counts_of(faces)
    local c = { 0, 0, 0, 0, 0, 0 }
    for _, f in ipairs(faces) do c[f] = c[f] + 1 end
    return c
end

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

-- opts.players: list of { ai = bool, level = "easy"|"medium"|"hard" }
-- opts.rng:     function(n) -> 1..n (default math.random)
-- opts.target:  winning score (default 10000)
function FarkleBoard:new(opts)
    opts = opts or {}
    local o = setmetatable({}, self)
    o.rng    = opts.rng or math.random
    o.target = opts.target or TARGET
    o:newGame(opts.players)
    return o
end

function FarkleBoard:newGame(players)
    players = players or { { ai = false }, { ai = true, level = "medium" } }
    self.players = {}
    for i = 1, math.min(#players, MAX_PLAYERS) do
        local p = players[i]
        self.players[i] = { ai = p.ai and true or false, level = p.level, score = 0 }
    end
    while #self.players < MIN_PLAYERS do
        self.players[#self.players + 1] = { ai = true, level = "medium", score = 0 }
    end
    self.current     = 1
    self.final_from  = nil     -- player who reached the target first
    self.game_over   = false
    self.last_event  = nil
    self:_startTurn()
end

function FarkleBoard:_startTurn()
    self.turn_points = 0
    self.dice        = { 0, 0, 0, 0, 0, 0 }   -- 0: not rolled this turn
    self.set_aside   = { false, false, false, false, false, false }
    self.selected    = { false, false, false, false, false, false }
    self.phase       = "start"                -- start | choose
end

function FarkleBoard:currentPlayer()
    return self.players[self.current]
end

-- ---------------------------------------------------------------------------
-- Selection
-- ---------------------------------------------------------------------------

-- Indices of the dice on the table this roll (rolled, not set aside).
function FarkleBoard:liveDice()
    local out = {}
    if self.phase ~= "choose" then return out end
    for i = 1, NUM_DICE do
        if not self.set_aside[i] then out[#out + 1] = i end
    end
    return out
end

function FarkleBoard:toggleSelect(i)
    if self.game_over or self.phase ~= "choose" or self.set_aside[i] then return false end
    self.selected[i] = not self.selected[i]
    return true
end

function FarkleBoard:setSelection(indices)
    if self.phase ~= "choose" then return false end
    for i = 1, NUM_DICE do self.selected[i] = false end
    for _, i in ipairs(indices) do
        if self.set_aside[i] then return false end
        self.selected[i] = true
    end
    return true
end

-- Points of the selected dice, or nil when nothing is selected or a selected
-- die does not score.
function FarkleBoard:selectionScore()
    local faces = {}
    for i = 1, NUM_DICE do
        if self.selected[i] then faces[#faces + 1] = self.dice[i] end
    end
    if #faces == 0 then return nil end
    local s = best_score(counts_of(faces))
    if s and s > 0 then return s end
    return nil
end

-- ---------------------------------------------------------------------------
-- Turn actions
-- ---------------------------------------------------------------------------

-- Commit the selection to the turn: its dice are set aside for good.
function FarkleBoard:_commitSelection()
    local s = self:selectionScore()
    if not s then return false end
    self.turn_points = self.turn_points + s
    for i = 1, NUM_DICE do
        if self.selected[i] then self.set_aside[i] = true end
        self.selected[i] = false
    end
    return true
end

-- Roll. At the start of a turn, all six dice; afterwards the selection is
-- set aside first and the rest rolled (all six again on hot dice).
-- Returns "rolled", "hot" (hot dice rolled), "farkle", or nil if refused.
function FarkleBoard:roll()
    if self.game_over then return nil end
    local hot = false
    if self.phase == "choose" then
        if not self:_commitSelection() then return nil end
        local all = true
        for i = 1, NUM_DICE do if not self.set_aside[i] then all = false end end
        if all then
            hot = true
            for i = 1, NUM_DICE do self.set_aside[i] = false end
        end
    end
    self.last_event = nil
    local rolled = {}
    for i = 1, NUM_DICE do
        if not self.set_aside[i] then
            self.dice[i] = self.rng(6)
            rolled[#rolled + 1] = self.dice[i]
        end
    end
    self.phase = "choose"
    if not has_score(counts_of(rolled)) then
        self.last_event = { kind = "farkle", player = self.current, lost = self.turn_points }
        self:_endTurn()
        return "farkle"
    end
    return hot and "hot" or "rolled"
end

-- Bank the turn: the selection is added and the total scored.
function FarkleBoard:bank()
    if self.game_over or self.phase ~= "choose" then return nil end
    if not self:_commitSelection() then return nil end
    local p = self:currentPlayer()
    local gained = self.turn_points
    p.score = p.score + gained
    self.last_event = { kind = "bank", player = self.current, gained = gained }
    self:_endTurn()
    return gained
end

-- Pass the turn on. The dice of the turn just played stay on show (set
-- aside dice too) until the next player rolls, so a farkle can be seen.
function FarkleBoard:_endTurn()
    local p = self:currentPlayer()
    if not self.final_from and p.score >= self.target then
        self.final_from = self.current
    end
    self.current = self.current % #self.players + 1
    if self.final_from and self.current == self.final_from then
        self.game_over = true
    end
    self.turn_points = 0
    self.selected    = { false, false, false, false, false, false }
    self.phase       = "start"
    -- set_aside and dice are cleared by the next roll (phase "start" rolls
    -- all six).
    self.shown_set_aside = self.set_aside
    self.set_aside = { false, false, false, false, false, false }
end

-- True during the last round (someone reached the target).
function FarkleBoard:isFinalRound()
    return self.final_from ~= nil and not self.game_over
end

-- Indices of the players with the best score.
function FarkleBoard:leaders()
    local best, out = -1, {}
    for i, p in ipairs(self.players) do
        if p.score > best then best, out = p.score, { i }
        elseif p.score == best then out[#out + 1] = i end
    end
    return out, best
end

-- Best score among the other players (what a last-round turn must beat).
function FarkleBoard:bestOtherScore()
    local best = 0
    for i, p in ipairs(self.players) do
        if i ~= self.current and p.score > best then best = p.score end
    end
    return best
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

local function copy6(t)
    t = t or {}
    return { t[1], t[2], t[3], t[4], t[5], t[6] }
end

function FarkleBoard:serialize()
    local players = {}
    for i, p in ipairs(self.players) do
        players[i] = { ai = p.ai, level = p.level, score = p.score }
    end
    return {
        players     = players,
        target      = self.target,
        current     = self.current,
        final_from  = self.final_from,
        game_over   = self.game_over,
        turn_points = self.turn_points,
        phase       = self.phase,
        dice        = copy6(self.dice),
        set_aside   = copy6(self.set_aside),
        selected    = copy6(self.selected),
        shown_set_aside = self.shown_set_aside and copy6(self.shown_set_aside) or nil,
    }
end

function FarkleBoard:load(data)
    if type(data) ~= "table" or type(data.players) ~= "table"
            or #data.players < MIN_PLAYERS or type(data.dice) ~= "table" then
        return false
    end
    self.players = {}
    for i, p in ipairs(data.players) do
        self.players[i] = { ai = p.ai and true or false, level = p.level,
                            score = tonumber(p.score) or 0 }
    end
    self.target      = tonumber(data.target) or TARGET
    self.current     = math.max(1, math.min(#self.players, tonumber(data.current) or 1))
    self.final_from  = tonumber(data.final_from)
    self.game_over   = data.game_over and true or false
    self.turn_points = tonumber(data.turn_points) or 0
    self.phase       = data.phase == "choose" and "choose" or "start"
    self.dice, self.set_aside, self.selected = {}, {}, {}
    for i = 1, NUM_DICE do
        self.dice[i]      = tonumber(data.dice[i]) or 0
        self.set_aside[i] = (data.set_aside and data.set_aside[i]) and true or false
        self.selected[i]  = (data.selected and data.selected[i]) and true or false
    end
    if data.shown_set_aside then
        self.shown_set_aside = {}
        for i = 1, NUM_DICE do self.shown_set_aside[i] = data.shown_set_aside[i] and true or false end
    end
    self.last_event = nil
    return true
end

FarkleBoard.NUM_DICE    = NUM_DICE
FarkleBoard.TARGET      = TARGET
FarkleBoard.MIN_PLAYERS = MIN_PLAYERS
FarkleBoard.MAX_PLAYERS = MAX_PLAYERS
FarkleBoard.bestScore   = best_score
FarkleBoard.hasScore    = has_score
FarkleBoard.countsOf    = counts_of

return FarkleBoard
