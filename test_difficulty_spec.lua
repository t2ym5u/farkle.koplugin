-- Difficulty guarantees of the Farkle computer players: every level's
-- choices are legal and score, the levels are ordered on the points they
-- bank per turn (Easy < Medium < Hard, on averages over seeded turns, Hard
-- close to its exact expectation), Hard plays the odds where Easy would
-- not, the same dice give the same turn, and Hard's one-off value table
-- builds within the Kobo's patience. No full matches.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = DIR .. "?.lua;" .. package.path

describe("Farkle difficulty", function()
    local Board, AI

    setup(function()
        Board = require("board")
        AI    = require("ai")
    end)

    local IDS = { "easy", "medium", "hard" }
    local KOBO = 25     -- a Kobo Aura runs this Lua about 25x slower

    -- Deterministic dice: rng(n) -> 1..n.
    local function lcg(seed)
        local x = seed
        return function(n)
            x = (x * 1103515245 + 12345) % 2147483648
            return math.floor(x / 2147483648 * n) + 1
        end
    end

    local function rolled(faces, level, turn_points)
        local q = {}
        for _, f in ipairs(faces) do q[#q + 1] = f end
        local b = Board:new{ players = { { ai = true, level = level }, { ai = false } },
                             rng = function() return table.remove(q, 1) or 2 end }
        b:roll()
        b.turn_points = turn_points or 0
        return b
    end

    -- Average points banked per turn by `level` over `n` turns of seeded
    -- dice; the target is out of reach, so no end-game rule kicks in.
    local function perTurn(level, seed, n)
        local b = Board:new{ players = { { ai = true, level = level }, { ai = true, level = level } },
                             rng = lcg(seed), target = 1e9 }
        local sum = 0
        for _ = 1, n do sum = sum + AI.playTurn(b, level) end
        return sum / n
    end

    it("builds Hard's value table within the Kobo's patience", function()
        -- Built once per session, on Hard's first decision.
        package.loaded["ai"] = nil
        local fresh = require("ai")
        local t0 = os.clock()
        fresh.buildTable(Board)
        local dt = (os.clock() - t0) * KOBO
        AI = fresh
        assert.is_true(dt <= 2.5, string.format("table build %.2f s on a Kobo", dt))
    end)

    for _, level in ipairs({ "easy", "medium", "hard", "random" }) do
        it(level .. " selections are legal and score", function()
            math.randomseed(5)
            for _ = 1, 200 do
                local b = Board:new{ players = { { ai = true, level = level }, { ai = true, level = level } } }
                if b:roll() ~= "farkle" then
                    local d = AI.decide(b)
                    assert.is_true(b:setSelection(d.select))
                    assert.are.equal(d.points, b:selectionScore())
                end
            end
        end)
    end

    it("hard keeps a single 1 rather than 1+5 with six dice", function()
        local b = rolled({ 1, 5, 2, 3, 4, 6, 6, 3 }, "hard")
        -- 1,5,2,3,4,6 is a straight: 1500 and hot dice.
        local d = AI.decide(b)
        assert.are.equal(1500, d.points)
        assert.is_false(d.bank)
        b = rolled({ 1, 5, 2, 3, 6, 6 }, "hard")
        d = AI.decide(b)
        assert.are.equal(100, d.points)
        assert.are.equal(1, #d.select)
    end)

    it("Easy banks at 350 where Hard rolls on", function()
        -- 250 already this turn, then a lone 1: 350 with five dice left.
        local e = AI.decide(rolled({ 1, 2, 3, 4, 6, 6 }, "easy", 250))
        local h = AI.decide(rolled({ 1, 2, 3, 4, 6, 6 }, "hard", 250))
        assert.are.equal(100, e.points)
        assert.are.equal(100, h.points)
        assert.is_true(e.bank)
        assert.is_false(h.bank)
    end)

    it("orders the levels on points per turn: Easy < Medium < Hard", function()
        -- Measured over 3 x 2000 turns (seeds 1-3): Easy ~470, Medium
        -- ~565, Hard ~610; Hard's exact expectation is V(0, 6) ~ 602.
        local avg = {}
        for _, id in ipairs(IDS) do
            local s = 0
            for seed = 1, 3 do s = s + perTurn(id, seed, 2000) end
            avg[id] = s / 3
        end
        local msg = string.format("easy %.0f, medium %.0f, hard %.0f",
                                  avg.easy, avg.medium, avg.hard)
        assert.is_true(avg.easy + 40 < avg.medium, msg)
        assert.is_true(avg.medium + 15 < avg.hard, msg)
        local exact = AI._value(0, 6)
        assert.is_true(math.abs(avg.hard - exact) < 0.05 * exact,
            msg .. string.format(" vs exact %.0f", exact))
    end)

    it("plays the same turns for the same dice", function()
        for _, id in ipairs(IDS) do
            assert.are.equal(perTurn(id, 9, 200), perTurn(id, 9, 200))
        end
    end)
end)
