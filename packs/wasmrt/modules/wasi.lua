-- Hosts/Lua/wasi.lua — WASI (wasi_snapshot_preview1) на Lua для модулей Spider (lua-no-ffi / lua-bytearray).
--
-- Работает поверх экспорта модуля `__host` (API памяти, не зависит от бэкенда), поэтому
-- годится для любого хоста: чистый LuaJIT, VoxelCore и т.д.
--
--   local wasi = WASI.create({
--       args = { "prog", "arg1" },              -- argv
--       env = { HOME = "/" },                   -- environ
--       stdout = function(text) ... end,        -- вывод fd 1 (по умолчанию io.write)
--       stderr = function(text) ... end,        -- вывод fd 2 (по умолчанию как stdout)
--       read_file = function(path) return string_or_nil end,  -- файлы только на чтение
--       list_dir = function(path) return { {name, is_dir}, ... } or nil end,  -- каталоги (fd_readdir, stat);
--                                               -- nil — каталога нет (необязательно, 12.10, Half-Life)
--       clock = function() return seconds end,  -- CLOCK_REALTIME / MONOTONIC (os.time/os.clock)
--       random = function() return 0..255 end,  -- random_get (по умолчанию math.random)
--   })
--   local exports = loader({ wasi_snapshot_preview1 = wasi.imports, ... })
--   wasi:bind(exports)                          -- память и __host
--   local ok, err = pcall(exports._start)       -- модель command
--   local code = WASI.exit_code(err)            -- proc_exit(code) -> code, иначе nil
--
-- Файловая система: один предоткрытый каталог "/" (fd 3). Открытие на чтение берёт
-- содержимое у read_file; создание/запись файла держит его в памяти (wasi.files[path]),
-- откуда хост может его забрать. Неизвестные вызовы отвечают ENOSYS и пишутся в лог
-- один раз (options.log, по умолчанию stderr).

local M = {}

local ERRNO = {
    SUCCESS = 0, ACCES = 2, BADF = 8, EXIST = 20, INVAL = 28, ISDIR = 31, NOENT = 44,
    NOSYS = 52, NOTDIR = 54, NOTSUP = 58, SPIPE = 70,
}
M.ERRNO = ERRNO

local FILETYPE = { CHARACTER_DEVICE = 2, DIRECTORY = 3, REGULAR_FILE = 4 }
local OFLAGS = { CREAT = 1, DIRECTORY = 2, EXCL = 4, TRUNC = 8 }
local FDFLAGS_APPEND = 1
local ALL_RIGHTS_LO, ALL_RIGHTS_HI = 0xFFFFFFFF, 0x1F  -- все права wasi (до 2^37)
-- stdio без FD_SEEK (1 << 2) и FD_TELL (1 << 5): по ним wasi-libc (__isatty) считает поток
-- терминалом и включает построчную буферизацию; иначе printf копится до заполнения буфера.
local TTY_RIGHTS_LO = 0xFFFFFFFF - 4 - 32

local EXIT_MT = { __tostring = function(self) return "wasi proc_exit(" .. self.code .. ")" end }

-- Код выхода, если ошибка — это proc_exit, иначе nil.
function M.exit_code(err)
    if type(err) == "table" and getmetatable(err) == EXIT_MT then
        return err.code
    end
    return nil
end

-- i64 из Spider ({lo, hi} без знака) или число -> число Lua (со знаком).
local function i64_value(v)
    if type(v) == "number" then
        return v
    end
    local lo, hi = v[1], v[2]
    if hi >= 0x80000000 then
        return (hi - 0x100000000) * 4294967296 + lo
    end
    return hi * 4294967296 + lo
end

local function normalize(path)
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then
            parts[#parts] = nil
        elseif part ~= "." then
            parts[#parts + 1] = part
        end
    end
    return table.concat(parts, "/")
end

function M.create(options)
    options = options or {}
    local args = options.args or { "wasm" }
    local env = options.env or {}
    local write_out = options.stdout or function(text) io.write(text) end
    local write_err = options.stderr or write_out
    local read_file = options.read_file or function() return nil end
    local list_dir = options.list_dir
    local clock = options.clock or function() return os.time() end
    local mono = options.monotonic or os.clock
    local random = options.random or function() return math.random(0, 255) end
    local log = options.log or function(text) io.stderr:write(text, "\n") end

    local self = { files = {}, imports = nil, exports = nil }
    local host, memory

    local fds = {
        [0] = { kind = "stdin" },
        [1] = { kind = "stdout", write = write_out },
        [2] = { kind = "stderr", write = write_err },
        [3] = { kind = "dir", path = "" },
    }
    local next_fd = 4

    local function u32(ptr, value) host.write_i32(memory, ptr, value) end
    local function u64(ptr, value)
        if value < 0 then value = 0 end
        local hi = math.floor(value / 4294967296)
        host.write_i32(memory, ptr, value - hi * 4294967296)
        host.write_i32(memory, ptr + 4, hi)
    end

    local function file_text(fd)
        if fd.parts then
            fd.data = table.concat(fd.parts)
            fd.parts = nil
        end
        return fd.data
    end

    local function strings_sizes(list)
        local size = 0
        for _, s in ipairs(list) do size = size + #s + 1 end
        return #list, size
    end

    local function strings_get(list, ptrs, buf)
        for i, s in ipairs(list) do
            u32(ptrs + (i - 1) * 4, buf)
            host.write_string(memory, buf, s .. "\0")
            buf = buf + #s + 1
        end
        return ERRNO.SUCCESS
    end

    local env_list = {}
    for k, v in pairs(env) do env_list[#env_list + 1] = k .. "=" .. v end
    table.sort(env_list)

    local function resolve(dirfd, path_ptr, path_len)
        local dir = fds[dirfd]
        if not dir or dir.kind ~= "dir" then return nil, ERRNO.BADF end
        local path = host.read_string(memory, path_ptr, path_len)
        return normalize(dir.path .. "/" .. path)
    end

    local function lookup(path)
        if self.files[path] then return self.files[path] end
        local data = read_file(path)
        if data then return data end
        return nil
    end

    local function filestat(ptr, filetype, size)
        host.fill(memory, ptr, 0, 64)
        host.write_u8(memory, ptr + 16, filetype)
        u64(ptr + 24, 1)
        u64(ptr + 32, size)
    end

    local wasi = {}

    function wasi.args_sizes_get(argc_ptr, size_ptr)
        local n, size = strings_sizes(args)
        u32(argc_ptr, n); u32(size_ptr, size)
        return ERRNO.SUCCESS
    end
    function wasi.args_get(argv_ptr, buf_ptr) return strings_get(args, argv_ptr, buf_ptr) end
    function wasi.environ_sizes_get(count_ptr, size_ptr)
        local n, size = strings_sizes(env_list)
        u32(count_ptr, n); u32(size_ptr, size)
        return ERRNO.SUCCESS
    end
    function wasi.environ_get(env_ptr, buf_ptr) return strings_get(env_list, env_ptr, buf_ptr) end

    function wasi.clock_res_get(id, res_ptr)
        u64(res_ptr, 1000)
        return ERRNO.SUCCESS
    end
    function wasi.clock_time_get(id, precision, time_ptr)
        local seconds = (id == 0) and clock() or mono()
        u64(time_ptr, math.floor(seconds * 1e9))
        return ERRNO.SUCCESS
    end

    function wasi.random_get(buf, len)
        for i = 0, len - 1 do host.write_u8(memory, buf + i, random()) end
        return ERRNO.SUCCESS
    end

    function wasi.proc_exit(code)
        self.exit_code = code
        error(setmetatable({ code = code }, EXIT_MT), 0)
    end
    function wasi.proc_raise() return ERRNO.NOSYS end
    function wasi.sched_yield()
        if options.yield then options.yield() end
        return ERRNO.SUCCESS
    end

    function wasi.fd_write(fd, iovs, iovs_len, nwritten_ptr)
        local f = fds[fd]
        if not f then return ERRNO.BADF end
        local total, chunks = 0, {}
        for i = 0, iovs_len - 1 do
            local buf = host.read_u32(memory, iovs + i * 8)
            local len = host.read_u32(memory, iovs + i * 8 + 4)
            if len > 0 then
                chunks[#chunks + 1] = host.read_string(memory, buf, len)
                total = total + len
            end
        end
        local text = table.concat(chunks)
        if f.write then
            if #text > 0 then f.write(text) end
        elseif f.kind == "file" and f.writable then
            local data = file_text(f)
            if f.append then f.pos = #data end
            data = data:sub(1, f.pos) .. text .. data:sub(f.pos + #text + 1)
            f.data = data
            f.pos = f.pos + #text
            self.files[f.path] = data
        else
            return ERRNO.BADF
        end
        u32(nwritten_ptr, total)
        return ERRNO.SUCCESS
    end

    function wasi.fd_read(fd, iovs, iovs_len, nread_ptr)
        local f = fds[fd]
        if not f then return ERRNO.BADF end
        if f.kind == "stdin" then
            local text = options.stdin and options.stdin() or ""
            f.data, f.pos, f.kind = text, 0, "stdin_buffer"
        end
        if f.kind == "dir" then return ERRNO.ISDIR end
        if not f.data then return ERRNO.BADF end
        local data = file_text(f)
        local total = 0
        for i = 0, iovs_len - 1 do
            local buf = host.read_u32(memory, iovs + i * 8)
            local len = host.read_u32(memory, iovs + i * 8 + 4)
            local chunk = data:sub(f.pos + 1, f.pos + len)
            if #chunk > 0 then host.write_string(memory, buf, chunk) end
            f.pos = f.pos + #chunk
            total = total + #chunk
            if #chunk < len then break end
        end
        u32(nread_ptr, total)
        return ERRNO.SUCCESS
    end

    function wasi.fd_pread(fd, iovs, iovs_len, offset, nread_ptr)
        local f = fds[fd]
        if not f or f.kind ~= "file" then return ERRNO.BADF end
        local saved = f.pos
        f.pos = i64_value(offset)
        local r = wasi.fd_read(fd, iovs, iovs_len, nread_ptr)
        f.pos = saved
        return r
    end

    function wasi.fd_seek(fd, offset, whence, newoffset_ptr)
        local f = fds[fd]
        if not f then return ERRNO.BADF end
        if f.kind ~= "file" then return ERRNO.SPIPE end
        local base = (whence == 0 and 0) or (whence == 1 and f.pos) or #file_text(f)
        local pos = base + i64_value(offset)
        if pos < 0 then return ERRNO.INVAL end
        f.pos = pos
        u64(newoffset_ptr, pos)
        return ERRNO.SUCCESS
    end

    function wasi.fd_tell(fd, offset_ptr)
        local f = fds[fd]
        if not f or f.kind ~= "file" then return ERRNO.BADF end
        u64(offset_ptr, f.pos)
        return ERRNO.SUCCESS
    end

    function wasi.fd_close(fd)
        if not fds[fd] then return ERRNO.BADF end
        if fd > 3 then fds[fd] = nil end
        return ERRNO.SUCCESS
    end

    function wasi.fd_sync() return ERRNO.SUCCESS end
    function wasi.fd_datasync() return ERRNO.SUCCESS end
    function wasi.fd_advise() return ERRNO.SUCCESS end
    function wasi.fd_fdstat_set_flags() return ERRNO.SUCCESS end

    function wasi.fd_fdstat_get(fd, ptr)
        local f = fds[fd]
        if not f then return ERRNO.BADF end
        local filetype = (f.kind == "dir" and FILETYPE.DIRECTORY)
            or (f.kind == "file" and FILETYPE.REGULAR_FILE) or FILETYPE.CHARACTER_DEVICE
        host.fill(memory, ptr, 0, 24)
        host.write_u8(memory, ptr, filetype)
        host.write_u16(memory, ptr + 2, f.append and FDFLAGS_APPEND or 0)
        u32(ptr + 8, filetype == FILETYPE.CHARACTER_DEVICE and TTY_RIGHTS_LO or ALL_RIGHTS_LO)
        u32(ptr + 12, ALL_RIGHTS_HI)
        u32(ptr + 16, ALL_RIGHTS_LO); u32(ptr + 20, ALL_RIGHTS_HI)
        return ERRNO.SUCCESS
    end

    function wasi.fd_filestat_get(fd, ptr)
        local f = fds[fd]
        if not f then return ERRNO.BADF end
        if f.kind == "file" then
            filestat(ptr, FILETYPE.REGULAR_FILE, #file_text(f))
        elseif f.kind == "dir" then
            filestat(ptr, FILETYPE.DIRECTORY, 0)
        else
            filestat(ptr, FILETYPE.CHARACTER_DEVICE, 0)
        end
        return ERRNO.SUCCESS
    end

    function wasi.fd_prestat_get(fd, ptr)
        if fd ~= 3 then return ERRNO.BADF end
        host.fill(memory, ptr, 0, 8)
        u32(ptr + 4, 1)  -- длина имени "/"
        return ERRNO.SUCCESS
    end

    function wasi.fd_prestat_dir_name(fd, path_ptr, len)
        if fd ~= 3 then return ERRNO.BADF end
        host.write_string(memory, path_ptr, ("/"):sub(1, len))
        return ERRNO.SUCCESS
    end

    function wasi.path_open(dirfd, dirflags, path_ptr, path_len, oflags, rights_base, rights_inh, fdflags, fd_ptr)
        local path, err = resolve(dirfd, path_ptr, path_len)
        if not path then return err end
        local data = lookup(path)
        local creat = bit.band(oflags, OFLAGS.CREAT) ~= 0
        if bit.band(oflags, OFLAGS.DIRECTORY) ~= 0 or path == "" then
            if path ~= "" and data then return ERRNO.NOTDIR end
            fds[next_fd] = { kind = "dir", path = path }
        else
            if not data then
                if not creat then return ERRNO.NOENT end
                data = ""
            elseif bit.band(oflags, OFLAGS.EXCL) ~= 0 and creat then
                return ERRNO.EXIST
            end
            local writable = creat or bit.band(oflags, OFLAGS.TRUNC) ~= 0
                or bit.band(rights_base and (type(rights_base) == "table" and rights_base[1] or rights_base) or 0, 64) ~= 0
            if bit.band(oflags, OFLAGS.TRUNC) ~= 0 then data = "" end
            if creat or bit.band(oflags, OFLAGS.TRUNC) ~= 0 then self.files[path] = data end
            fds[next_fd] = {
                kind = "file", path = path, data = data, pos = 0,
                writable = writable, append = bit.band(fdflags, FDFLAGS_APPEND) ~= 0,
            }
        end
        u32(fd_ptr, next_fd)
        next_fd = next_fd + 1
        return ERRNO.SUCCESS
    end

    function wasi.path_filestat_get(dirfd, flags, path_ptr, path_len, ptr)
        local path, err = resolve(dirfd, path_ptr, path_len)
        if not path then return err end
        if path == "" then
            filestat(ptr, FILETYPE.DIRECTORY, 0)
            return ERRNO.SUCCESS
        end
        local data = lookup(path)
        if not data then
            if list_dir and list_dir(path) then
                filestat(ptr, FILETYPE.DIRECTORY, 0)
                return ERRNO.SUCCESS
            end
            return ERRNO.NOENT
        end
        filestat(ptr, FILETYPE.REGULAR_FILE, #data)
        return ERRNO.SUCCESS
    end

    -- fd_readdir: записи dirent (d_next u64, d_ino u64, d_namlen u32, d_type u8 + 3) + имя;
    -- последняя запись может быть обрезана (libc перечитает с cookie большим буфером).
    function wasi.fd_readdir(fd, buf, buf_len, cookie, bufused_ptr)
        local f = fds[fd]
        if not f then return ERRNO.BADF end
        if f.kind ~= "dir" then return ERRNO.NOTDIR end
        if not list_dir then return ERRNO.NOSYS end
        if not f.entries then
            f.entries = { { ".", true }, { "..", true } }
            for _, e in ipairs(list_dir(f.path) or {}) do f.entries[#f.entries + 1] = e end
        end
        local start = i64_value(cookie)
        local used = 0
        for i = start + 1, #f.entries do
            if used >= buf_len then break end
            local e = f.entries[i]
            local name = e[1]
            local rec = {}
            local function le(v, n)
                for _ = 1, n do rec[#rec + 1] = string.char(v % 256); v = math.floor(v / 256) end
            end
            le(i, 8); le(i, 8); le(#name, 4)
            rec[#rec + 1] = string.char(e[2] and FILETYPE.DIRECTORY or FILETYPE.REGULAR_FILE)
            rec[#rec + 1] = "\0\0\0"
            rec[#rec + 1] = name
            local s = table.concat(rec)
            if used + #s > buf_len then s = s:sub(1, buf_len - used) end
            host.write_string(memory, buf + used, s)
            used = used + #s
        end
        u32(bufused_ptr, used)
        return ERRNO.SUCCESS
    end

    function wasi.path_unlink_file(dirfd, path_ptr, path_len)
        local path, err = resolve(dirfd, path_ptr, path_len)
        if not path then return err end
        if not self.files[path] then return ERRNO.ACCES end
        self.files[path] = nil
        return ERRNO.SUCCESS
    end

    function wasi.poll_oneoff(in_ptr, out_ptr, nsubs, nevents_ptr)
        -- Ждать нельзя (однопоточный хост): все подписки считаются сработавшими сразу.
        for i = 0, nsubs - 1 do
            local sub, ev = in_ptr + i * 48, out_ptr + i * 32
            host.fill(memory, ev, 0, 32)
            host.write_i32(memory, ev, host.read_i32(memory, sub))
            host.write_i32(memory, ev + 4, host.read_i32(memory, sub + 4))
            host.write_u8(memory, ev + 10, host.read_u8(memory, sub + 8))
        end
        u32(nevents_ptr, nsubs)
        if options.sleep then options.sleep() end
        return ERRNO.SUCCESS
    end

    local reported = {}
    self.imports = setmetatable(wasi, {
        __index = function(_, name)
            return function()
                if not reported[name] then
                    reported[name] = true
                    log("wasi: " .. tostring(name) .. " is not implemented (ENOSYS)")
                end
                return ERRNO.NOSYS
            end
        end,
    })

    function self:bind(exports)
        self.exports = exports
        host = assert(exports.__host, "module has no __host export (rebuild it with a current Spider)")
        memory = assert(exports.memory, "module exports no memory")
        return self
    end

    return self
end

return M
