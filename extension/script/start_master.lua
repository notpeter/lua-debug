local thread = require "remotedebug.thread"

local theadpool = {}

local exitMgr = [[
    package.path = %q
    package.cpath = %q
    local thread = require "remotedebug.thread"
    local exitReq = thread.channel(%q.."ExitReq")
    local clients = {}
    local EXITCODE
    local EXITID
    local function finishExit()
        local exitRes = thread.channel("ExitRes"..EXITID)
        exitRes:push(EXITCODE)
    end
    local function isExit()
        while true do
            local ok, msg, id = exitReq:pop()
            if not ok then
                return
            end
            if msg == "INIT" then
                clients[id] = true
                goto continue
            end
            if msg == "EXIT" then
                clients[id] = false
                EXITID = id
                if next(clients) == nil then
                    EXITCODE = "OK"
                    return true
                end
                EXITCODE = "BYE"
                finishExit()
                goto continue
            end
            ::continue::
        end
    end
]]

local function createNamedChannel(name)
    local ok, err = pcall(thread.newchannel, name)
    if not ok then
        if err:sub(1,17) ~= "Duplicate channel" then
            error(err)
        end
    end
    return not ok
end

local function createNamedThread(name, path, cpath, script)
    createNamedChannel(name.."ExitReq")
    theadpool[name] = thread.named_thread(name, exitMgr:format(path, cpath, name) .. script)
end

return function (path, cpath, errlog, addr, client)
    if createNamedChannel("ExitRes"..thread.id) then
        return
    end

    createNamedChannel("DbgMaster")
    createNamedThread("error", path, cpath, ([[
        local err = thread.channel "errlog"
        local log = require "common.log"
        log.file = %q
        repeat
            local ok, msg = err:pop(0.05)
            if ok then
                log.error("ERROR:" .. msg)
            end
        until isExit()
        finishExit()
    ]]):format(errlog))

    createNamedThread("master", path, cpath, ([[
        local addr = %q
        local client = %s
]]):format(addr, client) .. [=[
        local function parse_address(address)
            if address:sub(1,1) == '@' then
                return {
                    protocol = 'unix',
                    address = address:sub(2),
                    client = client,
                }
            end
            local ipv4, port = addr:match("(%d+%.%d+%.%d+%.%d+):(%d+)")
            if ipv4 then
                return {
                    protocol = 'tcp',
                    address = ipv4,
                    port = tonumber(port),
                    client = client,
                }
            end
            local ipv6, port = addr:match("%[([%d:a-fA-F]+)%]:(%d+)")
            if ipv6 then
                return {
                    protocol = 'tcp',
                    address = ipv6,
                    port = tonumber(port),
                    client = client,
                }
            end
            error "Invalid address."
        end

        local serverFactory = require "common.serverFactory"
        local server = serverFactory(parse_address(addr))

        local dbg_io = {}
        function dbg_io:event_in(f)
            self.fsend = f
        end
        function dbg_io:event_close(f)
            self.fclose = f
        end
        function dbg_io:update()
            local data = server.recvRaw()
            if data ~= '' then
                self.fsend(data)
            end
            return true
        end
        function dbg_io:send(data)
            server.sendRaw(data)
        end
        function dbg_io:close()
            self.fclose()
        end

        local select = require "common.select"
        local master = require 'backend.master'
        master.init(dbg_io)
        repeat
            select.update(0.05)
            master.update()
        until isExit()
        finishExit()
        select.closeall()
    ]=])

    local errlog = thread.channel "errlog"
    local ok, msg = errlog:pop()
    if ok then
        print(msg)
    end

    for _, thd in ipairs {"master","error"} do
        local chan = thread.channel(thd.."ExitReq")
        chan:push("INIT", thread.id)
    end

    setmetatable(theadpool, {__gc=function(self)
        local chanRes = thread.channel("ExitRes"..thread.id)
        for _, thd in ipairs {"master","error"} do
            local chanReq = thread.channel(thd.."ExitReq")
            chanReq:push("EXIT", thread.id)
            if chanRes:bpop() == "OK" then
                self[thd]:wait()
            end
        end
    end})
end
