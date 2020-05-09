-- cp --

local shell = require("shell")
local cp = require("cp.copy")

local args, opts = shell.parse(...)

cp.recurse = opts.r or opts.recursive or false
cp.verbose = opts.v or opts.verbose or false

if #args < 2 then
  shell.error("cp", "usage: cp FILE1 ... DEST")
  return shell.codes.argument
end

local ok, err = pcall(cp.copy, table.unpack(args))
if not ok and err then
  shell.error("cp", err)
  return shell.codes.failure
end