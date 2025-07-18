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
            process:kill()
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
-- I can't just split the string because quotes are used for grouping.
--
-- @param command string
function M.split_command(command)
    local command_len = string.len(command)

    local function is_whitespace(str)
        return string.match(str, "%s") ~= nil
    end

    local lexer = {
        tokens = {},
        start = 1,
        current = 1,
    }

    function lexer:push(token)
        if string.len(token) > 0 then
            table.insert(self.tokens, token)
        end
    end

    function lexer:get_current()
        return string.sub(command, self.current, self.current)
    end

    function lexer:advance()
        self.current = self.current + 1
    end

    function lexer:is_done()
        return lexer.current > command_len
    end

    -- @param quote char: Character that wraps the group.
    -- @param evaluate bool: When set skips the first char after a backslash.
    function lexer:parse_group(quote, evaluate)
        self:advance()
        while not self:is_done() and self:get_current() ~= quote do
            if self:get_current() == '\\' then
                self:advance()
            end
            self:advance()
        end
        if self:is_done() then
            error("Unterminated string literal")
        end
        self:push(string.sub(command, self.start + 1, self.current - 1))
        self:advance()
        self.start = self.current
    end

    while not lexer:is_done() do
        local c = lexer:get_current()
        if c == ' ' then
            local skipped = 1
            while not lexer:is_done() and is_whitespace(lexer:get_current()) do
                skipped = skipped + 1
                lexer:advance()
            end
            lexer:push(string.sub(command, lexer.start, lexer.current - skipped))
            lexer.start = lexer.current
        elseif c == '"' then
            lexer:parse_group('"', true)
        elseif c == "'" then
            lexer:parse_group("'", false)
        elseif lexer.current + 1 > command_len then
            lexer:push(string.sub(command, lexer.start, lexer.current))
            lexer:advance()
        else
            lexer:advance()
        end
    end

    return lexer.tokens[1], vim.list_slice(lexer.tokens, 2, #lexer.tokens)
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

        local executable, arguments = M.split_command(command)
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
                    if M.buffer ~= nil then
                        local lines = vim.split(data, "\n")
                        vim.api.nvim_buf_set_lines(M.buffer, -1, -1, false, lines)
                    end
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
