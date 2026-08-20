local M = {}

function M.new(id)
  return {
    id            = id,
    state         = "live",  -- "live"|"done"|"failed"|"folded"
    command       = "",
    chips         = {},
    lines         = {},
    exit_code     = nil,
    command_start = nil,     -- epoch seconds (from pre-exec hook)
    command_end   = nil,     -- epoch seconds (from precmd hook)
    duration      = nil,     -- seconds (derived: command_end - command_start)
    line_count    = 0,
    buf_start     = nil,
    buf_end       = nil,
  }
end

function M.summary(rec)
  return string.format("[%s] %s (%d lines)", rec.state, rec.command, rec.line_count)
end

return M
