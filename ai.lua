-- ---------------------------------------------------------------------------
-- FarkleAI — computer players at three levels of risk-taking
--
-- After each roll a computer player decides two things: which scoring dice
-- to set aside, and whether to bank or roll on.
--
--   easy    sets aside every scoring die and banks as soon as the turn is
--           worth 350.
--   medium  sets aside triples and combinations but only the best single
--           1 or 5 (more dice to roll on), and banks by a threshold table
--           on the dice left: the fewer dice, the sooner it banks.
--   hard    maximises the turn's expected points exactly. V(t, n) -- the
--           value of holding t points with n dice to roll -- is solved
--           once per session by backward induction over t (setting dice
--           aside always raises t, so no state loops back), and every
--           decision is a table lookup.
--
-- All levels share the end-game rules: bank when it reaches the target;
-- in the last round, never bank short of the leader.
-- ---------------------------------------------------------------------------

local AI = {}

local STEP  = 50       -- every Farkle score is a multiple of 50
local T_CAP = 12000    -- turn points beyond this are just banked

local EASY_BANK   = 350
-- medium: bank once the turn is worth this much, by dice left to roll.
local MEDIUM_BANK = { [1] = 300, [2] = 300, [3] = 400, [4] = 1000, [5] = 2000, [6] = math.huge }

AI.LEVELS = { "easy", "medium", "hard" }

-- ---------------------------------------------------------------------------
-- Roll outcomes and their scoring options (built once)
-- ---------------------------------------------------------------------------

local FACT = { [0] = 1, 1, 2, 6, 24, 120, 720 }

-- OUTCOMES[n] = list of { c = counts, p = probability, opts = options }
-- where options are { k = dice kept, s = best score with k dice } for each
-- k that can score -- the only thing that matters for the value, since
-- V(t, n) grows with t.
local OUTCOMES

local function build_outcomes(Board)
    if OUTCOMES then return OUTCOMES end
    OUTCOMES = {}
    for n = 1, 6 do
        local list = {}
        local c = { 0, 0, 0, 0, 0, 0 }
        local function rec(f, left)
            if f == 6 then
                c[6] = left
                local copy = { c[1], c[2], c[3], c[4], c[5], c[6] }
                local ways = FACT[n]
                for i = 1, 6 do ways = ways / FACT[copy[i]] end
                -- Best score for each number of dice kept.
                local best_k = {}
                local s = { 0, 0, 0, 0, 0, 0 }
                local function sub(g)
                    if g > 6 then
                        local k = s[1] + s[2] + s[3] + s[4] + s[5] + s[6]
                        if k > 0 then
                            local sc = Board.bestScore(s)
                            if sc and (not best_k[k] or sc > best_k[k]) then best_k[k] = sc end
                        end
                        return
                    end
                    for x = 0, copy[g] do s[g] = x; sub(g + 1) end
                    s[g] = 0
                end
                sub(1)
                local opts = {}
                for k = 1, n do
                    if best_k[k] then opts[#opts + 1] = { k = k, s = best_k[k] } end
                end
                list[#list + 1] = { c = copy, p = ways / (6 ^ n), opts = opts }
                return
            end
            for x = 0, left do
                c[f] = x
                rec(f + 1, left - x)
            end
            c[f] = 0
        end
        rec(1, n)
        OUTCOMES[n] = list
    end
    return OUTCOMES
end

-- ---------------------------------------------------------------------------
-- Hard: value table
-- ---------------------------------------------------------------------------

-- V[ti][n]: value of having t = (ti - 1) * STEP points with n dice to roll,
-- acting optimally (bank or roll). R[ti][n]: value of rolling.
local V, R

local function value(t, n)
    if t > T_CAP then return t end
    return V[math.floor(t / STEP) + 1][n]
end

function AI.buildTable(Board)
    if V then return end
    local outcomes = build_outcomes(Board)
    V, R = {}, {}
    local top = math.floor(T_CAP / STEP) + 1
    for ti = top, 1, -1 do
        local t = (ti - 1) * STEP
        V[ti], R[ti] = {}, {}
        for n = 1, 6 do
            local e = 0
            for _, o in ipairs(outcomes[n]) do
                local best = 0                      -- farkle
                for _, opt in ipairs(o.opts) do
                    local left = n - opt.k
                    if left == 0 then left = 6 end  -- hot dice
                    local v = value(t + opt.s, left)
                    if v > best then best = v end
                end
                e = e + o.p * best
            end
            R[ti][n] = e
            V[ti][n] = math.max(t, e)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Choosing the dice
-- ---------------------------------------------------------------------------

-- Every scoring selection of the live dice, as { idx = {...}, s, k }.
-- Several index sets with the same faces are the same option; one is kept.
local function selections(board)
    local Board = getmetatable(board)
    local live = board:liveDice()
    local by_face = {}
    for _, i in ipairs(live) do
        local f = board.dice[i]
        by_face[f] = by_face[f] or {}
        table.insert(by_face[f], i)
    end
    local out = {}
    local s = { 0, 0, 0, 0, 0, 0 }
    local function rec(f)
        if f > 6 then
            local k = s[1] + s[2] + s[3] + s[4] + s[5] + s[6]
            if k == 0 then return end
            local sc = Board.bestScore(s)
            if not sc then return end
            local idx = {}
            for g = 1, 6 do
                for j = 1, s[g] do idx[#idx + 1] = by_face[g][j] end
            end
            out[#out + 1] = { idx = idx, s = sc, k = k }
            return
        end
        local have = by_face[f] and #by_face[f] or 0
        for x = 0, have do s[f] = x; rec(f + 1) end
        s[f] = 0
    end
    rec(1)
    return out, #live
end

-- Dice left to roll after setting aside k of n live dice.
local function left_after(n_live, k)
    local left = n_live - k
    return left == 0 and 6 or left
end

-- Medium's pick: all multi-dice combinations, plus only the single best
-- 1 or 5 -- unless keeping everything gives hot dice.
local function medium_pick(opts, n_live)
    local best, best_rank
    for _, o in ipairs(opts) do
        -- Rank: hot dice first, then points per die kept, then points.
        local rank
        if o.k == n_live then
            rank = 1e9 + o.s
        else
            rank = (o.s / o.k) * 1000 + o.s
        end
        if not best_rank or rank > best_rank then best, best_rank = o, rank end
    end
    return best
end

-- The decision for the current player after a roll:
-- returns { select = {dice indices}, bank = bool }.
function AI.decide(board, level)
    local Board = getmetatable(board)
    local p = board:currentPlayer()
    level = level or p.level or "medium"
    local opts, n_live = selections(board)
    if #opts == 0 then return nil end   -- cannot happen after a non-farkle roll
    local t0 = board.turn_points

    local pick, bank
    if level == "random" then
        -- Measurement baseline, not offered in the menu.
        pick = opts[board.rng(#opts)]
        bank = board.rng(3) == 1
    elseif level == "easy" then
        for _, o in ipairs(opts) do
            if not pick or o.s > pick.s or (o.s == pick.s and o.k > pick.k) then pick = o end
        end
        bank = t0 + pick.s >= EASY_BANK
    elseif level == "medium" then
        pick = medium_pick(opts, n_live)
        local t = t0 + pick.s
        bank = t >= MEDIUM_BANK[left_after(n_live, pick.k)]
    else
        AI.buildTable(Board)
        local best_v
        for _, o in ipairs(opts) do
            local v = value(t0 + o.s, left_after(n_live, o.k))
            if not best_v or v > best_v or (v == best_v and o.s > pick.s) then
                pick, best_v = o, v
            end
        end
        local t = t0 + pick.s
        local left = left_after(n_live, pick.k)
        bank = t >= (t > T_CAP and t or R[math.floor(t / STEP) + 1][left])
    end

    -- End game, every level: bank what wins outright; in the last round,
    -- keep rolling until ahead of the leader.
    local after = p.score + t0 + pick.s
    if board:isFinalRound() then
        bank = after > board:bestOtherScore()
    elseif after >= board.target then
        bank = true
    end
    return { select = pick.idx, bank = bank, points = pick.s }
end

-- Play one whole turn for the current player (simulation helper).
-- Returns the points banked (0 on a farkle).
function AI.playTurn(board, level)
    local res = board:roll()
    while res ~= "farkle" do
        local d = AI.decide(board, level)
        board:setSelection(d.select)
        if d.bank then return board:bank() end
        res = board:roll()
    end
    return 0
end

AI._value = function(t, n) return value(t, n) end

return AI
