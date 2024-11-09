local cscope = require('cscope')

local M = {}

M.known_bytelengths = {
    UINT8 = 1, CHAR8 = 1,
    UINT16 = 2, CHAR16 = 2,
    UINT32 = 4, CHAR32 = 4,
    UINT64 = 8, CHAR64 = 8,
    UINT128 = 16, CHAR128 = 16,
    UINT256 = 32, CHAR256 = 32,
}

-- TODO: Cache symbol values
--       Better handling of filepaths? Not sure if relying on buf_name is reliable.

-- Map filename to buf_id
-- TODO: Clean up all visited files at end of parsing
M.visited_files = { }

local function set_visited_file(buf, filepath)
    local full_path = vim.fn.expand(vim.fn.fnamemodify(filepath, ':p'))
    M.visited_files[full_path] = buf
end

local function get_visited_file_buf(filepath)
    local full_path = vim.fn.expand(vim.fn.fnamemodify(filepath, ':p'))
    return M.visited_files[full_path]
end

local function find_keywords(text, keyword)
    local pattern = string.format([[\<%s\>]], keyword)
    local pos = 0

    local matches = {}

    while true do
        local match = vim.fn.matchstrpos(text, pattern, pos)

        if match[2] == -1 then
            break
        end

        table.insert(matches, match)
        pos = match[3]
    end

    return matches
end

local function get_tree_root_from_file(filepath)
    local buf = get_visited_file_buf(filepath)

    if buf == nil then
        buf = vim.api.nvim_create_buf(false, false)
        vim.api.nvim_buf_set_name(buf, filepath)
        vim.api.nvim_buf_call(buf, vim.cmd.edit)
        set_visited_file(buf, filepath)
    end

    local parser = vim.treesitter.get_parser(buf, 'c')
    local tree = parser:parse(true)[1]
    return buf, tree:root(), parser
end

--[[
   call cscope
   find definition(s)
   drill each value
   if all equal, return value
   else fail or ask
]]
local function drill_value(node, buf)
    if node:type() == 'number_literal' then
        local final_value = tonumber(vim.treesitter.get_node_text(node, buf, nil))
        return final_value
    end

    assert(node:type() == 'identifier')

    --[[ cscope_results example:
         lnum:       39
         text:       <<MY_MACRO>> #define MY_MACRO 4
         filename:   relative/path/to/macro/location/file.h
         ctx:        <<MY_MACRO>>
    ]]

    -- TODO: cscope_maps.utils.ret_codes
    local cscope_err, cscope_results = cscope.get_result(cscope.op_s_n['g'], 'g', vim.treesitter.get_node_text(node, buf, nil))

    if cscope_results == nil then
        print('No cscope results for ' .. vim.treesitter.get_node_text(node, buf))
        return nil
    end

    -- Prioritize local definitions
    do
        local source_filepath = vim.api.nvim_buf_get_name(buf)
        local source_full_path = vim.fn.expand(vim.fn.fnamemodify(source_filepath, ':p'))

        for res_n, res in ipairs(cscope_results) do
            local res_full_path = vim.fn.expand(vim.fn.fnamemodify(res.filename, ':p'))

            if res_full_path == source_full_path then
                cscope_results = { cscope_results[res_n], }
                break
            end
        end
    end


    -- TODO: Avoid infinite recursion by short-circuiting if we're circling back to the same symbol.
    --       Implement scratch buffer for prioritized symbol definitions, similar to how local definitions are prioritized.
    --       Add cpp support

    local found_values = {}

    for _, res in ipairs(cscope_results) do
        local symbol_text = string.sub(res.ctx, 3, -3)
        local line_text = string.sub(res.text, string.len(res.ctx)+1, -1)

        local matches = find_keywords(line_text, symbol_text)
        assert(matches ~= nil)
        assert(#matches == 1, 'Multiple cscope symbol matches on one line not supported yet.')

        local _, col, _ = unpack(matches[1])
        local row = tonumber(res.lnum) - 1 -- cscope_maps is 1-indexed

        local extern_buf, root , parser = get_tree_root_from_file(res.filename)
        local symbol_node = root:named_descendant_for_range(row, col, row, col)
        assert(symbol_node)
        assert(symbol_node:type() == 'identifier', 'Expected symbol_node:type() == "identifier", got `' .. symbol_node:type()
                                                    .. '` for `' .. res.ctx .. '` at `' .. res.text .. '` in `' .. res.filename)

        local value_node = symbol_node:parent():field('value')[1]

        if value_node == nil then
            goto continue_1
        end

        -- Need to do this to get injected code. nvim-treesitter injects c into preproc_arg.
        value_node = parser:named_node_for_range({ value_node:range() }, { ignore_injections = false })
        assert(value_node)

        local value_node_child = value_node:child(0)

        -- TODO: See if we can clean this up
        if value_node_child == nil then
            -- XXX: Hack to support error nodes. Might get false positives like matching `4 + 4` as simply `4`
            local value_node_text = vim.treesitter.get_node_text(value_node, extern_buf)
            local value = tonumber(value_node_text)

            if value_node:has_error() then
                print('DEBUG: Value node has error.')
                if value then
                    table.insert(found_values, value)
                else
                    print('Warning: ERROR node without valid value.')
                    -- TODO: Try assuming symbol.
                end
            else
                if value then
                    table.insert(found_values, value)
                else
                    print('Did not find value. Node text: ' .. value_node_text)
                    -- TODO: Try assuming symbol.
                end
            end
        elseif value_node_child:type() == 'number_literal' then
            local value_node_child_text = vim.treesitter.get_node_text(value_node_child, buf)
            local value = tonumber(value_node_child_text)

            assert(value ~= nil)
            table.insert(found_values, value)
        elseif value_node_child:type() == 'translation_unit' then
            local tr_unit = value_node_child
            print('trunit')
            assert(tr_unit:child_count() == 1)

            if tr_unit:child(0) ~= nil and tr_unit:child(0):type() == 'expression_statement' then
                local expr = tr_unit:child(0)
                assert(expr:child_count() == 1)

                if expr:child(0):type() == 'identifier' then
                    local assigned_symbol_node = expr:child(0)
                    local found_value = drill_value(assigned_symbol_node, buf)

                    table.insert(found_values, found_value)
                end
            end
        end

        ::continue_1::
    end

    local final_value = found_values[1]

    for i = 2, #found_values do
        if found_values[i] ~= final_value then
            print('Error: Found differing definitions of ' .. cscope_results[1].ctx
                   .. '. You can define the symbol locally in the file to bypass this, as local definitions are prioritized.')
            return nil
        end
    end

    return final_value
end

local function get_field_arr_len(buf, field_node)
    -- TODO: Find out what to do with multiple fields on one line
    --       Drill type definitions
    --       Function type support

    assert(#field_node:field('type') == 1, 'Field types consisting of more than a simple identifier is not supported yet.')

    local field_declarator = field_node:field('declarator')[1]
    local arr_len

    if field_declarator:type() == 'field_identifier' then
        arr_len = 1
    elseif field_declarator:type() == 'array_declarator' then
        local array_declarator = field_declarator

        local field_identifier = array_declarator:field('declarator')[1]
        local array_size = array_declarator:field('size')[1]

        assert(field_identifier:type() == 'field_identifier')

        arr_len = drill_value(array_size, buf)

        if arr_len == nil then
            print('Warning: Could not get array length of struct field ' .. vim.treesitter.get_node_text(field_declarator, buf))
        end
    else
        assert(false, 'Error: Unsupported field declarator type `' .. field_declarator:type() '`')
    end

    return arr_len
end

local function get_ancestor_node(node, type)
    while node:type() ~= type do
        node = node:parent()

        if node == nil then
            print('No field_declaration_list node found.')
            return nil
        end
    end

    return node
end

-- TODO: Clear namespace id extmarks when re-running the function on the same struct/etc.
local function annotate_node(buf, ns_id, node, text)
    local row_start, col_start, row_end, col_end = node:range()

    vim.api.nvim_buf_set_extmark(buf, ns_id, row_start, col_start, {
        end_col = col_end,
        end_row = row_end,
        hl_group = 0,
        virt_text = {{text, 'comment'}}, -- hl_group 0 is global highlight group
        virt_text_pos = 'inline',
    })
end

-- TODO: Separate part of this into init_file?
local function init_command(namespace)
    local ns_id = vim.api.nvim_create_namespace(namespace)
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_get_current_buf()
    local cursor_pos = vim.api.nvim_win_get_cursor(win)
    local filepath = vim.api.nvim_buf_get_name(buf)

    set_visited_file(buf, filepath)

    local row, col = unpack(cursor_pos) -- (1,0)-indexed
    local ts_row = row - 1 -- Treesitter uses 0-indexing
    local _, root, parser = get_tree_root_from_file(filepath)
    local init_node = root:named_descendant_for_range(ts_row, col, ts_row, col)

    return {
        ns_id = ns_id,
        win = win,
        buf = buf,
        filepath = filepath,
        pos = {
            row = row,
            col = col,
        },
        ts = {
            pos = {
                row = ts_row,
                col = col,
            },
            root = root,
            parser = parser,
            node = init_node,
        },
    }
end

-- TODO: Needs optimization.
local function show_struct_offsets()
    local init = init_command('nolsp_struct_offsets')

    local fields = get_ancestor_node(init.ts.node, 'field_declaration_list')
    assert(fields)

    local curr_offset = 0

    for field, _ in fields:iter_children() do
        if field:type() == 'field_declaration' then
            local arr_len = get_field_arr_len(init.buf, field)

            if arr_len == nil then
                print('Error: arr_len == nil')
                return nil
            end

            local annotation = string.format('0x%x: ', curr_offset)

            annotate_node(init.buf, init.ns_id, field, annotation)

            local type = vim.treesitter.get_node_text(field:field('type')[1], init.buf)
            local type_size = M.known_bytelengths[type]

            if type_size == nil then
                print('Error: Unknown type bytelength: ' .. type)
                return nil
            end

            local field_size = type_size * arr_len

            curr_offset = curr_offset + field_size
        end
    end
end

local function show_enum_values()
    local init = init_command('nolsp_enum_values')
    assert(init.ts.node ~= nil)

    local entries

    if init.ts.node:type() == 'enumerator_list' then
        entries = init.ts.node
    else
        entries = get_ancestor_node(init.ts.node, 'enumerator_list')
    end

    if entries == nil then
        print("Error: couldn't find enumerator_list node.")
        return nil
    end

    local curr_value = 0

    for entry, _ in entries:iter_children() do
        if entry:type() == 'enumerator' then
            local value_node = entry:field('value')[1]

            if value_node ~= nil and value_node:type() == 'number_literal' then
                curr_value = tonumber(vim.treesitter.get_node_text(value_node, init.buf))

                if curr_value == nil then
                    print('Error: Unable to find enum entry number.')
                    return nil
                end
            end

            -- XXX: Is there a better way to do this formatting?
            local annotation = string.format('0x%-4x %-8s ', curr_value, '('..curr_value..'):')

            annotate_node(init.buf, init.ns_id, entry, annotation)

            curr_value = curr_value + 1
        end
    end
end

M.commands = {
    ['enums'] = show_enum_values,
    ['structs'] = show_struct_offsets,
}

local function get_commands()
    local commands = {}

    for key, _ in pairs(M.commands) do
        table.insert(commands, key)
    end

    return commands
end

local function run_command(command)
    if command == nil then
        print('Please use a command.')
        return nil
    end

    M.commands[command]()
end

local function setup()
    vim.api.nvim_create_user_command('NoLsp', function(opts) run_command(opts.fargs[1]) end, {
        nargs = 1,
        complete = function() return get_commands() end,
    })
end

return { setup = setup }
