local errs = require("copilot-lsp.errors")
local nes_ui = require("copilot-lsp.nes.ui")
local utils = require("copilot-lsp.util")

local M = {}

local nes_ns = vim.api.nvim_create_namespace("copilotlsp.nes")

local nes_recent_suggestions = {}
local nes_recall_index = nil
local nes_recent_history_depth = 5

---Returns the text content at the given edit range in the buffer as it currently exists.
local function get_buffer_text_at_edit(edit, bufnr)
    local lines = vim.api.nvim_buf_get_lines(
        bufnr,
        edit.range.start.line,
        edit.range["end"].line + 1,
        false
    )
    if not lines then return nil end
    local original = nil
    if edit.range.start.line == edit.range["end"].line then
        original = string.sub(lines[1], edit.range.start.character + 1, edit.range["end"].character)
    else
        lines[1] = string.sub(lines[1], edit.range.start.character + 1)
        lines[#lines] = string.sub(lines[#lines], 1, edit.range["end"].character)
        original = table.concat(lines, "\n")
    end
    -- Special case: empty, zero-width insertion (insert new line or text at new line)
    if original == "" and edit.range.start.line == edit.range["end"].line
        and edit.range.start.character == 0 and edit.range["end"].character == 0 then
        if edit.range.start.line > 0 then
            local above = vim.api.nvim_buf_get_lines(bufnr, edit.range.start.line - 1, edit.range.start.line, false)[1]
            return above or ""
        end
    end
    return original
end

--- Recalls (re-shows) the last NES suggestion if still in the same buffer
function M.recall_last_suggestion()
    local history = nes_recent_suggestions
    if #history == 0 then
        vim.notify("No NES suggestion to recall.", vim.log.levels.INFO)
        return
    end

    local current_buf = vim.api.nvim_get_current_buf()
    local start_idx = nes_recall_index or 1
    local idx = start_idx
    local history_len = #history
    local checked = 0

    while checked < history_len and #history > 0 do
        local candidate = history[idx]
        -- Only consider suggestions from current buffer
        if candidate and candidate.bufnr == current_buf then
            local candidate_edit = candidate.edits[1]
            local current_text = get_buffer_text_at_edit(candidate_edit, current_buf)
            if current_text == candidate.original_text then
                -- Found a valid suggestion
                nes_recall_index = idx % #history + 1
                local ns_id = vim.api.nvim_create_namespace("copilotlsp.nes")
                nes_ui._display_next_suggestion(candidate.bufnr, ns_id, vim.deepcopy(candidate.edits))
                return
            else
                -- Content has changed, remove this entry
                table.remove(history, idx)
                if #history == 0 then
                    break -- List empty, exit
                end
                if idx > #history then
                    idx = 1 -- Wrap
                end
                -- continue; don't increment checked since we want to check the new item now at idx
                history_len = #history -- Update how many items we must check
            end
        else
            idx = idx % #history + 1
            checked = checked + 1
        end

        if #history > 0 and idx == start_idx then
            -- Made a full loop, bail out
            break
        end
    end

    vim.notify("No NES suggestion to recall in this buffer.", vim.log.levels.INFO)
end

---@param err lsp.ResponseError?
---@param result copilotlsp.copilotInlineEditResponse
---@param ctx lsp.HandlerContext
local function handle_nes_response(err, result, ctx)
    if err then
        -- vim.notify(err.message)
        return
    end
    -- Validate buffer still exists before processing response
    if not vim.api.nvim_buf_is_valid(ctx.bufnr) then
        return
    end
    for _, edit in ipairs(result.edits) do
        --- Convert to textEdit fields
        edit.newText = edit.text
    end

    -- Only add suggestions with non-empty edits to FIFO recall history
    if result.edits and #result.edits > 0 then
        -- Extract and store the original content at the replaced range for the first edit
        local edit = result.edits[1]
        local bufnr = ctx.bufnr
        local original_text = get_buffer_text_at_edit(edit, bufnr)
        local history = nes_recent_suggestions
        table.insert(history, 1, {
            edits = vim.deepcopy(result.edits),
            bufnr = ctx.bufnr,
            context = vim.deepcopy(ctx),
            original_text = original_text,
        })
        while #history > nes_recent_history_depth do
            table.remove(history, #history)
        end
        nes_recall_index = nil  -- Reset recall-cycle index
    end

    nes_ui._display_next_suggestion(ctx.bufnr, nes_ns, result.edits)
end

--- Requests the NextEditSuggestion from the current cursor position
---@param copilot_lss? vim.lsp.Client|string
function M.request_nes(copilot_lss)
    local pos_params = vim.lsp.util.make_position_params(0, "utf-16")
    local version = vim.lsp.util.buf_versions[vim.api.nvim_get_current_buf()]
    if type(copilot_lss) == "string" then
        copilot_lss = vim.lsp.get_clients({ name = copilot_lss })[1]
    end
    assert(copilot_lss, errs.ErrNotStarted)
    ---@diagnostic disable-next-line: inject-field
    pos_params.textDocument.version = version
    copilot_lss:request("textDocument/copilotInlineEdit", pos_params, handle_nes_response)
end

--- Walks the cursor to the start of the edit.
--- This function returns false if there is no edit to apply or if the cursor is already at the start position of the
--- edit.
---@param bufnr? integer
---@return boolean --if the cursor walked
function M.walk_cursor_start_edit(bufnr)
    bufnr = bufnr and bufnr > 0 and bufnr or vim.api.nvim_get_current_buf()
    ---@type copilotlsp.InlineEdit
    local state = vim.b[bufnr].nes_state
    if not state then
        return false
    end

    local cursor_row, _ = unpack(vim.api.nvim_win_get_cursor(0))
    if cursor_row - 1 ~= state.range.start.line then
        vim.b[bufnr].nes_jump = true
        ---@type lsp.Location
        local jump_loc_before = {
            uri = state.textDocument.uri,
            range = {
                start = state.range["start"],
                ["end"] = state.range["start"],
            },
        }
        return vim.lsp.util.show_document(jump_loc_before, "utf-16", { focus = true })
    else
        return false
    end
end

--- Walks the cursor to the end of the edit.
--- This function returns false if there is no edit to apply or if the cursor is already at the end position of the
--- edit
---@param bufnr? integer
---@return boolean --if the cursor walked
function M.walk_cursor_end_edit(bufnr)
    bufnr = bufnr and bufnr > 0 and bufnr or vim.api.nvim_get_current_buf()
    ---@type copilotlsp.InlineEdit
    local state = vim.b[bufnr].nes_state
    if not state then
        return false
    end

    ---@type lsp.Location
    local jump_loc_after = {
        uri = state.textDocument.uri,
        range = {
            start = state.range["end"],
            ["end"] = state.range["end"],
        },
    }
    --NOTE: If last line is deletion, then this may be outside of the buffer
    vim.schedule(function()
        pcall(vim.lsp.util.show_document, jump_loc_after, "utf-16", { focus = true })
    end)
    return true
end

--- This function applies the pending nes edit to the current buffer and then clears the marks for the pending
--- suggestion
---@param bufnr? integer
---@return boolean --if the nes was applied
function M.apply_pending_nes(bufnr)
    bufnr = bufnr and bufnr > 0 and bufnr or vim.api.nvim_get_current_buf()

    ---@type copilotlsp.InlineEdit
    local state = vim.b[bufnr].nes_state
    if not state then
        return false
    end
    vim.schedule(function()
        utils.apply_inline_edit(state)
        vim.b[bufnr].nes_jump = false
        nes_ui.clear_suggestion(bufnr, nes_ns)
    end)
    return true
end

---@param bufnr? integer
function M.clear_suggestion(bufnr)
    bufnr = bufnr and bufnr > 0 and bufnr or vim.api.nvim_get_current_buf()
    nes_ui.clear_suggestion(bufnr, nes_ns)
end

--- Clear the current suggestion if it exists
---@return boolean -- true if a suggestion was cleared, false if no suggestion existed
function M.clear()
    local buf = vim.api.nvim_get_current_buf()
    if vim.b[buf].nes_state then
        local ns = vim.b[buf].copilotlsp_nes_namespace_id or nes_ns
        nes_ui.clear_suggestion(buf, ns)
        return true
    end
    return false
end

return M
