local M = {
    last_command = nil,
    last_window = nil,
    BUFFER_NAME = "compile-output",
    buffer = nil,
    process_handles = {},
}

-- @param file_path string
-- @param line number
-- @param column number
function M.open_file_at(file_path, line, column)
    if vim.uv.fs_stat(file_path) then
        vim.api.nvim_set_current_win(M.last_window)
        vim.cmd(string.format("edit +%d %s", line, file_path))
        if column > 1 then
            vim.cmd(string.format("normal! %d|", column))
        end
    else
        print("The path", file_path, "does not exist.")
    end
end

function M.kill_processes()
    for _, process in pairs(M.process_handles) do
        if process then
            process:kill('SIGINT')
        end
    end
    M.process_handles = {}
end

function M.open_link_under_cursor()
    local cursor_position = vim.api.nvim_win_get_cursor(0)
    local current_line = cursor_position[1]
    local current_line_contents = vim.fn.getline(current_line)

    -- Regular expressions to match different error formats:
    local patterns = {
        "(.-):(%d+):(%d+)", -- 1. path/to/file:line:column
        "(.-)%((%d+):(%d+)%)", -- 2. path/to/file(line:column)
        "(.-)%((%d+)%)", -- 3. path/to/file(line)
        "(.-):(%d+)", -- 4. path/to/file:line
        '"([^"]+)"', -- 5. "path/to/file"
    }

    local file_path, line, column = nil, nil, nil
    for _, pattern in ipairs(patterns) do
        file_path, line, column = string.match(current_line_contents, pattern)
        if file_path then
            break
        end
    end

    -- @param x string
    -- @param default int
    local function defaultpos(x, default)
        if x == nil then
            return default
        else
            return tonumber(x)
        end
    end

    if file_path then
        line = defaultpos(line, 1)
        column = defaultpos(column, 0) + 1
        M.open_file_at(file_path, line, column)
    else
        print("No valid link to a file position found on this line.")
    end
end

-- @param command string
-- @param output string: stdout of the command just ran
function M.create_output_buffer(command, output)
    if M.buffer then
        vim.api.nvim_buf_delete(M.buffer, { force = true })
    end

    local header = string.format("> %s", command)

    M.buffer = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(M.buffer, M.BUFFER_NAME)
    vim.api.nvim_buf_set_option(M.buffer, "buftype", "nofile")
    vim.api.nvim_buf_set_option(M.buffer, "bufhidden", "hide")

    vim.api.nvim_buf_set_keymap(M.buffer, "n", "<C-c>", '', {
        noremap = true,
        silent = true,
        callback = M.kill_processes,
    })
    vim.api.nvim_buf_set_keymap(M.buffer, "n", "<CR>", "", {
        noremap = true,
        silent = true,
        callback = M.open_link_under_cursor,
    })
    vim.api.nvim_buf_set_keymap(M.buffer, "n", "<Esc>", ":bd<CR>", { noremap = true, silent = true })
    vim.api.nvim_buf_set_keymap(M.buffer, "n", "q", ":bd<CR>", { noremap = true, silent = true })

    vim.api.nvim_create_autocmd({'BufDelete'}, {
        buffer = M.buffer,
        callback = function(event)
            M.buffer = nil
        end
    })

    vim.api.nvim_buf_set_lines(M.buffer, 0, 0, false, { header })
    vim.api.nvim_buf_set_lines(M.buffer, -1, -1, false, vim.split(output, "\n"))

    M.last_window = vim.api.nvim_get_current_win()
    vim.api.nvim_command("split")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, M.buffer)
    vim.api.nvim_win_set_height(win, 10)
end

-- This is why I FUCKING HATE vim.uv
local function split_command(command)
    -- This pattern splits on spaces, but preserves quoted strings as single arguments
    local pattern = '([^%s"]+)"([^"]+)"([^%s"]*)'
    local parts = {}
    local i = 1

    -- Iterate over the command string
    while i <= #command do
        local start_pos, end_pos, quoted_str, unquoted_str = string.find(command, '([%S]+)', i)
        if start_pos then
            if quoted_str then
                -- Handle quoted string
                table.insert(parts, quoted_str)
                i = end_pos + 1
            else
                -- Handle non-quoted string
                table.insert(parts, unquoted_str)
                i = end_pos + 1
            end
        end
    end
    return parts[1], vim.list_slice(parts, 2, #parts)
end

-- @param command string
-- @param async bool: When set avoids blocking the main thread.
function M.execute(command, async)
    if not async then
        local result = vim.fn.system(command)
        M.create_output_buffer(command, result)
    else
        M.create_output_buffer(command, '')

        local stdin = vim.uv.new_pipe()
        local stdout = vim.uv.new_pipe()
        local stderr = vim.uv.new_pipe()

        local executable, arguments = split_command(command)
        local options = { stdio = {stdin, stdout, stderr}, args = arguments }
        local on_exit = function(code, signal)
            vim.schedule(function()
                vim.api.nvim_buf_set_option(M.buffer, "modifiable", false)
                M.kill_processes()
            end)
        end
        local handle, pid = vim.uv.spawn(executable, options, on_exit)
        table.insert(M.process_handles, handle)

        local read_callback = function(err, data)
            if err then
                print("Error:", err)
            elseif data and M.buffer ~= nil then
                vim.schedule(function()
                    local lines = vim.split(data, "\n")
                    vim.api.nvim_buf_set_lines(M.buffer, -1, -1, false, lines)
                end)
            end
        end
        vim.uv.read_start(stdout, read_callback)
        vim.uv.read_start(stderr, read_callback)
    end
end

function M.compile()
    local command = vim.fn.input("command: ")
    if string.len(command) == 0 then
        if M.last_command == nil then
            print("There is no last command.")
            return
        else
            command = M.last_command
        end
    else
        M.last_command = command
    end
    assert(command ~= nil)
    M.execute(command, true)
end

function M.compile_last()
    if M.last_command == nil then
        print("There is no last command.")
    else
        M.execute(M.last_command, true)
    end
end

function M.setup()
    vim.api.nvim_create_user_command("Compile", M.compile, { desc = "Run a compile command", force = true })
    vim.api.nvim_create_user_command("CompileLast", M.compile_last, { desc = "Run the last compile command", force = true })
end

return M
