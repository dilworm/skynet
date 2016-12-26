local skynet = require "skynet"
local socketdriver = require "socketdriver"
local wsproto = require "ws.ws_proto"
local netpack = require "netpack"
local crypto = require "crypt"
local str_lower = string.lower

local _M = {}

local connection = {}
local _socket_cb
local ST

function _M.init(handler)
    assert(type(handler) == "table")
    assert(handler.error)
    assert(handler.open)
    assert(handler.connect)
    assert(handler.disconnect)
    assert(handler.message)
    _socket_cb = handler

    ST = {
    [1] = _socket_cb.message,
    [2] = _socket_cb.connect,}
end

local MAX_HANDSHAKE =10000

--[[
-- 0  : handshake success
-- 1  : handshake unfinish
-- nil : handshake failed
--]]
local function handle_handshake(conn)
    local str = conn.buffer
    if #str >= MAX_HANDSHAKE then
        return nil, "too long handshake"
    end

    local istart, iend = str:find("\r\n\r\n")
    if not istart then 
        return 1
    end
    
    if iend ~= #str then
        return nil, "invalid handshake data."
    end

    if not str then
       print("not valid protocol!")
       return nil, "not valid protocol"
    end
    local req  = wsproto.parse(str)
    local headers = req.headers
    local val = headers.Upgrade or headers.upgrade
    if type(val) == "table" then
       val = val[1]
    end
    if not val or str_lower(val) ~= "websocket" then
       return nil, "bad \"upgrade\" request header"
    end
    local key = headers["Sec-WebSocket-Key"] or headers["sec-websocket-key"] 
    if type(key) == "table" then
       key = key[1]
    end
    if not key then
       return nil, "bad \"sec-websocket-key\" request header"
    end

    local ver = headers["Sec-WebSocket-Version"] or headers["sec-websocket-version"] 
    if type(ver) == "table" then
       ver = ver[1]
    end
    if not ver or ver ~= "13" then
       return nil, "bad \"sec-websock-version\" request header"
    end

    local protocols = headers["Sec-WebSocket-Protocol"] or headers["sec-websocket-protocol"]
    if type(protocols) == "table" then
       protocols = protocols[1]
    end

    local ngx_header = {}
    if protocols then
       ngx_header["Sec-WebSocket-Protocol"] = protocols
    end
    ngx_header["connection"] = "Upgrade"
    ngx_header["upgrade"] = "websocket"
    local sha1 = crypto.sha1(key.."258EAFA5-E914-47DA-95CA-C5AB0DC85B11",true)
    ngx_header["sec-websocket-accept"] = crypto.base64encode(sha1)
    local status = 101
    local request_line = "HTTP/1.1 ".. status .." Switching Protocols"
    local rep ={}
    table.insert(rep,request_line)
    local k,v
    for k,v in pairs(ngx_header) do
       local str = string.format('%s: %s',k,v)
       table.insert(rep,str)
    end
    rep = table.concat(rep,"\r\n")
    rep = rep.."\r\n\r\n"
    --sock:write(rep)
    local max_payload_len, send_masked
    if opts then
       max_payload_len = opts.max_payload_len
       send_masked = opts.send_masked
    end

    return 0, rep, { 
        max_payload_len = max_payload_len or 65535,
        send_masked = send_masked,
        headers = headers}
end

local function handle_dataframe(conn)
    
end

function _M.unpack(msg, sz)
    local pack = table.pack(socketdriver.unpack(msg, sz))
    local socket_type = pack[1]
    if socket_type == 2 then -- listen succ,just ignore
        return 
    end
    if socket_type == 1 then -- data
        local fd, size, buffer = pack[2], pack[3], netpack.tostring(pack[4], pack[3])
        print(fd, size, buffer)
        local conn = connection[fd] 
        if conn then
            if conn.handshaked then
                return socket_type, fd, buffer, size
            else
                conn.buffer =  conn.buffer..buffer
                conn.buf_size = conn.buf_size + size
                local ok, ret = pcall(handle_handshake, conn)
                if ok then
                    return 2, conn.fd, conn.addr
                else
                    skynet.error("Handshake failed, fd = %d", fd)
                    socketdriver.close(fd)
                    return 
                end
            end
        else
            skynet.error("Drop msg from fd = %d", fd)
        end
    elseif socket_type == 4 then -- recv new connection and wait for handshake
        fd = pack[3]
        addr = pack[4]
        assert(not connection[fd])
        print(string.format("new raw connection fd = %s, addr = %s", fd, addr))
        connection[fd] = {addr = addr, handshaked=false, buffer="", buf_size=0}
        socketdriver.start(fd)
    else
        print("warn or error on fd:"..fd)
    end
end

function _M.dispatch(_, _, type, ...)
    if type and ST[type] then 
        ST[type](...)
    end
end

return _M
