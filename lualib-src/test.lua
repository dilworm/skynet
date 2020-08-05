print("------------------------- test snapshot  ------------------------\n")
local snapshot = require "snapshot"

local t = {} -- 这是我们要找的子结点数最多的table

local function foo()
    for i=1,1000 do
        t[#t+1] = {}
    end
end

foo()
local res = snapshot.child_count()
for k, v in pairs(res) do
    print(string.format("%-s     %-25s    %s", k, v.desc, v.count))
end

print("\n------------------------- test snapshot_helper ------------------------\n")

package.path="../../common/?.lua;"..package.path
local snapshot_h = require "snapshot_helper"
local res = snapshot_h.top_child_count(100)
for k, v in pairs(res) do
    print(string.format("%-3s    %-25s    %-s", k, v.desc, v.count))
end










