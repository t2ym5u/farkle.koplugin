local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = DIR .. "?.lua;" .. package.path

-- A board whose dice come from a queue instead of the RNG.
local function rigged(Board, players)
    local queue = {}
    local b = Board:new{ players = players or { { ai = false }, { ai = false } },
                         rng = function() return table.remove(queue, 1) or 2 end }
    b.feed = function(faces) for _, f in ipairs(faces) do queue[#queue + 1] = f end end
    return b
end

describe("FarkleBoard", function()
    local Board

    setup(function()
        Board = require("board")
    end)

    describe("scoring", function()
        local function score(faces) return Board.bestScore(Board.countsOf(faces)) end

        it("singles", function()
            assert.are.equal(100, score{ 1 })
            assert.are.equal(50, score{ 5 })
            assert.are.equal(250, score{ 1, 1, 5 })
            assert.is_nil(score{ 2 })
            assert.is_nil(score{ 1, 3 })   -- every die must score
        end)

        it("three of a kind", function()
            assert.are.equal(1000, score{ 1, 1, 1 })
            assert.are.equal(200, score{ 2, 2, 2 })
            assert.are.equal(600, score{ 6, 6, 6 })
            assert.are.equal(600, score{ 5, 5, 5, 1 })
        end)

        it("four, five and six of a kind", function()
            assert.are.equal(1000, score{ 3, 3, 3, 3 })
            assert.are.equal(2000, score{ 4, 4, 4, 4, 4 })
            assert.are.equal(3000, score{ 2, 2, 2, 2, 2, 2 })
            -- Four 1s read better as three 1s and a single 1.
            assert.are.equal(1100, score{ 1, 1, 1, 1 })
        end)

        it("six-dice combinations", function()
            assert.are.equal(1500, score{ 1, 2, 3, 4, 5, 6 })
            assert.are.equal(1500, score{ 2, 2, 3, 3, 4, 4 })
            assert.are.equal(1500, score{ 6, 6, 6, 6, 3, 3 })   -- four + pair
            assert.are.equal(2500, score{ 2, 2, 2, 3, 3, 3 })
            assert.are.equal(3000, score{ 4, 4, 4, 4, 4, 4 })
        end)

        it("detects a farkle roll", function()
            assert.is_false(Board.hasScore(Board.countsOf{ 2, 3, 4, 6, 6, 2 }))
            assert.is_false(Board.hasScore(Board.countsOf{ 2, 3 }))
            assert.is_true(Board.hasScore(Board.countsOf{ 2, 2, 3, 3, 6, 6 }))
            assert.is_true(Board.hasScore(Board.countsOf{ 2, 3, 5 }))
            assert.is_true(Board.hasScore(Board.countsOf{ 4, 4, 4 }))
        end)
    end)

    describe("turn flow", function()
        it("a turn starts by rolling all six dice", function()
            local b = rigged(Board)
            b.feed{ 1, 2, 3, 4, 6, 6 }
            assert.are.equal("rolled", b:roll())
            assert.are.same({ 1, 2, 3, 4, 6, 6 }, b.dice)
            assert.are.equal("choose", b.phase)
        end)

        it("refuses to roll on without a scoring selection", function()
            local b = rigged(Board)
            b.feed{ 1, 2, 3, 4, 6, 6 }
            b:roll()
            assert.is_nil(b:roll())
            b:setSelection{ 2 }              -- a 2 does not score
            assert.is_nil(b:roll())
            assert.is_nil(b:bank())
        end)

        it("sets the selection aside and rolls the rest", function()
            local b = rigged(Board)
            b.feed{ 1, 2, 3, 4, 6, 6 }
            b:roll()
            b:setSelection{ 1 }
            b.feed{ 5, 2, 2, 3, 4 }
            assert.are.equal("rolled", b:roll())
            assert.are.equal(100, b.turn_points)
            assert.is_true(b.set_aside[1])
            assert.are.same({ 1, 5, 2, 2, 3, 4 }, b.dice)
            assert.is_false(b:toggleSelect(1))   -- already set aside
        end)

        it("banks the turn and passes to the next player", function()
            local b = rigged(Board)
            b.feed{ 1, 1, 1, 4, 6, 6 }
            b:roll()
            b:setSelection{ 1, 2, 3 }
            assert.are.equal(1000, b:bank())
            assert.are.equal(1000, b.players[1].score)
            assert.are.equal(2, b.current)
            assert.are.equal("start", b.phase)
            assert.are.equal(0, b.turn_points)
        end)

        it("a farkle loses the turn's points", function()
            local b = rigged(Board)
            b.feed{ 1, 1, 1, 4, 6, 6 }
            b:roll()
            b:setSelection{ 1, 2, 3 }
            b.feed{ 2, 3, 4 }
            assert.are.equal("farkle", b:roll())
            assert.are.equal(0, b.players[1].score)
            assert.are.equal(1000, b.last_event.lost)
            assert.are.equal(2, b.current)
        end)

        it("hot dice roll all six again and keep the points", function()
            local b = rigged(Board)
            b.feed{ 1, 2, 3, 4, 5, 6 }
            b:roll()
            b:setSelection{ 1, 2, 3, 4, 5, 6 }
            b.feed{ 5, 2, 2, 3, 4, 6 }
            assert.are.equal("hot", b:roll())
            assert.are.equal(1500, b.turn_points)
            for i = 1, 6 do assert.is_false(b.set_aside[i]) end
            assert.are.same({ 5, 2, 2, 3, 4, 6 }, b.dice)
        end)
    end)

    describe("end of game", function()
        it("reaching the target gives the others one last turn", function()
            local b = rigged(Board, { { ai = false }, { ai = false }, { ai = false } })
            b.players[1].score = 9500
            b.feed{ 1, 1, 1, 2, 3, 4 }
            b:roll(); b:setSelection{ 1, 2, 3 }; b:bank()
            assert.are.equal(10500, b.players[1].score)
            assert.is_true(b:isFinalRound())
            assert.are.equal(2, b.current)
            b.feed{ 2, 3, 4, 6, 6, 2 }   -- farkle
            b:roll()
            assert.is_false(b.game_over)
            b.feed{ 5, 3, 4, 6, 6, 2 }
            b:roll(); b:setSelection{ 1 }; b:bank()
            assert.is_true(b.game_over)
            local l = b:leaders()
            assert.are.same({ 1 }, l)
            assert.is_nil(b:roll())
        end)

        it("a last-round player can overtake", function()
            local b = rigged(Board)
            b.players[1].score = 9950
            b.players[2].score = 9000
            b.feed{ 5, 2, 3, 4, 6, 6 }
            b:roll(); b:setSelection{ 1 }; b:bank()
            b.feed{ 1, 1, 1, 1, 1, 1 }
            b:roll(); b:setSelection{ 1, 2, 3, 4, 5, 6 }; b:bank()
            assert.is_true(b.game_over)
            assert.are.same({ 2 }, (b:leaders()))
        end)
    end)

    describe("serialize / load", function()
        it("round-trips a turn in progress", function()
            local b = rigged(Board, { { ai = false }, { ai = true, level = "hard" } })
            b.feed{ 1, 2, 3, 4, 6, 6 }
            b:roll(); b:setSelection{ 1 }
            b.feed{ 5, 2, 2, 3, 4 }
            b:roll(); b:toggleSelect(2)
            local b2 = Board:new()
            assert.is_true(b2:load(b:serialize()))
            assert.are.same(b.dice, b2.dice)
            assert.are.same(b.set_aside, b2.set_aside)
            assert.are.same(b.selected, b2.selected)
            assert.are.equal(b.turn_points, b2.turn_points)
            assert.are.equal("choose", b2.phase)
            assert.are.equal("hard", b2.players[2].level)
            assert.are.equal(b:selectionScore(), b2:selectionScore())
        end)

        it("rejects invalid data", function()
            local b = Board:new()
            assert.is_false(b:load(nil))
            assert.is_false(b:load({}))
            assert.is_false(b:load({ players = { {} }, dice = {} }))
        end)
    end)
end)
