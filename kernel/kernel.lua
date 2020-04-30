-- The core --

local _START = computer.uptime()

local flags = ... or {}
flags.init = flags.init or "/sbin/init.lua"
flags.quiet = flags.quiet or false

local _KERNEL_NAME = "ComputOS"
local _KERNEL_REVISION = "986f02c"
local _KERNEL_BUILDER = "ocawesome101@manjaro-pbp"
local _KERNEL_COMPILER = "luacomp 1.2.0"

_G._OSVERSION = string.format("%s revision %s (%s, %s)", _KERNEL_NAME, _KERNEL_REVISION, _KERNEL_BUILDER, _KERNEL_COMPILER)

_G.kernel = {}


-- bootlogger --

kernel.logger = {}
kernel.logger.log = function()end

do
  local y, w, h = 0
  local gpu = component.list("gpu")()
  local screen = component.list("screen")()
  if gpu and screen then
    gpu = component.proxy(gpu)
    gpu.bind(screen)
    w, h = gpu.maxResolution()
    gpu.setResolution(w, h)
    function kernel.logger.log(msg)
      msg = string.format("[%3.3f] %s", computer.uptime() - _START, tostring(msg))
      if y == h then
        gpu.copy(1, 2, w, h, 0, -1)
        gpu.fill(1, h, w, 1, " ")
      else
        y = y + 1
      end
      gpu.set(1, y, msg)
    end
  end
end

kernel.logger.log(_OSVERSION)

function kernel.logger.panic(reason)
  reason = tostring(reason)
  kernel.logger.log("==== Crash ".. os.date() .." ====")
  local trace = debug.traceback(reason):gsub("\t", "  ")
  for line in trace:gmatch("[^\n]+") do
    kernel.logger.log(line)
  end
  kernel.logger.log("=========== End trace ===========")
  while true do computer.pullSignal(1) computer.beep(200, 1) end
end


-- component API metatable allowing component.filesystem, and component.get --

do
  function component.get(addr)
    checkArg(1, addr, "string")
    for ca, ct in component.list() do
      if ca:sub(1, #addr) == addr then
        return ca, ct
      end
    end
    return nil, "no such compoennt"
  end

  local mt = {
    __index = function(tbl, k)
      local addr = component.list(k, true)()
      if not addr then
        error("component of type '" .. k .. "' not found")
      end
      tbl[k] = component.proxy(addr)
      return tbl[k]
    end
  }

  setmetatable(component, mt)
end


-- read-only driver for the initramfs --

local ifs = {}

do
  kernel.logger.log("loading initramfs.bin")
  local fs = component.proxy(computer.getBootAddress())
  local iramfs = fs.open("/initramfs.bin", "r")
  if not iramfs then
    kernel.logger.panic("initramfs not found")
  end
  local filetable = fs.read(iramfs, 2048)
  
  local files = {}
  for i=1, 2048, 32 do
    local name, start, size = string.unpack("<c24I4I4", filetable:sub(i, i + 31))
    if name == "\0" then
      break
    end
    name = name:gsub("\0", "")
    files[name] = {
      start= start,
      size = size
    }
  end

  function ifs.read(file)
    if files[file] then
      kernel.logger.log("reading " .. file .. " from initramfs")
      local nptr = fs.seek(iramfs, "set", files[file].start)
      if not nptr then
        kernel.logger.panic("invalid initramfs entry: " .. file)
      end
      local data = fs.read(iramfs, files[file].size)
      return data
    end
    kernel.logger.panic("no such file: " .. file)
  end

  function ifs.close()
    return fs.close(iramfs)
  end
end


-- users --

do
  kernel.logger.log("initializing user subsystem")
  local cuid = 0

  local u = {}

  local sha = ifs.read("sha256.lua")
  sha = load(sha, "=initramfs:sha256.lua", "bt", _G)

  u.passwd = {}
  u.psave = function()end

  function u.authenticate(uid, password)
    checkArg(1, uid, "number")
    checkArg(2, password, "string")
    if not passwd[uid] then
      return nil, "no such user"
    end
    return sha.sha256(password) == pswd.p
  end

  function u.login(uid, password)
    local yes, why = u.authenticate(uid, password)
    if not yes then
      return yes, why or "invalid credentials"
    end
    cuid = uid
    return yes
  end

  function u.uid()
    return cuid
  end

  function u.add(oassword, cansudo)
    checkArg(1, password, "string")
    checkArg(2, cansudo, "boolean", "nil")
    if u.uid() ~= 0 then
      return nil, "only root can do that"
    end
    local nuid = #passwd + 1
    passwd[nuid] = {p = sha.sha256(password), c = (cansudo and true) or false}
    u.psave()
    return nuid
  end

  function u.del(uid)
    checkArg(1, uid, "number")
    if u.uid()  ~= 0 then
      return nil, "only root can do that"
    end
    if not passwd[uid] then
      return nil, "no such user"
    end
    passwd[uid] = nil
    u.psave()
    return true
  end

  function u.sudo(func, uid, password)
    checkArg(1, func, "function")
    checkArg(2, uid, "number")
    checkArg(3, password, "string")
    if sha.sha256(password) == passwd[u.uid()].p then
      local o = u.uid()
      cuid = uid
      local s, r = pcall(func)
      cuid = o
      return true, s, r
    end
    return nil, "permission denied"
  end

  kernel.users = u
end


-- kernel modules-ish --

do
  kernel.logger.log("initializing kernel module service")
  local m = {}
  local l = {}
  setmetatable(kernel, {__index = l})

  function m.load(mod)
    checkArg(1, mod, "string")
    if kernel.users.uid() ~= 0 then
      return nil, "permission denied"
    end
    local ok, err = ifs.read(mod)
    if not ok then
      return nil, err
    end
    l[mod] = ok()
    return true
  end

  function m.unload(mod)
    checkArg(1, mod, "string")
    if kernel.users.uid() ~= 0 then
      return nil, "permission denied"
    end
    l[mod] = nil
    return true
  end

  kernel.module = m
end


-- filesystem management --

do
  local fs = {}

  local mounts = {}

  local function split(path)
    local segments = {}
    for seg in path:gmatch("[^;]+") do
      if seg == ".." then
        segments[#segments] = nil
      else
        segments[#segments + 1] = seg
      end
    end
    return segments
  end

  local function resolve(path)
    path = path or os.getenv("PWD")
    if path == "." then path = os.getenv("PWD") end
    if path:sub(1,1) ~= "/" then path = os.getenv("PWD") .. "/" .. path end
    local s = split(path)
    for i=1, #s, 1 do
      local cur = table.concat(s, "/", 1)
      if mounts[cur] and mounts[cur].exists(table.concat(s, "/", i)) then
        return mounts[cur], table.concat(s, "/", i)
      end
    end
    if mounts["/"].exists(path) then
      return mounts["/"], path
    end
    return nil, path .. ": no such file or directory"
  end

  local basic =  {"makeDirectory", "exists", "isDirectory", "list", "lastModified", "remove", "size", "spaceUsed", "spaceTotal", "isReadOnly", "getLabel"}
  for k, v in pairs(basic) do
    fs[v] = function(path)
      checkArg(1, path, "string", "nil")
      local mt, p = resolve(path)
      if path and not mt then
        return nil, p
      end
      return mt[v](p)
    end
  end

  local function fread(self, amount)
    checkArg(1, amount, "number", "string")
    if amount == math.huge or amount == "*a" then
      local r = ""
      repeat
        local d = self.fs.read(self.handle, math.huge)
        r = r .. (d or "")
      until not d
      return r
    end
    return self.fs.read(self.handle, amount)
  end

  local function fwrite(self, data)
    checkArg(1, data, "string")
    return self.fs.write(self.handle, data)
  end

  local function fseek(self, whence, offset)
    checkArg(1, whence, "string")
    checkArg(2, offset, "number", "nil")
    offset = offset or 0
    return self.fs.seek(self.handle, whence, offset)
  end

  local open = {}

  local function fclose(self)
    open[self.handle] = nil
    return self.fs.close(self.handle)
  end

  function fs.open(path, mode)
    checkArg(1, path, "string")
    checkArg(2, mode, "string", "nil")
    local m = mode or "r"
    mode = {}
    for c in m:gmatch(".") do
      mode[c] = true
    end
    local node, rpath = resolve(path)
    if not node then
      return nil, rpath
    end

    local handle = node.open(rpath, m)
    if handle then
      local ret = {
        fs = node,
        handle = handle,
        seek = fseek,
        close = fclose
      }
      open[handle] = ret
      if mode.r then
        ret.read = fread
      end
      if mode.w or mode.a then
        ret.write = fwrite
      end
      return ret
    else
      return nil, path .. ": no such file or directory"
    end
  end

  function fs.closeAll()
    for _, h in pairs(open) do
      h:close()
    end
  end

  function fs.copy(from, to)
    checkArg(1, from, "string")
    checkArg(2, to, "string")
    local fhdl, ferr = fs.open(from, "r")
    if not fhdl then
      return nil, ferr
    end
    local thdl, terr = fs.open(to, "w")
    if not thdl then
      return nil, terr
    end
    thdl:write(fhdl:read("*a"))
    thdl:close()
    fhdl:close()
    return true
  end

  function fs.rename(from, to)
    checkArg(1, from, "string")
    checkArg(2, to, "string")
    local ok, err = fs.copy(from, to)
    if not ok then
      return nil, err
    end
    local ok, err = fs.remove(from)
    if not ok then
      return nil, err
    end
    return true
  end

  function fs.canonical(path)
    checkArg(1, path, "string")
    if path == "." then
      path = os.getenv("PWD")
    elseif path:sub(1,1) ~= "/" then
      path = os.getenv("PWD") .. path
    end
    return "/" .. table.concat(split(path), "/")
  end

  function fs.concat(path1, path2, ...)
    checkArg(1, path1, "string")
    checkArg(2, path2, "string")
    local args = {...}
    for i=1, #args, 1 do
      checkArg(i + 2, args[i], "string")
    end
    local path = table.concat({path1, path2, ...}, "/")
    return fs.canonical(path)
  end

  local function rowrap(prx)
    local function t()
      return true
    end
    local function roerr()
      error(prx.address:sub(1,8) .. ": filesystem is read-only")
    end
    local mt = {
      __index = prx,
      __newindex = function()error("table is read-only")end,
      __ro = true
    }
    return setmetatable({
      isReadOnly = t,
      write = roerr,
      makeDirectory = roerr,
      remove = roerr,
      setLabel = roerr,
      open = function(f, m)
        m = m or "r"
        if m:find("[wa]") then
          return nil, "filesystem is read-only"
        end
        return prx.open(f, m)
      end
    }, mt)
  end

  local function proxywrap(prx)
    local mt = {
      __index = prx,
      __newindex = function()error("table is read-only")end,
      __ro = true
    }
    return setmetatable({}, mt)
  end

  function fs.mount(fsp, path, ro)
    checkArg(1, fsp, "string", "table")
    checkArg(2, path, "string")
    checkArg(2, ro, "boolean", "nil")
    --path = fs.canonical(path)
    if type(fsp) == "string" then
      fsp = component.proxy(fsp)
    end
    if mounts[path] == fsp then
      return true
    end
    if ro then
      mounts[path] = rowrap(fsp)
    else
      mounts[path] = proxywrap(fsp)
    end
    return true
  end

  function fs.mounts()
    local m = {}
    for path, proxy in pairs(mts) do
      m[path] = proxy.address
    end
    return m
  end

  function fs.umount(path)
    checkArg(1, path, "string")
    if not mounts[path] then
      return nil, "no filesystem mounted at " .. path
    end
    mounts[path] = nil
    return true
  end

--[[ loading things from the initramfs fstab is just broken. No separate boot drive for now.
  local fstab = ifs.read("fstab"):sub(1, -2) -- there's some weird char at the end we don't want, and I don't know what it is
  ifs.close()
  local fstab, err = load("return " .. fstab, "=initramfs:fstab", "bt", {})
  if not fstab then
    kernel.logger.panic(err)
  end
  fstab = fstab()

  for i, b in pairs(fstab) do
    local addr = component.get(b.address)
    kernel.logger.log("mounting " .. addr .. " at " .. b.path)
    fs.mount(addr, b.path)
  end]]

  fs.mount(computer.getBootAddress(), "/")
  fs.mount(computer.tmpAddress(), "/tmp")

  kernel.filesystem = fs
end


-- computer.shutdown stuff --

do
  local shutdown = computer.shutdown
  local closeAll = kernel.filesystem.closeAll
  kernel.filesystem.closeAll = nil
  function computer.shutdown(reboot)
    checkArg(1, reboot, "boolean")
    local running = kernel.thread.threads()
    for i=1, #running, 1 do
      kernel.thread.signal(running[i].pid, kernel.thread.signals.term)
    end
    coroutine.yield()
    for i=1, #running, 1 do
      kernel.thread.signal(running[i].pid, kernel.thread.signals.kill)
    end
    coroutine.yield()
    closeAll()
    shutdown(reboot)
  end
end


-- userspace sandbox and some security features --

kernel.logger.log("wrapping setmetatable,getmetatable for security")

local smt, gmt = setmetatable, getmetatable

function _G.setmetatable(tbl, mt)
  checkArg(1, tbl, "table")
  checkArg(2, mt, "table")
  local _mt = gmt(tbl)
  if _mt and _mt.__ro then
    error("table is read-only")
  end
  return smt(tbl, mt)
end

function _G.getmetatable(tbl)
  checkArg(1, tbl, "table")
  local mt = gmt(tbl)
  local _mt = {
    __index = mt,
    __newindex = function()error("metatable is read-only")end,
    __ro = true
  }
  if mt and mt.__ro then
    return smt({}, _mt)
  else
    return mt
  end
end

kernel.logger.log("setting up userspace sandbox")

local sandbox = {}

for k, v in pairs(_G) do
  if v ~= _G then -- prevent recursion hopefully
    if type(v) == "table" then
      sandbox[k] = setmetatable({}, {__index = v})
    else
      sandbox[k] = v
    end
  end
end

sandbox.computer.pullSignal = coroutine.yield()


-- big fancy scheduler --

do
  kernel.logger.log("initializing scheduler")
  local thread, tasks, sbuf, last, cur = {}, {}, {}, 0, 0

  local function checkDead(thd)
    local p = tasks[thd.parent] or {dead = false, coro = coroutine.create(function()end)}
    if thd.dead or p.dead or coroutine.status(thd.coro) == "dead" or coroutine.status(p.coro) == "dead" then
      return true
    end
    return false
  end

  local function getMinTimeout()
    local min = math.huge
    for pid, thd in pairs(tasks) do
      if computer.uptime() - thd.deadline < min then
        min = computer.uptime() - thd.deadline
      end
      if min <= 0 then
        min = 0
        break
      end
    end
    return min
  end

  local function cleanup()
    local dead = {}
    for pid, thd in pairs(tasks) do
      if checkDead(thd) then
        computer.pushSignal("thread_died", pid)
        dead[#dead + 1] = pid
      end
    end
    for i=1, #dead, 1 do
      tasks[dead[i]] = nil
    end

    local timeout = getMinTimeout()
    local sig = {computer.pullSignal(timeout)}
    if #sig > 0 then
      sbuf[#sbuf + 1] = sig
    end
  end

  local function getHandler(thd)
    local p = tasks[thd.parent] or {handler = kernel.logger.panic}
    return thd.handler or p.handler or getHandler(p)
  end

  local function handleProcessError(thd, err)
    local h = getHandler(thd)
    tasks[thd.pid] = nil
    computer.pushSignal("thread_errored", thd.pid, err)
    h(err)
  end

  local global_env = {}

  function thread.spawn(func, name, handler, env, stdin, stdout, priority)
    checkArg(1, func, "function")
    checkArg(2, name, "string")
    checkArg(3, handler, "function", "nil")
    checkArg(4, env, "table", "nil")
    checkArg(5, stdin, "table", "nil")
    checkArg(6, stdout, "table", "nil")
    last = last + 1
    env = setmetatable(env or {}, {__index = (tasks[cur] and tasks[cur].env) or global_env})
    stdin = stdin or {}
    stdour = stdout or {}
    priority = priority or math.huge
    local new = {
      coro = coroutine.create( -- the thread itself
        function()
          return xpcall(func, debug.traceback)
        end
      ),
      pid = last, -- process/thread ID
      name = name, -- thread name
      handler = handler, -- error handler
      user = kernel.users.uid(), -- current user
      users = {}, -- user history
      owner = kernel.users.uid(), -- thread owner
      sig = {}, -- signal buffer
      ipc = {}, -- IPC buffer
      env = env, -- environment variables
      stdin = stdin, -- thread STDIN handle
      stdout = stdout, -- thread STDOUT handle
      deadline = computer.uptime(), -- signal deadline
      priority = priority, -- thread priority
      uptime = 0, -- thread uptime
      started = computer.uptime() -- time of thread creation
    }
    if not new.env.PWD then
      new.env.PWD = "/"
    end
    tasks[last] = new
    return last
  end

  function os.setenv(var, val)
    checkArg(1, var, "string", "number")
    checkArg(2, val, "string", "number", "boolean", "table", "nil", "function")
    if tasks[cur] then
      tasks[cur].env[var] = val
    else
      global_env[var] = val
    end
  end

  function os.getenv(var)
    checkArg(1, var, "string", "number")
    if tasks[cur] then
      tasks[cur].env[var] = val
    else
      global_env[var] = val
    end
  end

  function thread.stdin(stdin)
    checkArg(1, stdin, "table", "nil")
    if threads[cur] then
      if stdin then
        threads[cur].stdin = stdin
      end
      return threads[cur].stdin
    end
  end

  function thread.stdout(stdout)
    checkArg(1, stdout, "table", "nil")
    if threads[cur] then
      if stdout then
        threads[cur].stdout = stdout
      end
      return threads[cur].stdout
    end
  end

  -- (re)define kernel.users stuff to be thread-local. Not done in module/users.lua as it requires low-level thread access.
  local ulogin, ulogout, uuid = kernel.users.login, kernel.users.logout, kernel.users.uid
  function kernel.users.login(uid, password)
    checkArg(1, uid, "number")
    checkArg(2, password, "string")
    local ok, err = kernel.users.authenticate(uid, password)
    if not ok then
      return nil, err
    end
    if threads[cur] then
      table.insert(threads[cur].users, 1, threads[cur].user)
      threads[cur].user = uid
      return true
    end
    return ulogin(uid, password)
  end

  function kernel.users.logout()
    if tasks[cur] then
      tasks[cur].user = -1
      if #tasks[cur].users > 0 then
        tasks[cur].user = table.remove(tasks[cur].users, 1)
      end
      return true
    end
    return false -- kernel is always root
  end

  function kernel.users.uid()
    if tasks[cur] then
      return tasks[cur].user
    else
      return 0 -- again, kernel is always root
    end
  end

  function thread.threads()
    local t = {}
    for pid, _ in pairs(tasks) do
      t[#t + 1] = pid
    end
    return t
  end

  function thread.info(pid)
    checkArg(1, pid, "number")
    if not tasks[pid] then
      return nil, "no such thread"
    end
    local t = tasks[pid]
    local inf = {
      name = t.name,
      owner = t.owner,
      priority = thd.priority,
      uptime = thd.uptime,
      started = thd.started
    }
  end

  function thread.signal(pid, sig)
    checkArg(1, pid, "number")
    checkArg(2, sig, "number")
    if not tasks[pid] then
      return nil, "no such thread"
    end
    local msg = {
      "signal",
      cur,
      sig
    }
    table.insert(tasks[pid].sig, msg)
    return true
  end

  function thread.ipc(pid, ...)
    checkArg(1, pid, "number")
    if not tasks[pid] then
      return nil, "no such thread"
    end
    local ipc = {
      "ipc",
      cur,
      ...
    }
    table.insert(tasks[pid].ipc, ipc)
    return true
  end

  thread.signals = {
    interrupt = 2,
    quit      = 3,
    term      = 15,
    usr1      = 65,
    usr2      = 66,
    kill      = 9
  }

  function thread.start()
    thread.start = nil
    while #tasks > 0 do
      local run = {}
      for pid, thd in pairs(tasks) do
        if thd.deadline <= computer.uptime() or #sbuf > 0 or #thd.ipc > 0 or #thd.sig > 0 then
          run[#run + 1] = thd
        end
      end

      table.sort(run, function(a, b)
        if a.priority > b.priority then
          return a, b
        elseif a.prioroty < b.priority then
          return b, a
        else
          return a, b
        end
      end)

      local sig = table.remove(sbuf, 1)

      for i, thd in ipairs(run) do
        cur = thd.pid
        local ok, p1, p2
        if #thd.ipc > 0 then
          local ipc = table.remove(thd.ipc, 1)
          ok, p1, p2 = coroutine.resume(thd.coro, table.unpack(ipc))
        elseif #thd.sig > 0 then
          local nsig = table.remove(thd.sig, 1)
          ok, p1, p2 = coroutine.resume(thd.coro, table.unpack(nsig))
          if nsig[3] == thread.signals.kill then
            thd.dead = true
          end
        elseif sig and #sig > 0 then
          ok, p1, p2 = coroutine.resume(thd.coro, table.unpack(sig))
        else
          ok, p1, p2 = coroutine.resume(thd.coro)
        end
        --kernel.logger.log(tostring(ok) .. " " .. tostring(p1) .. " " .. tostring(p2))
        if (not p1) and p2 then
          handleProcessError(thd, p2)
        elseif ok then
          if p1 and type(p2) == "number" then
            thd.deadline = thd.deadline + p2
          else
            thd.deadline = math.huge
          end
          thd.uptime = computer.uptime() - thd.started
        end
      end

      cleanup()
    end
    kernel.logger.panic("all tasks died")
  end

  kernel.thread = thread
end


-- basic loadfile function --

local function loadfile(file, mode, env)
  checkArg(1, file, "string")
  checkArg(2, mode, "string", "nil")
  checkArg(3, env, "table", "nil")
  mode = mode or "bt"
  env = env or sandbox
  local handle, err = kernel.filesystem.open(file, "r")
  if not handle then
    return nil, err
  end
  local data = handle:read("*a")
  handle:close()
  return load(data, "=" .. file, mode, env)
end

sandbox.loadfile = loadfile


kernel.logger.log("loadinig init from " .. flags.init)

local ok, err = loadfile(flags.init, "bt", sandbox)
if not ok then
  kernel.logger.panic(err)
end

kernel.thread.spawn(ok, flags.init, kernel.logger.panic)

kernel.thread.start()
