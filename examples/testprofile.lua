local skynet = require "skynet"
local p = require "profile_ex"

local a = 0
local function _foo(i)
    a = i
end

local function foo()
    for i = 1,10000 do
        _foo(i)
    end
    skynet.error(string.format("%s ---before sleep", coroutine.running()))
    skynet.sleep(math.random(200,300))
    skynet.error(string.format("%s ---after sleep", coroutine.running()))
end

local function test()
    skynet.error("=========================test=============================")

    p.hook()
    foo()
    stat = p.get_stat()
    for _, v in pairs(stat) do
        skynet.error(string.format("%s|%-15s |%-10s |%-10.9f", coroutine.running(),v.name, v.count, v.totaltime))
    end
    --p.reset_stat();
    --p.unhook()
end

skynet.start(function() 
    skynet.dispatch("lua", function(session, addr, cmd, ...) end)
    skynet.fork(test)
    skynet.fork(test)
    skynet.fork(test)
end)
