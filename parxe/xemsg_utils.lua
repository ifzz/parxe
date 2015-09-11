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

-- This module reimplements functions serialize and deserialize to work with
-- nanomsg SP sockets, replacing implementation done at common module.

local config = require "parxe.config"
local xe     = require "xemsg"

local function deserialize(s)
  local str = assert( xe.recv(s) )
  return util.deserialize( str )
end

local function serialize(data, s)
  local str = util.serialize( data )
  assert( (assert( xe.send(s,str) )) == #str )
end

return {
  deserialize = deserialize,
  serialize   = serialize,
}