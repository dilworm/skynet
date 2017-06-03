local skynet = require "skynet"
local p = require "profile_ex"

local a = 0
local function _foo()
    a = 2
end

local function foo()
    a = 3
    for i = 1, 1 do
        _foo()
        skynet.sleep(100)
    end
    --local a = 2
   -- print("===foo===")
end

local function test()
    print ("=========================test=============================")

    p.hook()
    foo()
    --p.unhook()
end

skynet.start(function() 
    skynet.dispatch("lua", function(session, addr, cmd, ...) end)
    skynet.fork(test)
end)
