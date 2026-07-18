--GUIMODE=1  --用于识别GUI程序还是print程序
---------------------------------------------------------------
-- ESP Serial Flasher Lua
-- 仓库：https://github.com/MDLZCOOL/esp-serial-flasher-lua/
-- Copyright (c) 2026, MDLZCOOL
-- SPDX-License-Identifier: Apache-2.0
---------------------------------------------------------------

local PATH = "0:/H7-TOOL/Lua/ESP"

local CFG = {
    UART_PORT = 1,
    BAUD = 921600,
    EN_PIN = 2,
    BOOT_PIN = 3,
    TVCC_VOLT = 3.3,
    BLOCK_SIZE = 4096,
    FLASH_SIZE = 0x400000,
    SYNC_TRIALS = 5
}

local BAUD_LIST = {115200, 230400, 460800, 921600, 1500000}

local CHIP_LIST = {
    "Auto",
    "ESP32",
    "ESP32-S2",
    "ESP32-C3",
    "ESP32-S3",
    "ESP32-C2",
    "ESP32-C6",
    "ESP32-H2",
    "ESP32-C5",
    "ESP32-C61",
    "ESP32-P4",
    "ESP8266"
}

local CHIPS = {
    ["ESP8266"] = {enc = false, attach = "8266"},
    ["ESP32"] = {enc = false, attach = "spi"},
    ["ESP32-S2"] = {enc = true, attach = "spi"},
    ["ESP32-C3"] = {enc = true, attach = "spi"},
    ["ESP32-S3"] = {enc = true, attach = "spi"},
    ["ESP32-C2"] = {enc = true, attach = "spi"},
    ["ESP32-C6"] = {enc = true, attach = "spi"},
    ["ESP32-H2"] = {enc = true, attach = "spi"},
    ["ESP32-C5"] = {enc = true, attach = "spi"},
    ["ESP32-C61"] = {enc = true, attach = "spi"},
    ["ESP32-P4"] = {enc = true, attach = "spi"}
}

local MAGIC = {
    [0xfff0c101] = "ESP8266",
    [0x00f01d83] = "ESP32",
    [0x000007c6] = "ESP32-S2",
    [0x6921506f] = "ESP32-C3",
    [0x1b31506f] = "ESP32-C3",
    [0x4881606f] = "ESP32-C3",
    [0x4361606f] = "ESP32-C3",
    [0x00000009] = "ESP32-S3",
    [0x6f51306f] = "ESP32-C2",
    [0x7c41a06f] = "ESP32-C2",
    [0x0c21e06f] = "ESP32-C2",
    [0x1101406f] = "ESP32-C5",
    [0x5fd1406f] = "ESP32-C5",
    [0xd7b73e80] = "ESP32-H2",
    [0x2ce0806f] = "ESP32-C6",
    [0x7211606f] = "ESP32-C61"
}

-- 用于ESP32P4芯片检测，其他芯片使用ROM magic值
local MAGIC_P4_REG = 0x500d0000
local MAGIC_P4_MASK = 0x7FFFFFF
local MAGIC_P4_VAL = 0x2207202

local CMD = {
    FLASH_BEGIN = 0x02,
    FLASH_DATA = 0x03,
    MEM_BEGIN = 0x05,
    MEM_END = 0x06,
    MEM_DATA = 0x07,
    SYNC = 0x08,
    WRITE_REG = 0x09,
    READ_REG = 0x0a,
    SPI_SET_PARAMS = 0x0b,
    SPI_ATTACH = 0x0d
}

local KEY = {UP = 1, DOWN = 8, OK = 15, CANCEL = 22, HOME = 29}

local C = {
    BG = 0xFFFF,
    TEXT = 0x0000,
    TITLE_BG = 0x001F,
    TITLE_TEXT = 0xFFFF,
    HL = 0xFFE0,
    HL_TEXT = 0x0000,
    LINE = 0xCE59,
    PROG = 0x9F53,
    STATUS = 0x0000,
    GRAY = 0x8410
}

local OFFSET_PRESETS = {0x00000, 0x01000, 0x08000, 0x0E000, 0x10000, 0x100000, 0x200000, 0x300000, 0x400000}
local SCREEN_W = 240

local function le16(v)
    return string.char(v & 0xFF, (v >> 8) & 0xFF)
end
local function le32(v)
    return string.char(v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF)
end
local function tohex(v)
    return string.format("0x%X", v)
end
local function xor8(s)
    local c = 0xEF
    for i = 1, #s do
        c = (c ~ string.byte(s, i)) & 0xFF
    end
    return c
end

local function slip_encode(s)
    local out = ""
    for i = 1, #s do
        local b = string.byte(s, i)
        if b == 0xC0 then
            out = out .. "\xDB\xDC"
        elseif b == 0xDB then
            out = out .. "\xDB\xDD"
        else
            out = out .. string.char(b)
        end
    end
    return out
end

local function slip_decode(s)
    local out, i = "", 1
    while i <= #s do
        local b = string.byte(s, i)
        if b == 0xDB then
            local n = string.byte(s, i + 1)
            if n == 0xDC then
                out = out .. "\xC0"
            elseif n == 0xDD then
                out = out .. "\xDB"
            else
                out = out .. string.char(n or 0xDB)
            end
            i = i + 2
        else
            out = out .. string.char(b)
            i = i + 1
        end
    end
    return out
end

local function now_ms()
    local ok, v = pcall(get_runtime)
    if ok and v then
        return v
    end
    return os.clock() * 1000
end

-- ESP对象
local ESP = {}
ESP.__index = ESP

function ESP.new(port, baud)
    local self = setmetatable({}, ESP)
    self.port, self.baud, self.rawbuf, self.target = port, baud, "", "Auto"
    self:apply_target()
    return self
end

function ESP.apply_target(self)
    local c = CHIPS[self.target] or {enc = true, attach = "spi"}
    self.encryption_field, self.attach_method, self.block_size = c.enc, c.attach, CFG.BLOCK_SIZE
end

function ESP.fill_raw(self, t)
    local len, str = uart_recive(self.port, 200, t, 10)
    if len and len > 0 and str then
        self.rawbuf = self.rawbuf .. str
        if #self.rawbuf > 8192 then
            self.rawbuf = string.sub(self.rawbuf, -4096)
        end
    end
end

function ESP.extract_packet(self)
    local buf = self.rawbuf
    local i = string.find(buf, "\xC0", 1, true)
    if not i then
        return nil
    end
    local start = i
    while start <= #buf and string.byte(buf, start) == 0xC0 do
        start = start + 1
    end
    if start > #buf then
        self.rawbuf = ""
        return nil
    end
    local j = string.find(buf, "\xC0", start, true)
    if not j then
        return nil
    end
    local raw = string.sub(buf, start, j - 1)
    self.rawbuf = string.sub(buf, j + 1)
    return slip_decode(raw)
end

function ESP.parse_packet(self, pkt)
    if not pkt or #pkt < 10 then
        return nil
    end
    return {
        direction = string.byte(pkt, 1),
        command = string.byte(pkt, 2),
        size = string.byte(pkt, 3) | (string.byte(pkt, 4) << 8),
        value = string.byte(pkt, 5) | (string.byte(pkt, 6) << 8) | (string.byte(pkt, 7) << 16) |
            (string.byte(pkt, 8) << 24),
        failed = string.byte(pkt, #pkt - 1),
        error = string.byte(pkt, #pkt),
        resp_data = string.sub(pkt, 9, #pkt - 2)
    }
end

function ESP.read_packet(self, timeout)
    local deadline = now_ms() + timeout
    while true do
        local raw = self:extract_packet()
        if raw then
            local p = self:parse_packet(raw)
            if p then
                return p
            end
        end
        if now_ms() >= deadline then
            return nil
        end
        local t = deadline - now_ms()
        if t > 500 then
            t = 500
        end
        self:fill_raw(t)
    end
end

function ESP.send_frame(self, cmd, payload, data)
    data = data or ""
    local checksum = 0
    if #data > 0 then
        checksum = xor8(data)
    end
    local header = string.char(0x00, cmd) .. le16(#payload + #data) .. le32(checksum)
    self.rawbuf = ""
    uart_send(self.port, "\xC0" .. slip_encode(header .. payload .. data) .. "\xC0")
end

function ESP.send_command(self, cmd, payload, data, timeout)
    self:send_frame(cmd, payload, data)
    local deadline = now_ms() + (timeout or 5000)
    while true do
        local pkt = self:read_packet(timeout or 5000)
        if not pkt then
            return nil, "timeout"
        end
        if pkt.direction == 0x01 and pkt.command == cmd then
            if pkt.failed ~= 0 then
                return nil, "ERR" .. pkt.error
            end
            return pkt
        end
        if now_ms() > deadline then
            return nil, "no matching resp"
        end
    end
end

function ESP.enter_bootloader(self)
    print("开始进入下载模式...")
    if CFG.EN_PIN > 0 then
        gpio_cfg(CFG.EN_PIN, 1)
        gpio_write(CFG.EN_PIN, 1)
    end
    if CFG.BOOT_PIN > 0 then
        gpio_cfg(CFG.BOOT_PIN, 1)
        gpio_write(CFG.BOOT_PIN, 1)
    end
    delayms(50)
    if CFG.BOOT_PIN > 0 then
        gpio_write(CFG.BOOT_PIN, 0)
    end
    if CFG.EN_PIN > 0 then
        gpio_write(CFG.EN_PIN, 0)
    end
    delayms(50)
    if CFG.EN_PIN > 0 then
        gpio_write(CFG.EN_PIN, 1)
    end
    delayms(50)
    if CFG.BOOT_PIN > 0 then
        gpio_write(CFG.BOOT_PIN, 1)
    end
    delayms(100)
    print("进入下载模式时序执行完毕")
end

function ESP.release_pins(self)
    print("释放引脚并执行硬件复位...")
    if CFG.BOOT_PIN > 0 then
        gpio_write(CFG.BOOT_PIN, 1)
    end
    if CFG.EN_PIN > 0 then
        gpio_write(CFG.EN_PIN, 0)
        delayms(50)
        gpio_write(CFG.EN_PIN, 1)
    end
end

function ESP.sync(self)
    print("开始发送 SYNC 握手指令...")
    local seq = "\x07\x07\x12\x20" .. string.rep("\x55", 32)
    self:send_frame(CMD.SYNC, seq)
    for attempt = 1, CFG.SYNC_TRIALS do
        print("  SYNC 第 " .. attempt .. " 次尝试...")
        local ok = false
        for _ = 1, 8 do
            local pkt = self:read_packet(400)
            if pkt and pkt.direction == 0x01 and pkt.command == CMD.SYNC and pkt.failed == 0 then
                ok = true
                break
            end
        end
        if ok then
            print("SYNC 握手成功！")
            return true
        end
        delayms(120)
        self:send_frame(CMD.SYNC, seq)
    end
    print("SYNC 握手失败，请检查接线，或者降低波特率")
    return false
end

function ESP.detect_chip(self)
    print("开始读取芯片识别寄存器...")
    local chip_name = nil

    local pkt = self:send_command(CMD.READ_REG, le32(0x40001000), nil, 4000)
    if pkt and pkt.value then
        print(string.format("读到寄存器值: 0x%08X", pkt.value))
        chip_name = MAGIC[pkt.value]
    else
        print("读取 ROM magic 值超时或失败！")
    end

    if not chip_name then
        print("尝试 ESP32P4 寄存器...")
        local p4 = self:send_command(CMD.READ_REG, le32(MAGIC_P4_REG), nil, 4000)
        if p4 and p4.value then
            print(string.format("ESP32P4 寄存器值: 0x%08X", p4.value))
            if (p4.value & MAGIC_P4_MASK) == MAGIC_P4_VAL then
                chip_name = "ESP32-P4"
            end
        else
            print("读取 ESP32P4 寄存器超时或失败！")
        end
    end

    if chip_name then
        self.target = chip_name
        self:apply_target()
        print("成功识别到芯片: " .. chip_name)
        return chip_name
    end

    print("芯片识别失败，未找到匹配的芯片型号！")
    return nil
end

function ESP.spi_attach(self)
    print("执行 SPI ATTACH...")
    if self.attach_method == "8266" then
        return self:send_command(CMD.FLASH_BEGIN, le32(0) .. le32(0) .. le32(0) .. le32(0), nil, 5000)
    else
        return self:send_command(CMD.SPI_ATTACH, le32(0) .. le32(0), nil, 5000)
    end
end

function ESP.spi_set_params(self)
    print("执行 SPI SET PARAMS...")
    return self:send_command(
        CMD.SPI_SET_PARAMS,
        le32(0) .. le32(CFG.FLASH_SIZE) .. le32(0x10000) .. le32(0x1000) .. le32(0x100) .. le32(0xFFFF),
        nil,
        5000
    )
end

function ESP.flash_begin(self, offset, erase_size, block_size, num_blocks)
    print(string.format("FLASH_BEGIN: 偏移=0x%X, 擦除大小=%d, 块大小=%d, 块数=%d", offset, erase_size, block_size, num_blocks))
    local payload =
        le32(erase_size) ..
        le32(num_blocks) .. le32(block_size) .. le32(offset) .. (self.encryption_field and le32(0) or "")
    return self:send_command(CMD.FLASH_BEGIN, payload, nil, 30000)
end

function ESP.flash_data(self, seq, data)
    return self:send_command(CMD.FLASH_DATA, le32(#data) .. le32(seq) .. le32(0) .. le32(0), data, 20000)
end

local function calc_erase_8266(offset, image_size)
    local num_sectors = math.ceil(image_size / 4096)
    local head_sectors = 16 - (math.floor(offset / 4096) % 16)
    if num_sectors <= head_sectors then
        return math.floor((num_sectors + 1) / 2) * 4096
    else
        return (num_sectors - head_sectors) * 4096
    end
end

function ESP.flash_one(self, job, on_progress, idx, total)
    print("\n========= 开始处理烧录任务: " .. job.name .. " =========")
    print("指定的目标文件路径为: " .. job.path)

    local fsize = f_size(job.path)
    print("f_size 返回值: " .. tostring(fsize))

    if not fsize or fsize <= 0 then
        print("读取不到文件大小！路径有误或处于U盘模式")
        return false, "文件为空或不存在: " .. job.name
    end

    print(string.format("文件大小为: %d 字节 (%.2f KB)", fsize, fsize / 1024))

    local bs = (self.target == "ESP8266") and 1024 or self.block_size
    local es = (self.target == "ESP8266") and calc_erase_8266(job.offset, fsize) or fsize

    if not self:flash_begin(job.offset, es, bs, math.ceil(fsize / bs)) then
        print("FLASH_BEGIN 命令被芯片拒绝")
        return false, "FLASH_BEGIN 失败"
    end

    local seq, addr = 0, 0
    print("开始传输数据块...")
    while addr < fsize do
        local chunk = math.min(bs, fsize - addr)
        local _, bin = f_read(job.path, addr, chunk)
        if not bin or #bin == 0 then
            return false, "读文件内容失败 @0x" .. tohex(addr)
        end
        if (fsize - addr) == chunk and (#bin % 4 ~= 0) then
            bin = bin .. string.rep("\xFF", 4 - (#bin % 4))
        end
        if not self:flash_data(seq, bin) then
            return false, "写数据失败 @块" .. seq
        end
        seq, addr = seq + 1, addr + #bin
        if on_progress then
            on_progress(
                math.floor(addr * 100 / fsize),
                string.format("段%d/%d %s %d/%d", idx, total, job.name, addr, fsize)
            )
        end
    end
    print("数据块传输完毕，文件烧录完成")

    return true
end

function ESP.flash_all(self, jobs, expected_chip, on_progress)
    print("\n>>>>>>>>>>> 烧录启动 <<<<<<<<<<<")
    if #jobs == 0 then
        return false, "没有固件任务"
    end
    self:enter_bootloader()
    uart_clear_rx(self.port)
    if not self:sync() then
        self:release_pins()
        return false, "同步失败"
    end
    
    local name = self:detect_chip()
    if not name then
        self:release_pins()
        return false, "未识别到芯片"
    end
    if expected_chip ~= "Auto" and name ~= expected_chip then
        self:release_pins()
        return false, "选中[" .. expected_chip .. "] 实际[" .. name .. "]"
    end
    
    self.target = name
    self:apply_target()
    
    if on_progress then
        on_progress(0, "芯片: " .. name)
    end
    
    if not self:spi_attach() then
        self:release_pins()
        return false, "SPI ATTACH 失败"
    end
    if not self:spi_set_params() then
        self:release_pins()
        return false, "SPI SET_PARAMS 失败"
    end

    for i, job in ipairs(jobs) do
        local ok, msg = self:flash_one(job, on_progress, i, #jobs)
        if not ok then
            self:release_pins()
            return false, msg
        end
    end

    self:release_pins()
    if on_progress then
        on_progress(100, "完成")
    end
    print(">>>>>>>>>>> 烧录结束 <<<<<<<<<<<")
    return true, "完成"
end

-- UI和逻辑交互
local ui = {}
local esp = ESP.new(CFG.UART_PORT, CFG.BAUD)

local state = {
    chip_idx = 1, -- 默认 Auto
    baud_idx = 1, -- 默认 115200 波特率
    sel = 1,
    progress = 0,
    status = "就绪",
    busy = false,
    jobs = {
        {name = "bootloader.bin", path = PATH .. "/bootloader.bin", offset = 0x0000},
        {name = "partition-table.bin", path = PATH .. "/partition-table.bin", offset = 0x8000},
        {name = "firmware.bin", path = PATH .. "/firmware.bin", offset = 0x10000}
    }
}

local function cls()
    lcd_clr(C.BG)
end
local function text(x, y, s, size, fc, bc, align, w)
    lcd_disp_str(x, y, s, size or 16, fc or C.TEXT, bc or C.BG, w or SCREEN_W, align or 0)
end
local function bar(x, y, w, h, color)
    lcd_fill_rect(x, y, h, w, color)
end
local function line(x1, y1, x2, y2, color)
    lcd_draw_line(x1, y1, x2, y2, color)
end

local function chip_name()
    return CHIP_LIST[state.chip_idx]
end

local function menu_items()
    local items = {}
    table.insert(items, {type = "chip"})
    table.insert(items, {type = "baud"})
    for i = 1, #state.jobs do
        table.insert(items, {type = "job", idx = i})
    end
    table.insert(items, {type = "flash"})
    table.insert(items, {type = "exit"})
    return items
end

local function draw_menu()
    cls()
    bar(0, 0, SCREEN_W, 20, C.TITLE_BG)
    text(0, 2, "ESP Serial Flasher", 16, C.TITLE_TEXT, C.TITLE_BG, 1, SCREEN_W)
    line(0, 20, SCREEN_W - 1, 20, C.LINE)

    local items = menu_items()
    if state.sel > #items then
        state.sel = #items
    end
    if state.sel < 1 then
        state.sel = 1
    end

    local y = 26
    for i, it in ipairs(items) do
        local selected = (i == state.sel)
        local fc = selected and C.HL_TEXT or C.TEXT
        local bc = selected and C.HL or C.BG

        if it.type == "chip" then
            if selected then bar(0, y - 1, SCREEN_W, 16, C.HL) end
            text(2, y, "芯片型号 : " .. chip_name(), 16, fc, bc, 0, SCREEN_W - 2)
            y = y + 17
        elseif it.type == "baud" then
            if selected then bar(0, y - 1, SCREEN_W, 16, C.HL) end
            text(2, y, "波特率   : " .. BAUD_LIST[state.baud_idx], 16, fc, bc, 0, SCREEN_W - 2)
            y = y + 17
        elseif it.type == "job" then
            if selected then bar(0, y - 1, SCREEN_W, 16, C.HL) end
            local j = state.jobs[it.idx]
            text(2, y, string.format("%d.", it.idx), 16, fc, bc, 0, 22)
            local n_str = j.name
            if #n_str > 22 then
                n_str = string.sub(n_str, 1, 20) .. ".."
            end
            text(24, y + 2, n_str, 12, fc, bc, 0, 136)
            text(160, y, string.format("@0x%X", j.offset), 16, fc, bc, 0, 80)
            y = y + 17
            
        elseif it.type == "flash" then
            local half_w = math.floor(SCREEN_W / 2)
            if selected then bar(0, y - 1, half_w, 16, C.HL) end
            text(0, y, "[ 开始烧录 ]", 16, fc, bc, 1, half_w)
            
        elseif it.type == "exit" then
            local half_w = math.floor(SCREEN_W / 2)
            if selected then bar(half_w, y - 1, SCREEN_W - half_w, 16, C.HL) end
            text(half_w, y, "[   退出   ]", 16, fc, bc, 1, SCREEN_W - half_w)
            y = y + 17 
        end

        if y > 145 then break end
    end

    text(0, 147, "接线：TTLTX-TX，TTLRX-RX", 16, C.TEXT, C.BG)
    text(0, 164, "      D2-EN，D3-IO0", 16, C.TEXT, C.BG)
    text(0, 181, "固件目录：", 16, C.TEXT, C.BG)
    text(0, 198, string.format("%s", PATH), 16, C.TEXT, C.BG)

    bar(0, 214, SCREEN_W, 2, C.LINE)
    if state.progress > 0 then
        bar(0, 214, math.floor(SCREEN_W * state.progress / 100), 2, C.PROG)
    end
    text(0, 220, state.status, 12, C.STATUS, C.BG)
    lcd_refresh()
end

local function update_progress(pct, status)
    state.progress, state.status = pct, status or state.status
    bar(0, 214, SCREEN_W, 2, C.LINE)
    if pct > 0 then
        bar(0, 214, math.floor(SCREEN_W * pct / 100), 2, C.PROG)
    end
    text(0, 220, state.status, 12, C.STATUS, C.BG)
    lcd_refresh()
end

local function wait_key()
    while true do
        local k = get_key()
        if k == KEY.UP or k == KEY.DOWN or k == KEY.OK or k == KEY.CANCEL or k == KEY.HOME then
            return k
        end
        delayms(20)
    end
end

local function handle_menu_key(k)
    local items = menu_items()
    if k == KEY.UP then
        state.sel = state.sel - 1
        if state.sel < 1 then
            state.sel = #items
        end
        draw_menu()
    elseif k == KEY.DOWN then
        state.sel = state.sel + 1
        if state.sel > #items then
            state.sel = 1
        end
        draw_menu()
    elseif k == KEY.OK then
        local it = items[state.sel]
        if not it then
            return
        end
        if it.type == "chip" then
            state.chip_idx = (state.chip_idx % #CHIP_LIST) + 1
            esp.target = CHIP_LIST[state.chip_idx]
            esp:apply_target()
            draw_menu()
        elseif it.type == "baud" then
            state.baud_idx = (state.baud_idx % #BAUD_LIST) + 1
            esp.baud = BAUD_LIST[state.baud_idx]
            uart_cfg(esp.port, esp.baud, 0, 8, 1)
            draw_menu()
        elseif it.type == "job" then
            local j = state.jobs[it.idx]
            for i, v in ipairs(OFFSET_PRESETS) do
                if v == j.offset then
                    j.offset = OFFSET_PRESETS[(i % #OFFSET_PRESETS) + 1]
                    break
                end
            end
            draw_menu()
        elseif it.type == "flash" then
            start_flash()
        elseif it.type == "exit" then
            state.busy = true
        end
    elseif k == KEY.CANCEL then
    elseif k == KEY.HOME then
        state.busy = true
    end
end

function start_flash()
    if #state.jobs == 0 then
        state.status = "请先添加固件"
        draw_menu()
        return
    end
    state.busy, state.progress, state.status = true, 0, "连接中..."
    update_progress(0, state.status)
    beep()

    local expected_chip = CHIP_LIST[state.chip_idx]
    
    local ok, msg =
        esp:flash_all(
        state.jobs,
        expected_chip,
        function(pct, st)
            update_progress(pct, st)
        end
    )

    state.busy = false
    if ok then
        state.status = "烧写成功! " .. msg
        state.progress = 100
        beep()
        delayms(120)
        beep()
    else
        state.status = "失败: " .. msg
        state.progress = 0
        print("失败: " .. msg)
    end
    update_progress(state.progress, state.status)
    delayms(1500)
    draw_menu()
end

local function main()
    delayms(300)
    for i = 1, 20 do
        get_key()
        delayms(10)
    end
    clear_key()

    set_tvcc(CFG.TVCC_VOLT)
    uart_cfg(esp.port, esp.baud, 0, 8, 1)
    uart_clear_rx(esp.port)
    esp.target = CHIP_LIST[state.chip_idx]
    esp:apply_target()

    draw_menu()

    while true do
        local k = wait_key()
        handle_menu_key(k)
        if state.busy then
            break
        end
    end

    print("退出 ESP Serial Flasher")
    delayms(500)
    clear_key()
end

main()