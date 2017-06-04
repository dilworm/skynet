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
    print("&&&&&&& ".. a.." \n")
    --skynet.sleep(100)
end

local function test()
    print ("=========================test=============================")

    p.hook()
    --skynet.sleep(100)
    foo()
    stat = p.get_stat()
    for _, v in pairs(stat) do
        print(v.name, v.count, v.totaltime)
    end
    p.reset_stat();
    --p.unhook()
end

skynet.start(function() 
    skynet.dispatch("lua", function(session, addr, cmd, ...) end)
    skynet.fork(test)
    skynet.fork(test)
    skynet.fork(test)
end)
