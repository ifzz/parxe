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
local common      = require "parxe.common"
local config      = require "parxe.config"
local xe          = require "xemsg"
local xe_utils    = require "parxe.xemsg_utils"
local deserialize = xe_utils.deserialize
local serialize   = xe_utils.serialize

local seq,seq_methods = class("parxe.engines.seq")

function seq:constructor()
  ---------------------------------------------------------------------------
  -- TMPNAME allows to identify this server, allowing to execute several servers
  -- in the same host. The hash part is the particular random sequence of
  -- characters generated by Lua to distinguish the tmpname file. This hash part
  -- is used to  identify client connections in order to assert possible errors.
  self.TMPNAME  = os.tmpname()
  self.HASH     = self.TMPNAME:match("^.*lua_(.*)$")

  -- nanomsg URI connection, using IPC transport
  self.URI = "inproc://"..self.HASH

  self.results = {}
  ---------------------------------------------------------------------------
  
  -- Forward declaration of server socket and binded endpoint identifier, for
  -- attention of the reader.
  self.server = nil
  self.endpoint = nil
  self.server_url = nil
  self.client_url = nil
end

function seq:destructor()
  if self.server then
    self.client:shutdown(self.client_endpoint)
    self.server:shutdown(self.server_endpoint)
    self.server:close()
    self.client:close()
  end
  if self.TMPNAME then os.remove(self.TMPNAME) end
end

function seq_methods:destroy()
  seq.destructor(self)
  for k,v in pairs(self) do self[k] = nil end
end

function seq_methods:init()
  if not self.server then
    self.server = assert( xe.socket(xe.NN_REP) )
    self.server_endpoint = assert( self.server:bind(self.URI) )
    self.client = assert( xe.socket(xe.NN_REQ) )
    self.client_endpoint = assert( self.client:connect(self.URI) )
  end
  return self.server
end

function seq_methods:abort(task)
  error("Not implemented")
end

function seq_methods:check_asserts(cmd)
  assert(cmd.hash == self.HASH,
         "Warning: unknown hash identifier, check that every server has a different port\n")
end

function seq_methods:acceptting_tasks()
  return true
end

function seq_methods:execute(task, stdout, stderr)
  os.execute("cd "..task.wd)
  local func   = task.func
  local args   = task.args
  local result = func(table.unpack(args))
  do
    local f = io.open(stdout, "w") f:close()
    local f = io.open(stderr, "w") f:close()
  end
  serialize({ id=task.id, result=result, hash=self.HASH, reply=true }, self.client)
end

function seq_methods:finished(task)
  assert( deserialize(self.client) )
end

function seq_methods:get_max_tasks() return 1 end

----------------------------------------------------------------------------

return seq
