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
local TMPNAME  = os.tmpname()
local HASH     = TMPNAME:match("^.*lua_(.*)$")
local HOSTNAME = common.hostname()
---------------------------------------------------------------------------

local pbs,pbs_methods = class("parxe.engine.pbs")

---------------------------------------------------------------------------

-- Used in xe.poll() function.
local poll_fds = {}

-- A table with all the futures related with executed processes. The table is
-- indexed as a dictionary using PBS jobids as keys.
local pending_futures = {}

-- Table with all allowed resources for PBS configuration. They can be setup
-- by means of set_resource method in pbs engine object.
local allowed_resources = { mem=true, q=true, name=true, omp=true,
                            appname=true, host=true, properties = true }
-- Value of resources for PBS configuration.
local resources = { appname="april-ann", host=HOSTNAME, port=1234, omp=1,
                    mem="1g" }
-- Lines of shell script to be executed by PBS script before running worker
local shell_lines = {}

---------------------------------------------------------------------------

-- Forward declaration of server socket and binded endpoint identifier
local server,endpoint
-- initializes the nanomsg SP socket for REQ/REP pattern
local function init(port)
  if not server or port then
    server = assert( xe.socket(xe.NN_REP) )
    endpoint = assert( xe.bind(server, "tcp://*:%d"%{resources.port}) )
    poll_fds[1] = { fd = server, events = xe.NN_POLLIN }
  end
end

local function concat_properties(props)
  if not props or #props==0 then return "" end
  return ":" .. table.concat(props, ":")
end

-- Executes qsub passing it the worker script and resources
-- configuration. Returns the jobid of the queued worker.
local function execute_qsub(wd, tmpname, f)
  local qsub_in,qsub_out = assert( io.popen2("qsub -N %s"%{resources.name or tmpname}) )
  qsub_in:write("#PBS -l nice=19\n")
  qsub_in:write("#PBS -l nodes=1:ppn=%d%s,mem=%s\n"%{resources.omp,
                                                     concat_properties(resources.properties),
                                                     resources.mem})
  if resources.q then qsub_in:write("#PBS -q %s\n"%{resources.q}) end
  qsub_in:write("#PBS -m a\n")
  qsub_in:write("#PBS -o %s\n"%{f._stdout_})
  qsub_in:write("#PBS -e %s\n"%{f._stderr_})
  for _,v in pairs(shell_lines) do qsub_in:write("%s\n"%{v}) end
  qsub_in:write("cd %s\n"%{wd})
  qsub_in:write("export OMP_NUM_THREADS=%d\n"%{resources.omp})
  qsub_in:write("export PARXE_SERVER=%s\n"%{resources.host})
  qsub_in:write("export PARXE_SERVER_PORT=%d\n"%{resources.port})
  qsub_in:write("export PARXE_HASH=%s\n"%{HASH})
  qsub_in:write("echo \"# SERVER_HOSTNAME: %s\"\n"%{HOSTNAME})
  qsub_in:write("echo \"# WORKER_HOSTNAME: $(hostname)\"\n")
  qsub_in:write("echo \"# DATE:     $(date)\"\n")
  qsub_in:write("echo \"# SERVER:   %s\"\n"%{resources.host})
  qsub_in:write("echo \"# PORT:     %d\"\n"%{resources.port})
  qsub_in:write("echo \"# HASH:     %s\"\n"%{HASH})
  qsub_in:write("echo \"# TMPNAME:  %s\"\n"%{tmpname})
  qsub_in:write("echo \"# APPNAME:  %s\"\n"%{resources.appname})
  qsub_in:write("%s -l parxe.engines.workers.pbs_worker_script -e ''\n"%{
               resources.appname,
  })
  qsub_in:close()
  local jobid = qsub_out:read("*l")
  qsub_out:close()
  return jobid
end


----------------------------- check worker helpers ---------------------------

-- given a future object, serializes its associated task by means of server
-- SP socket
local function send_task(f, host)
  local task = f.task
  serialize(task, server)
  f.task    = nil
  f.host    = host
  f._state_ = future.RUNNING_STATE
end

-- given a worker reply, returns a true to the worker and process the result
-- modifying its corresponding future object
local function process_reply(r)
  serialize(true, server)
  local f = pending_futures[r.jobid]
  pending_futures[r.id] = nil
  f._result_ = r.result or {false}
  f._err_    = r.err
  assert(f.jobid == r.jobid)
  assert(f.task_id == r.id)
end

-- reads a message request from socket s and executes the corresponding response
local function process_message(s, revents)
  assert(revents == xe.NN_POLLIN)
  if revents == xe.NN_POLLIN then
    local cmd = deserialize(s)
    assert(cmd.hash == HASH,
           "Warning: unknown hash identifier, check that every server has a different port\n")
    if cmd.request then
      -- task request, send a reply with the task
      send_task(pending_futures[cmd.jobid], cmd.host)
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

------------------------ check worker function -------------------------------

-- This function is the main one for future objects produced by pbs engine.
-- This function is responsible of look-up for new incoming messages and
-- dispatch its response by using process_message function.
local function check_worker()
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

-- The pbs engine class, exported as result of this module.
function pbs:constructor()
end

function pbs:destructor()
  if server then
    xe.shutdown(server, endpoint)
    xe.close(server)
    xe.term()
  end
  os.remove(TMPNAME)
end

-- configures a future object to perform the given operation func(...), assigns
-- the future object a task_id and keeps it in pending_futures[jobid], being
-- jobid the PBS jobid as returned by execute_qsub() function
function pbs_methods:execute(func, ...)
  init()
  local args    = table.pack(...)
  local task_id = common.next_task_id()
  local tmp = config.tmp()
  local tmpname = "%s/PX_%s_%06d_%s"%{tmp,HASH,task_id,os.date("%Y%m%d%H%M%S")}
  local f = future(check_worker)
  f._stdout_  = tmpname..".OU"
  f._stderr_  = tmpname..".ER"
  f.tmpname   = tmpname
  f.jobid     = execute_qsub(config.wd(), tmpname, f)
  f.task_id   = task_id
  f.time      = common.gettime()
  pending_futures[f.jobid] = f
  local task = { id=task_id, func=func, args=args, wd=config.wd() }
  f.task = task
  return f
end

-- waits until all futures are ready
function pbs_methods:wait()
  parallel_engine_wait_method(pending_futures)
end

-- no limit due to PBS
function pbs_methods:get_max_tasks() return math.huge end

-- configure PBS resources for qsub script configuration
function pbs_methods:set_resource(key, value)
  april_assert(allowed_resources[key], "Not allowed resources name %s", key)
  resources[key] = value
  if key == "port" and server then
    fprintf(io.stderr, "Unable to change port after any task has been executed")
  end
end

-- appends a new shell line which will be executed by qsub script
function pbs_methods:append_shell_line(value)
  table.insert(shell_lines, value)
end

----------------------------------------------------------------------------

local singleton = pbs()
class.extend_metamethod(pbs, "__call", function() return singleton end)
common.user_conf("pbs.lua", singleton)
return singleton
