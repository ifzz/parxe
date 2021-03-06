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
require "aprilann"
local common      = require "parxe.common"
local xe          = require "xemsg"
local xe_utils    = require "parxe.xemsg_utils"
local deserialize = xe_utils.deserialize
local serialize   = xe_utils.serialize
--
local HOSTNAME = common.hostname()
local TIMEOUT  = 1800000 -- 30 minutes in milliseconds
--
function RUN_WORKER(URL, HASH, ID)
  print("# RUN_WORKER", URL, HASH, ID)
  -- socket creation and connection
  local client = assert( xe.socket(xe.NN_REQ) )
  assert( client:setsockopt(xe.NN_SOL_SOCKET, xe.NN_RCVTIMEO, TIMEOUT) )
  assert( client:setsockopt(xe.NN_SOL_SOCKET, xe.NN_SNDTIMEO, TIMEOUT) )
  local endpoint = assert( client:connect(URL) )
  -- request a new job
  serialize({ id=ID, hash=HASH, host=HOSTNAME, request=true }, client)
  -- response with task data
  local task = deserialize(client)
  local func, args, id = task.func, task.args, task.id
  assert(id == ID)
  print("# TASKID: ", id)
  -- execute the task
  local ok,result = xpcall(func,debug.traceback,table.unpack(args,1,args.n))
  local err = nil
  if not ok then err,result=result,{} end
  -- request returning the task result
  serialize({ id=id, result=result, err=err, hash=HASH, reply=true }, client)
  assert( deserialize(client) )
  client:shutdown(endpoint)
  client:close()
end
