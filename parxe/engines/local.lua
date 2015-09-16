--[[
  PARalel eXecution Engine (PARXE) for APRIL-ANN
  Copyright (C) 2015  Francisco Zamora-Martinez

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <http://www.gnu.org/licenses/>.
]]
local common   = require "parxe.common"
local config   = require "parxe.config"
local future   = require "parxe.future"
local xe       = require "xemsg"
local xe_utils = require "parxe.xemsg_utils"

local parallel_engine_wait_method = common.parallel_engine_wait_method
local serialize   = xe_utils.serialize
local deserialize = xe_utils.deserialize

---------------------------------------------------------------------------
-- TMPNAME allows to identify this server, allowing to execute several servers
-- in the same host. The hash part is the particular random sequence of
-- characters generated by Lua to distinguish the tmpname file. This hash part
-- is used to  identify client connections in order to assert possible errors.
local TMPNAME = os.tmpname()
local HASH    = TMPNAME:match("^.*lua_(.*)$")

-- nanomsg URI connection, using IPC transport
local URI = "ipc://"..TMPNAME

-- number of cores available in local machine
local num_cores = tonumber( assert( io.popen("getconf _NPROCESSORS_ONLN") ):read("*l") )

-- A table with all the futures related with executed processes. The table is
-- indexed as a dictionary using task_id as keys.
local pending_futures = {}

-- A list of tasks pending of execution.
local pending_tasks = {}

-- A dictionary with PID keys of all workers currently executing work
local running_workers = {}
local num_running_workers = 0 -- it should be less or equal to num_cores

-- Used in xe.poll() function.
local poll_fds = {}

-- server socket binded to URI address
local server,endpoint
local function init(force)
  if not server or force then
    server = assert( xe.socket(xe.NN_REP) )
    endpoint = assert( server:bind(URI) )
    -- Used in xe.poll() function.
    poll_fds[1] = { fd = server, events = xe.NN_POLLIN }
  end
end
  

----------------------------- check worker helpers ---------------------------

-- given a future object, serializes its associated task by means of server
-- SP socket
local function send_task(f)
  local task = f.task
  serialize(task, server)
  f.task    = nil
  f.host    = "localhost"
  f._state_ = future.RUNNING_STATE
end

-- given a worker reply, returns a true to the worker and process the result
-- modifying its corresponding future object; additionally it waits until worker
-- process termination
local function process_reply(r)
  serialize(true, server)
  local f = pending_futures[r.id]
  pending_futures[r.id] = nil
  running_workers[r.pid] = nil
  f._result_ = r.result or {false}
  f._err_    = r.err
  util.wait()
  assert(f.pid == r.pid)
  assert(f.task_id == r.id)
  num_running_workers = num_running_workers - 1
end

-- reads a message request from socket s and executes the corresponding
-- response, which can be send_task or process_reply
local function process_message(s, revents)
  assert(revents == xe.NN_POLLIN)
  if revents == xe.NN_POLLIN then
    local cmd = deserialize(s)
    if cmd.request then
      -- task request, send a reply with the task
      send_task(pending_futures[running_workers[cmd.pid]])
    elseif cmd.reply then
      -- task reply, read task result and send ack
      process_reply(cmd)
      if cmd.err then fprintf(io.stderr, "ERROR IN TASK %d: %s\n", cmd.id, cmd.err) end
      return true
    else
      error("Incorrect command")
    end
  end
end

-- Executes the worker with a given task description in a new background
-- process. Uses nohup to send the process in background. Additionally, fills
-- the corresponding future object with _stdout_ and _stderr_ filenames and
-- keeps tracks of the new running worker.
local function execute_worker(task)
  --local which,pid = util.split_process(2)
  --if not pid then
  local file = assert(arg[-1], "Unable to locate executable at arg[-1]")
  local tmp = config.tmp()
  local tmpname = "%s/PX_%s_%06d_%s"%{tmp,HASH,task.id,os.date("%Y%m%d%H%M%S")}
  local f = pending_futures[task.id]
  f._stdout_ = tmpname..".OU"
  f._stderr_ = tmpname..".ER"
  local cmd = "nohup %s -l %s -e \"RUN_WORKER('%s')\" > %s 2> %s & echo $!"%
    { file, "parxe.engines.workers.local_worker_script", URI,
      f._stdout_, f._stderr_  }
  local pipe = io.popen(cmd)
  local pid = tonumber(pipe:read("*l"))
  pipe:close()
  --end
  assert(pid >= 0, "Unexpected PID < 0")
  -- parent code, keep track of pid and task_id for error checking
  f.pid  = pid
  f.time = common.gettime()
  running_workers[pid] = task.id
  num_running_workers  = num_running_workers + 1
end

------------------------ check worker function -------------------------------

-- This function is the main one for future objects produced by local engine.
-- This function is responsible of execute workers associated with pending
-- tasks, look-up for new incoming messages and dispatch its response by using
-- process_message function.
local function check_worker()
  while #pending_tasks > 0 and num_running_workers < num_cores do
    execute_worker(table.remove(pending_tasks, 1))
  end
  -- TODO: error checking
  -- for pid,task_id in pairs(running_workers) do
  --   assert( os.execute("kill 0 " .. pid) )
  -- end
  repeat
    local n = assert( xe.poll(poll_fds) )
    if n > 0 then
      for i,r in ipairs(poll_fds) do
        if r.events == r.revents then
          process_message(r.fd, r.revents)
          r.revents = nil
        end
      end
    end
  until n == 0
  collectgarbage("collect")
end

---------------------------------------------------------------------------

-- The local engine class, exported as result of this module.
local local_engine,local_engine_methods = class("parxe.engine.local")
function local_engine:constructor()
end

function local_engine:destructor()
  if server then
    server:shutdown(endpoint)
    server:close()
    xe.term()
    util.wait()
  end
  os.remove(TMPNAME)
end

function local_engine_methods:execute(func, ...)
  init()
  local args = table.pack(...)
  local f    = future(check_worker)
  f.task_id  = common.next_task_id()
  f.task     = { id=f.task_id, func=func, args=args, wd=config.wd() }
  pending_futures[f.task_id] = f
  table.insert(pending_tasks, f.task)
  return f
end

function local_engine_methods:wait()
  parallel_engine_wait_method(pending_futures)
end

function local_engine_methods:get_max_tasks() return num_cores end

----------------------------------------------------------------------------

local singleton = local_engine() -- local variable taken from the header of this file
class.extend_metamethod(local_engine, "__call", function() return singleton end)
return singleton
