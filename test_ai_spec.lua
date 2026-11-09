local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = DIR .. "?.lua;" .. package.path

describe("FarkleAI", function()
    local Board, AI

    setup(function()
        Board = require("board")
        AI    = require("ai")
    end)

    local function rolled(faces, level, turn_points)
        local q = {}
        for _, f in ipairs(faces) do q[#q + 1] = f end
        local b = Board:new{ players = { { ai = true, level = level }, { ai = false } },
                             rng = function() return table.remove(q, 1) or 2 end }
        b:roll()
        b.turn_points = turn_points or 0
        return b
    end

    it("hard values: banking never beats rolling six dice early", function()
        AI.buildTable(Board)
        assert.is_true(AI._value(0, 6) > 0)
        assert.is_true(AI._value(1000, 6) > 1000)
        -- With one die left and a big turn, banking is right.
        assert.are.equal(2000, AI._value(2000, 1))
    end)

    it("banks a winning total, and in the last round only when ahead", function()
        local b = rolled({ 1, 2, 3, 4, 6, 6 }, "easy")
        b.players[1].score = 9950
        assert.is_true(AI.decide(b).bank)

        b = rolled({ 1, 1, 1, 4, 6, 6 }, "easy")
        b.final_from = 2
        b.players[2].score = 12000
        assert.is_false(AI.decide(b).bank)   -- 1000 is not enough
        b.players[1].score = 11500
        assert.is_true(AI.decide(b).bank)
    end)

    it("plays whole games to the end at every level", function()
        math.randomseed(77)
        for _, level in ipairs({ "easy", "medium", "hard" }) do
            local b = Board:new{ players = { { ai = true, level = level }, { ai = true, level = "medium" } } }
            local turns = 0
            while not b.game_over do
                AI.playTurn(b)
                turns = turns + 1
                assert.is_true(turns < 500)
            end
            local _, best = b:leaders()
            assert.is_true(best >= Board.TARGET)
        end
    end)
end)
