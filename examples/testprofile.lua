local skynet = require "skynet"
local p = require "profile_ex"

local function foo()
end

local function test()
    print ("=========================test=============================")

    p.hook()
    foo()
    p.unhook()
end

skynet.start(function() 
    skynet.dispatch("lua", function(session, addr, cmd, ...) end)
    skynet.fork(test)
end)
