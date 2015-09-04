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
local MPI    = require "MPI"
local buffer = require "buffer"

local function accept_connection(cnn)
end

local function check_any_result(cnn, running_clients)
end

local function run_server(server_name)
end

local function send_task(cnn, cli, task)
end

return {
  accept_connection = accept_connection,
  check_any_result = check_any_result,
  run_server = run_server,
  send_task = send_task,
}
