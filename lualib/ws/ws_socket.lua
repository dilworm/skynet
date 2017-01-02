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
    if conn.buf_size < 2 then return 1 end
    
    local data = string.sub(conn.buffer,1,2)

    local fst, snd = byte(data, 1, 2)

    local fin = (fst & 0x80) ~= 0
    -- print("fin: ", fin)

    if (fst & 0x70) ~= 0 then
        return nil, nil, "bad RSV1, RSV2, or RSV3 bits"
    end

    local opcode = (fst & 0x0f)
    -- print("opcode: ", tohex(opcode))

    if opcode >= 0x3 and opcode <= 0x7 then
        return nil, nil, "reserved non-control frames"
    end

    if opcode >= 0xb and opcode <= 0xf then
        return nil, nil, "reserved control frames"
    end

    local mask = (snd & 0x80) ~= 0

    if debug then
        skynet.error("recv_frame: mask bit: ", mask and 1 or 0)
    end

    local force_masking = conn.header.force_masking
    if force_masking and not mask then
        return nil, nil, "frame unmasked"
    end

    local payload_len = (snd & 0x7f)
    -- print("payload len: ", payload_len)

    if payload_len == 126 then
        skynet.wait(1)
        local data, err = sock:readbytes(2)
        if not data then
            return nil, nil, "failed to receive the 2 byte payload length: "
                             .. (err or "unknown")
        end

        payload_len = ((byte(data, 1) << 8) | byte(data, 2))

    elseif payload_len == 127 then
        local data, err = sock:readbytes(8)
        if not data then
            return nil, nil, "failed to receive the 8 byte payload length: "
                             .. (err or "unknown")
        end

        if byte(data, 1) ~= 0
           or byte(data, 2) ~= 0
           or byte(data, 3) ~= 0
           or byte(data, 4) ~= 0
        then
            return nil, nil, "payload len too large"
        end

        local fifth = byte(data, 5)
        if (fifth & 0x80) ~= 0 then
            return nil, nil, "payload len too large"
        end

        payload_len = ((fifth<<24) |
                          (byte(data, 6) << 16)|
                          (byte(data, 7)<< 8)|
                          byte(data, 8))
    end

    if (opcode & 0x8) ~= 0 then
        -- being a control frame
        if payload_len > 125 then
            return nil, nil, "too long payload for control frame"
        end

        if not fin then
            return nil, nil, "fragmented control frame"
        end
    end

    -- print("payload len: ", payload_len, ", max payload len: ",
          -- max_payload_len)

    if payload_len > max_payload_len then
        return nil, nil, "exceeding max payload len"
    end

    local rest
    if mask then
        rest = payload_len + 4

    else
        rest = payload_len
    end
    -- print("rest: ", rest)

    local data
    if rest > 0 then
        data, err = sock:readbytes(rest)
        if not data then
            return nil, nil, "failed to read masking-len and payload: "
                             .. (err or "unknown")
        end
    else
        data = ""
    end

    -- print("received rest")

    if opcode == 0x8 then
        -- being a close frame
        if payload_len > 0 then
            if payload_len < 2 then
                return nil, nil, "close frame with a body must carry a 2-byte"
                                 .. " status code"
            end

            local msg, code
            if mask then
                local fst = (byte(data, 4 + 1) ~ byte(data, 1))
                local snd = (byte(data, 4 + 2) ~ byte(data, 2))
                code = ((fst << 8) | snd)

                if payload_len > 2 then
                    -- TODO string.buffer optimizations
                    local bytes = new_tab(payload_len - 2, 0)
                    for i = 3, payload_len do
                        bytes[i - 2] = str_char((byte(data, 4 + i) |
                                                     byte(data,
                                                          (i - 1) % 4 + 1)))
                    end
                    msg = concat(bytes)

                else
                    msg = ""
                end

            else
                local fst = byte(data, 1)
                local snd = byte(data, 2)
                code = ((fst << 8) | snd)

                -- print("parsing unmasked close frame payload: ", payload_len)

                if payload_len > 2 then
                    msg = sub(data, 3)

                else
                    msg = ""
                end
            end

            return msg, "close", code
        end

        return "", "close", nil
    end

    local msg
    if mask then
        -- TODO string.buffer optimizations
        local bytes = new_tab(payload_len, 0)
        for i = 1, payload_len do
            bytes[i] = str_char((byte(data, 4 + i) ~
                                     byte(data, (i - 1) % 4 + 1)))
        end
        msg = concat(bytes)

    else
        msg = data
    end

    return msg, types[opcode], not fin and "again" or nil

end

function _M.unpack(msg, sz)
    local pack = table.pack(socketdriver.unpack(msg, sz))
    local socket_type = pack[1]
    if socket_type == 2 then -- listen succ,just ignore
        return 
    end
    if socket_type == 1 then -- data
        local fd, size, buffer = pack[2], pack[3], netpack.tostring(pack[4], pack[3])
        --print(fd, size, buffer)
        local conn = connection[fd] 
        if conn then
            if conn.handshaked then
                conn.buffer = conn.buffer..buffer
                conn.buf_size = conn.buf_size + size
                local ok, ret = pcall(handle_dataframe, conn)
                if ok then
                    if ret == 1 then
                        return socket_type, fd, buffer, size
                    else
                        return
                    end
                else
                    skynet.error("Recv dataframe failed, fd = %d", fd)
                    socketdriver.close(fd)
                    return
                end
            else
                conn.buffer = conn.buffer..buffer
                conn.buf_size = conn.buf_size + size
                local ok, ret, reply = pcall(handle_handshake, conn)
                if ok then
                    if ret == 0 then
                        socketdriver.send(conn.fd, reply)
                        conn.buffer = ""
                        conn.buf_size = 0
                        return 2, conn.fd, conn.addr
                    end
                else
                    skynet.error("Handshake failed, fd = %d", fd)
                    socketdriver.close(fd)
                    return 
                end
            end
        else
            skynet.error("Drop msg from fd = %d", fd)
        end
    elseif socket_type == 4 then -- accept, recv new connection and wait for handshake
        fd = pack[3]
        addr = pack[4]
        assert(not connection[fd])
        print(string.format("new raw connection fd = %s, addr = %s", fd, addr))
        connection[fd] = {fd = fd, addr = addr, handshaked=false, buffer="", buf_size=0}
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
