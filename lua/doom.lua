-- /doom: real Doom (ozkl/doomgeneric) rendered into a maki float via Buf:blit.
-- First run bootstraps under state_dir()/doom: clone, compile, shareware WAD.

local REPO_URL = "https://github.com/ozkl/doomgeneric"
local WAD_URL = "https://github.com/Akbar30Bill/DOOM_wads/raw/master/doom1.wad"
local BIN_NAME = "maki-doom"
local WAD_NAME = "doom1.wad"

local CLONE_TIMEOUT_MS = 180000
local COMPILE_TIMEOUT_MS = 300000
local WAD_TIMEOUT_MS = 180000
local FRAME_MS = 16
local FILTER = "sharp" -- "smooth" blends pixels when downscaling (softer look)
local MAX_KEY_EVENTS = 32

local CFLAGS = "-O2 -DNORMALUNIX -DLINUX -DSNDSERV -D_DEFAULT_SOURCE"
  .. " -DDOOMGENERIC_RESX=320 -DDOOMGENERIC_RESY=200"

-- Makefile SRC_DOOM minus the doomgeneric_xlib.o backend, plus our shim.
local SOURCES = "dummy.c am_map.c doomdef.c doomstat.c dstrings.c d_event.c"
  .. " d_items.c d_iwad.c d_loop.c d_main.c d_mode.c d_net.c f_finale.c"
  .. " f_wipe.c g_game.c hu_lib.c hu_stuff.c info.c i_cdmus.c i_endoom.c"
  .. " i_joystick.c i_scale.c i_sound.c i_system.c i_timer.c memio.c m_argv.c"
  .. " m_bbox.c m_cheat.c m_config.c m_controls.c m_fixed.c m_menu.c m_misc.c"
  .. " m_random.c p_ceilng.c p_doors.c p_enemy.c p_floor.c p_inter.c"
  .. " p_lights.c p_map.c p_maputl.c p_mobj.c p_plats.c p_pspr.c p_saveg.c"
  .. " p_setup.c p_sight.c p_spec.c p_switch.c p_telept.c p_tick.c p_user.c"
  .. " r_bsp.c r_data.c r_draw.c r_main.c r_plane.c r_segs.c r_sky.c"
  .. " r_things.c sha1.c sounds.c statdump.c st_lib.c st_stuff.c s_sound.c"
  .. " tables.c v_video.c wi_stuff.c w_checksum.c w_file.c w_main.c w_wad.c"
  .. " z_zone.c w_file_stdc.c i_input.c i_video.c doomgeneric.c"
  .. " doomgeneric_maki.c"

-- doomkeys.h codes.
local K_UP, K_DOWN, K_LEFT, K_RIGHT = 0xad, 0xaf, 0xac, 0xae
local K_STRAFE_L, K_STRAFE_R, K_USE, K_FIRE = 0xa0, 0xa1, 0xa2, 0xa3
local KEYMAP = {
  up = K_UP,
  down = K_DOWN,
  left = K_LEFT,
  right = K_RIGHT,
  w = K_UP,
  s = K_DOWN,
  a = K_STRAFE_L,
  d = K_STRAFE_R,
  f = K_FIRE,
  ["ctrl+f"] = K_FIRE,
  space = K_USE,
  e = K_USE,
  enter = 13,
  esc = 27,
  tab = 9,
  backspace = 0x7f,
}

local function to_doom_key(key)
  local code = KEYMAP[key]
  if code then
    return code
  end
  if #key == 1 then
    local b = string.byte(key:lower())
    if b >= 32 and b < 127 then
      return b
    end
  end
  return nil
end

local function exists(path)
  return maki.fs.metadata(path) ~= nil
end

local function log(buf, text, style)
  buf:line({ { text, style or "dim" } })
end

local function fail(win, buf, msg)
  log(buf, "error: " .. msg, "error")
  log(buf, "press any key to close")
  win:recv()
  return false
end

local function run_step(buf, cmd, cwd, timeout_ms, env)
  local on_line = function(_, line)
    log(buf, line)
  end
  local job = maki.fn.jobstart(cmd, {
    cwd = cwd,
    env = env,
    on_stdout = on_line,
    on_stderr = on_line,
  })
  local result = maki.fn.jobwait(job, timeout_ms)
  if not result then
    maki.fn.jobstop(job)
    return false, "timed out: " .. cmd
  end
  if result.exit_code ~= 0 then
    return false, "exit code " .. result.exit_code .. ": " .. cmd
  end
  return true
end

local function bootstrap(win, buf, state)
  local bin = maki.fs.joinpath(state, BIN_NAME)
  local wad = maki.fs.joinpath(state, WAD_NAME)
  if exists(bin) and exists(wad) then
    return true
  end

  for _, tool in ipairs({ "git", "cc", "curl" }) do
    if maki.fn.executable(tool) == 0 then
      return fail(win, buf, "`" .. tool .. "` not found on PATH, install it and rerun /doom")
    end
  end
  maki.fs.mkdir(state, { parents = true })

  local clone = maki.fs.joinpath(state, "doomgeneric")
  local srcdir = maki.fs.joinpath(clone, "doomgeneric")
  if not exists(maki.fs.joinpath(srcdir, "doomgeneric.c")) then
    log(buf, "cloning doomgeneric...")
    local ok, err = run_step(buf, "git clone --depth 1 " .. REPO_URL .. " '" .. clone .. "'", state, CLONE_TIMEOUT_MS)
    if not ok then
      return fail(win, buf, err)
    end
  end

  if not exists(bin) then
    local ok, err = maki.fs.write(maki.fs.joinpath(srcdir, "doomgeneric_maki.c"), require("doom_shim"))
    if err then
      return fail(win, buf, "writing shim: " .. err)
    end
    log(buf, "compiling (may take ~30s)...")
    ok, err = run_step(buf, "cc " .. CFLAGS .. " " .. SOURCES .. " -o '" .. bin .. "' -lm", srcdir, COMPILE_TIMEOUT_MS)
    if not ok then
      return fail(win, buf, err)
    end
  end

  if not exists(wad) then
    log(buf, "downloading shareware " .. WAD_NAME .. " (~4MB)...")
    local ok, err = run_step(buf, "curl -fSL -o '" .. wad .. "' " .. WAD_URL, state, WAD_TIMEOUT_MS)
    if not ok then
      return fail(win, buf, err)
    end
    local bytes = maki.fs.read_bytes(wad)
    if not bytes or buffer.len(bytes) < 4 or buffer.readstring(bytes, 0, 4) ~= "IWAD" then
      maki.fs.rm(wad)
      return fail(win, buf, WAD_NAME .. " download is not a valid IWAD")
    end
  end

  log(buf, "ready, starting...")
  return true
end

local function make_run_dir()
  local base = exists("/dev/shm") and "/dev/shm" or maki.env.state_dir()
  local dir = maki.fs.joinpath(base, "maki-doom-" .. os.time())
  local ok, err = maki.fs.mkdir(dir, { parents = true })
  if not ok then
    return nil, err
  end
  return dir
end

local function run_game(win, buf, state, run_dir)
  local px_w, px_h = win.width, win.height * 2
  local frame_bin = maki.fs.joinpath(run_dir, "frame.bin")
  local keys_path = maki.fs.joinpath(run_dir, "keys")
  local frame_size = px_w * px_h * 4
  local file_size = frame_size + 4
  local last_frame_seq = -1
  local pixels = buffer.create(frame_size)

  local exited = false
  local job = maki.fn.jobstart("exec ./" .. BIN_NAME .. " -iwad " .. WAD_NAME, {
    cwd = state,
    env = {
      MAKI_DOOM_DIR = run_dir,
      MAKI_DOOM_W = tostring(px_w),
      MAKI_DOOM_H = tostring(px_h),
      MAKI_DOOM_FILTER = FILTER,
    },
    on_stderr = function(_, line)
      maki.log.warn("doom: " .. line)
    end,
    on_exit = function()
      exited = true
    end,
  })

  local seq = 0
  local events = {}
  while not exited do
    local ev = win:recv(FRAME_MS)
    if not ev or ev.type == "close" then
      break
    end
    if ev.type == "timeout" then
      local fb = maki.fs.read_bytes(frame_bin)
      if fb and buffer.len(fb) == file_size then
        local frame_seq = buffer.readu32(fb, frame_size)
        if frame_seq ~= last_frame_seq then
          last_frame_seq = frame_seq
          buffer.copy(pixels, 0, fb, 0, frame_size)
          buf:blit(pixels, px_w, px_h, { format = "bgra" })
        end
      end
    elseif ev.type == "key" then
      if ev.key == "q" then
        break
      end
      local code = to_doom_key(ev.key)
      if code then
        seq = seq + 1
        events[#events + 1] = seq .. " " .. code .. "\n"
        if #events > MAX_KEY_EVENTS then
          table.remove(events, 1)
        end
        maki.fs.write(keys_path, table.concat(events))
      end
    end
  end
  maki.fn.jobstop(job)
end

maki.api.register_command({
  name = "/doom",
  description = "Play Doom (shareware) in a floating window",
  handler = function()
    local state = maki.fs.joinpath(maki.env.state_dir(), "doom")

    local size = maki.ui.terminal_size()
    local w = size.cols - 2
    local h = math.floor(w * 200 / 320 / 2)
    local max_h = size.rows - 2
    if h > max_h then
      h = max_h
      w = math.floor(h * 2 * 320 / 200)
    end

    local buf = maki.ui.buf()
    local win = maki.ui.open_win(buf, {
      title = "DOOM",
      width = w,
      height = h,
      footer = { { "q", "quit" }, { "esc", "menu" } },
    })
    maki.ui.set_status_hint({ { "q", "quit" }, { "esc", "menu" } })

    local run_dir
    if bootstrap(win, buf, state) then
      local err
      run_dir, err = make_run_dir()
      if run_dir then
        run_game(win, buf, state, run_dir)
      else
        fail(win, buf, "creating run dir: " .. tostring(err))
      end
    end

    win:close()
    maki.ui.set_status_hint(nil)
    if run_dir then
      maki.fn.jobstart("rm -rf '" .. run_dir .. "'")
    end
  end,
})
