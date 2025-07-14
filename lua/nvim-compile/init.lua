local M = {
	last_command = nil,
	last_window = nil,
	BUFFER_NAME = "compile-output",
}

-- @param name string
function M.get_buffer_by_name(name)
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		local buf_full_path = vim.api.nvim_buf_get_name(buf)
		local buf_name = vim.fn.fnamemodify(buf_full_path, ":t")
		if buf_name == name then
			return buf
		end
	end
	return nil
end

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
	local existing_buf = M.get_buffer_by_name(M.BUFFER_NAME)
	if existing_buf then
		vim.api.nvim_buf_delete(existing_buf, { force = true })
	end

	local header = string.format("> %s", command)

	local buf = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_name(buf, M.BUFFER_NAME)
	vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
	vim.api.nvim_buf_set_option(buf, "bufhidden", "hide")
	vim.api.nvim_buf_set_keymap(buf, "n", "<CR>", "", {
		noremap = true,
		silent = true,
		callback = M.open_link_under_cursor,
	})
	vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", ":bd<CR>", { noremap = true, silent = true })
	vim.api.nvim_buf_set_keymap(buf, "n", "q", ":bd<CR>", { noremap = true, silent = true })
	vim.api.nvim_buf_set_lines(buf, 0, 0, false, { header })
	vim.api.nvim_buf_set_lines(buf, -1, -1, false, vim.split(output, "\n"))
	vim.api.nvim_buf_set_option(buf, "modifiable", false)

	M.last_window = vim.api.nvim_get_current_win()
	vim.api.nvim_command("split")
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	vim.api.nvim_win_set_height(win, 10)
end

-- @param command string
-- @param async bool: When set avoids blocking the main thread.
function M.execute(command, async)
    if not async then
        local result = vim.fn.system(command)
        M.create_output_buffer(command, result)
    else
        M.create_output_buffer(command, "running...")

        local stdin = vim.uv.new_pipe()
        local stdout = vim.uv.new_pipe()
        local stderr = vim.uv.new_pipe()

        local output = {}
        local read_callback = function(err, data)
            if err then
                print("Error:", err)
            elseif data then
                table.insert(output, data)
            end
        end

        local options = { stdio = {stdin, stdout, stderr} }

        vim.uv.spawn(command, options, function(code, signal)
            vim.uv.read_stop(stdout)
            vim.uv.read_stop(stderr)
            M.create_output_buffer(command, table.concat(output))
        end)

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
	vim.api.nvim_create_user_command("Compile", M.compile, { desc = "Run a compile command" })
	vim.api.nvim_create_user_command("CompileLast", M.compile_last, { desc = "Run the last compile command" })
end

return M
