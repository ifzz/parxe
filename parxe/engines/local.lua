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
--]]
local common   = require "parxe.common"
local config   = require "parxe.config"
local xe       = require "xemsg"

---------------------------------------------------------------------------
-- TMPNAME allows to identify this server, allowing to execute several servers
-- in the same host. The hash part is the particular random sequence of
-- characters generated by Lua to distinguish the tmpname file. This hash part
-- is used to  identify client connections in order to assert possible errors.
local TMPNAME  = os.tmpname()
local HASH     = TMPNAME:match("^.*lua_(.*)$")

-- nanomsg URI connection, using IPC transport
local URI = "ipc://"..TMPNAME

-- number of cores available in local machine
local num_cores = tonumber( assert( io.popen("getconf _NPROCESSORS_ONLN") ):read("*l") )

-- A dictionary with PID keys of all workers currently executing work
local running_workers = {}
local num_running_workers = 0 -- it should be less or equal to num_cores

---------------------------------------------------------------------------

-- Forward declaration of server socket and binded endpoint identifier
local server,endpoint,server_url,client_url

local local_class,local_methods = class("parxe.engine.local")

function local_class:constructor()
end

function local_class:destructor()
  if server then
    server:shutdown(endpoint)
    server:close()
  end
  os.remove(TMPNAME)
end

function local_methods:init()
  if not server then
    server = assert( xe.socket(xe.NN_REP) )
    endpoint = assert( server:bind(URI) )
  end
  return server
end

function local_methods:abort(task)
  error("Not implemented")
end

function local_methods:check_asserts(cmd)
  assert(cmd.hash == HASH,
         "Warning: unknown hash identifier, check that every server has a different port\n")
end

function local_methods:acceptting_tasks()
  return num_running_workers < num_cores
end

-- Executes local passing it the worker script and resources
-- configuration.
function local_methods:execute(task, stdout, stderr)
  -- local which,pid = util.split_process(2)
  -- if not pid then
  local file = assert(arg[-1], "Unable to locate executable at arg[-1]")
  local cmd = "nohup %s -l %s -e \"RUN_WORKER('%s','%s',%d)\" > %s 2> %s & echo $!"%
    { file, "parxe.worker", URI, HASH, task.id,
      stdout, stderr }
  local pipe = io.popen(cmd)
  local pid = tonumber(pipe:read("*l"))
  pipe:close()
  --end
  assert(pid >= 0, "Unexpected PID < 0")
  -- parent code, keep track of pid and task_id for error checking
  running_workers[pid] = task.id
  num_running_workers  = num_running_workers + 1
  task.pid = pid
end

function local_methods:finished(task)
  running_workers[task.pid] = nil
  num_running_workers = num_running_workers - 1
end

function local_methods:get_max_tasks() return num_cores end

----------------------------------------------------------------------------

local singleton = local_class()
class.extend_metamethod(local_class, "__call", function() return singleton end)
return singleton
