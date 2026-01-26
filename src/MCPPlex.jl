"""
MCP Julia REPL Multiplexer

This multiplexer implements an MCP server that forwards REPL commands to Unix socket-based
Julia REPL servers. Each tool call specifies a project directory to locate the correct
Julia server socket.

Usage:
    julia -e 'using MCPRepl; MCPRepl.run_multiplexer(ARGS)' -- [--transport stdio|http] [--port PORT]

Options:
    --transport stdio|http    Transport mode (default: stdio)
    --port PORT               Port for HTTP mode (default: 3000)

The Julia MCP server must be running in each project directory:
    julia --project -e "using MCPRepl; MCPRepl.start!(multiplex=true)"
"""
module MCPPlex

using ArgParse
using JSON3
using Sockets
using HTTP

# Import from Tools module (included in parent MCPRepl module)
using ..Tools: TOOL_DEFINITIONS, make_tool_schema, get_tool_description, get_tool_names

const SOCKET_NAME = ".mcp-repl.sock"
const PID_NAME = ".mcp-repl.pid"
const MCP_PROTOCOL_VERSION = "2024-11-05"

# NOTE: SOCKET_CACHE is not thread-safe. This multiplexer assumes single-threaded
# operation. If running with multiple threads, add appropriate locking around cache access.
const SOCKET_CACHE = Dict{String,Tuple{Union{String,Nothing},Float64}}()
const SOCKET_CACHE_TTL = 10.0

const TASK_CLEANUP_INTERVAL = 100

"""
    find_socket_path(start_dir::String) -> Union{String,Nothing}

Walk up the directory tree from start_dir looking for .mcp-repl.sock.
Returns the socket path if found, nothing otherwise.

Results are cached with a TTL to avoid repeated directory traversals.
"""
function find_socket_path(start_dir::String)
    current = abspath(start_dir)

    now = time()
    if haskey(SOCKET_CACHE, current)
        cached_path, cached_time = SOCKET_CACHE[current]
        if now - cached_time < SOCKET_CACHE_TTL
            return cached_path
        end
    end

    search_dir = current
    while true
        socket_path = joinpath(search_dir, SOCKET_NAME)
        if ispath(socket_path)
            SOCKET_CACHE[current] = (socket_path, now)
            return socket_path
        end
        parent = dirname(search_dir)
        if parent == search_dir
            SOCKET_CACHE[current] = (nothing, now)
            return nothing
        end
        search_dir = parent
    end
end

"""
    check_server_running(socket_path::String) -> Bool

Check if the MCP server is running by verifying the PID file.
Returns true if server appears to be running, false otherwise.
"""
function check_server_running(socket_path::String)
    pid_path = joinpath(dirname(socket_path), PID_NAME)

    if !ispath(pid_path)
        return false
    end

    try
        pid = parse(Int, strip(read(pid_path, String)))
        # Check if process exists (Unix systems)
        return success(pipeline(`kill -0 $pid`, stderr=devnull))
    catch
        return false
    end
end

const SOCKET_TIMEOUT = 30.0

"""
    with_timeout(f, timeout::Float64)

Execute function f with a timeout. Throws ErrorException if timeout is exceeded.
"""
function with_timeout(f, timeout::Float64)
    task = @async f()

    if timedwait(() -> istaskdone(task), timeout) == :timed_out
        try
            Base.throwto(task, ErrorException("Operation timed out after $timeout seconds"))
        catch
        end
        wait(task)
        error("Operation timed out after $timeout seconds")
    end

    return fetch(task)
end

"""
    send_to_julia_server_async(socket_path::String, request::Dict{String,Any}) -> Task

Send a JSON-RPC request to the Julia server asynchronously.
Returns a Task that yields the response Dict when complete.
Includes connection and read timeouts.
"""
function send_to_julia_server_async(socket_path::String, request::Dict{String,Any})
    return @async begin
        try
            sock = with_timeout(SOCKET_TIMEOUT) do
                connect(socket_path)
            end

            # Send request
            println(sock, JSON3.write(request))

            # Read response
            response_line = with_timeout(SOCKET_TIMEOUT) do
                readline(sock)
            end

            if isempty(response_line)
                close(sock)
                error("Server closed connection")
            end

            response = JSON3.read(response_line, Dict{String,Any})
            close(sock)

            return response
        catch e
            if e isa Base.IOError || e isa SystemError
                error("Socket error: $e. Is the Julia MCP server running?")
            else
                rethrow(e)
            end
        end
    end
end

"""
    send_to_julia_server(socket_path::String, request::Dict{String,Any}) -> Dict

Send a JSON-RPC request to the Julia server synchronously.
This is a convenience wrapper around send_to_julia_server_async.
"""
function send_to_julia_server(socket_path::String, request::Dict{String,Any})
    return fetch(send_to_julia_server_async(socket_path, request))
end

"""
    create_error_response(request_id, code::Int, message::String) -> Dict

Create a JSON-RPC error response.
"""
function create_error_response(request_id, code::Int, message::String)
    return Dict(
        "jsonrpc" => "2.0",
        "id" => request_id,
        "error" => Dict(
            "code" => code,
            "message" => message
        )
    )
end

"""
    create_success_response(request_id, result) -> Dict

Create a JSON-RPC success response.
"""
function create_success_response(request_id, result)
    return Dict(
        "jsonrpc" => "2.0",
        "id" => request_id,
        "result" => result
    )
end

"""
    forward_to_julia_server_async(tool_name::String, project_dir::String, tool_args::Dict{String,Any}, include_startup_msg::Bool=false) -> Task

Forward a tool call to the Julia server identified by project_dir asynchronously.
Returns a Task that yields the result text or error message when complete.
"""
function forward_to_julia_server_async(tool_name::String, project_dir::String, tool_args::Dict{String,Any}, include_startup_msg::Bool=false)
    return @async begin
        socket_path = find_socket_path(project_dir)
        if isnothing(socket_path)
            msg = "Error: MCP REPL server not found in $project_dir"
            if include_startup_msg
                msg *= ". Start the server with:\n  julia --project -e 'using MCPRepl; MCPRepl.start!(multiplex=true)'"
            end
            return msg
        end

        if !check_server_running(socket_path)
            msg = "Error: MCP REPL server not running"
            if include_startup_msg
                msg *= " (socket exists but process dead). Start the server with:\n  julia --project -e 'using MCPRepl; MCPRepl.start!(multiplex=true)'"
            end
            return msg
        end

        julia_request = Dict(
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "tools/call",
            "params" => Dict(
                "name" => tool_name,
                "arguments" => tool_args
            )
        )

        try
            response = send_to_julia_server(socket_path, julia_request)
            if haskey(response, "error")
                return "Error: Julia server returned error: $(response["error"]["message"])"
            end
            if haskey(response, "result") && haskey(response["result"], "content")
                content = response["result"]["content"]
                if content isa Vector && length(content) > 0
                    return get(content[1], "text", "")
                end
            end
            return string(get(response, "result", ""))
        catch e
            return "Error: Failed to communicate with Julia server: $e"
        end
    end
end

"""
    forward_to_julia_server(tool_name::String, project_dir::String, tool_args::Dict{String,Any}, include_startup_msg::Bool=false) -> String

Forward a tool call to the Julia server identified by project_dir.
Returns the result text or an error message.
This is a synchronous wrapper around forward_to_julia_server_async.
"""
function forward_to_julia_server(tool_name::String, project_dir::String, tool_args::Dict{String,Any}, include_startup_msg::Bool=false)
    return fetch(forward_to_julia_server_async(tool_name, project_dir, tool_args, include_startup_msg))
end

#==============================================================================#
# Forwarding Handlers - extract project_dir and forward to Julia server
#==============================================================================#

"""
    handle_exec_repl(args::Dict{String,Any}) -> String

Handle exec_repl tool call.
Takes project_dir and expression, forwards to Julia server.
"""
function handle_exec_repl(args::Dict{String,Any})
    project_dir = get(args, "project_dir", "")
    expression = get(args, "expression", "")

    if isempty(project_dir)
        return "Error: project_dir parameter is required"
    end

    if isempty(expression)
        return "Error: expression parameter is required"
    end

    return forward_to_julia_server("exec_repl", project_dir, Dict("expression" => expression), true)
end

"""
    handle_investigate_environment(args::Dict{String,Any}) -> String

Handle investigate_environment tool call.
Takes project_dir, forwards to Julia server.
"""
function handle_investigate_environment(args::Dict{String,Any})
    project_dir = get(args, "project_dir", "")

    if isempty(project_dir)
        return "Error: project_dir parameter is required"
    end

    return forward_to_julia_server("investigate_environment", project_dir, Dict(), false)
end

"""
    handle_usage_instructions(args::Dict{String,Any}) -> String

Handle usage_instructions tool call.
Takes project_dir, forwards to Julia server.
"""
function handle_usage_instructions(args::Dict{String,Any})
    project_dir = get(args, "project_dir", "")

    if isempty(project_dir)
        return "Error: project_dir parameter is required"
    end

    return forward_to_julia_server("usage_instructions", project_dir, Dict(), false)
end

"""
    handle_remove_trailing_whitespace(args::Dict{String,Any}) -> String

Handle remove-trailing-whitespace tool call.
Takes project_dir and file_path, forwards to Julia server.
"""
function handle_remove_trailing_whitespace(args::Dict{String,Any})
    project_dir = get(args, "project_dir", "")
    file_path = get(args, "file_path", "")

    if isempty(project_dir)
        return "Error: project_dir parameter is required"
    end

    if isempty(file_path)
        return "Error: file_path parameter is required"
    end

    return forward_to_julia_server("remove-trailing-whitespace", project_dir, Dict("file_path" => file_path), false)
end

#==============================================================================#
# Tool Generation and Lookup
#==============================================================================#

# Handler lookup table - maps tool names to their forwarding handlers
const TOOL_HANDLERS = Dict(
    "exec_repl" => handle_exec_repl,
    "investigate_environment" => handle_investigate_environment,
    "usage_instructions" => handle_usage_instructions,
    "remove-trailing-whitespace" => handle_remove_trailing_whitespace
)

"""
    get_tools() -> Vector{Dict}

Generate tool definitions with project_dir parameter included.
This is used by the multiplexer which always needs project_dir for routing.
"""
function get_tools()
    tools = Dict[]
    for tool_name in get_tool_names()
        if haskey(TOOL_HANDLERS, tool_name)
            push!(tools, Dict(
                "name" => tool_name,
                "description" => get_tool_description(tool_name),
                "inputSchema" => make_tool_schema(tool_name; include_project_dir=true),
                "handler" => TOOL_HANDLERS[tool_name]
            ))
        end
    end
    return tools
end

"""
    process_mcp_request(request::Dict) -> Union{Dict,Nothing}

Process an MCP request and return a response.
"""
function process_mcp_request(request::Dict)
    method = get(request, "method", nothing)
    request_id = get(request, "id", nothing)

    # Handle initialization
    if method == "initialize"
        return create_success_response(request_id, Dict(
            "protocolVersion" => MCP_PROTOCOL_VERSION,
            "capabilities" => Dict(
                "tools" => Dict()
            ),
            "serverInfo" => Dict(
                "name" => "julia-mcp-adapter",
                "version" => "1.0.0"
            )
        ))
    end

    # Handle initialized notification
    if method == "notifications/initialized"
        return nothing  # No response for notifications
    end

    # Handle tool listing
    if method == "tools/list"
        tools = get_tools()
        tool_list = [
            Dict(
                "name" => tool["name"],
                "description" => tool["description"],
                "inputSchema" => tool["inputSchema"]
            ) for tool in tools
        ]
        return create_success_response(request_id, Dict("tools" => tool_list))
    end

    # Handle tool calls
    if method == "tools/call"
        params = get(request, "params", Dict())
        tool_name = get(params, "name", "")
        args = get(params, "arguments", Dict())

        # Find tool handler
        if !haskey(TOOL_HANDLERS, tool_name)
            return create_error_response(request_id, -32602, "Tool not found: $tool_name")
        end

        # Call tool handler
        try
            result_text = TOOL_HANDLERS[tool_name](args)
            return create_success_response(request_id, Dict(
                "content" => [
                    Dict(
                        "type" => "text",
                        "text" => result_text
                    )
                ]
            ))
        catch e
            return create_error_response(request_id, -32603, "Tool execution error: $e")
        end
    end

    # Method not found
    return create_error_response(request_id, -32601, "Method not found: $method")
end

"""
    run_stdio_mode()

Run in stdio mode - read from stdin, write to stdout.
Processes requests asynchronously for better concurrency.
"""
function run_stdio_mode()
    output_lock = ReentrantLock()
    active_tasks = Task[]
    request_count = 0

    try
        while !eof(stdin)
            line = readline(stdin)
            isempty(line) && continue

            # Process each request in a separate task
            task = @async begin
                try
                    request = JSON3.read(line, Dict{String,Any})
                    response = process_mcp_request(request)

                    # Only send response if not a notification
                    if !isnothing(response)
                        lock(output_lock) do
                            println(stdout, JSON3.write(response))
                            flush(stdout)
                        end
                    end

                catch e
                    local error_response
                    if e isa JSON3.Error
                        error_response = create_error_response(nothing, -32700, "Parse error: $e")
                    else
                        error_response = create_error_response(nothing, -32603, "Internal error: $e")
                    end
                    lock(output_lock) do
                        println(stdout, JSON3.write(error_response))
                        flush(stdout)
                    end
                end
            end

            push!(active_tasks, task)
            request_count += 1

            # Clean up completed tasks periodically
            if request_count % TASK_CLEANUP_INTERVAL == 0
                filter!(t -> !istaskdone(t), active_tasks)
            end
        end
    finally
        # Wait for all active tasks to complete
        for task in active_tasks
            try
                wait(task)
            catch
            end
        end
    end
end

"""
    run_http_mode(port::Int)

Run in HTTP mode - serve HTTP requests.
Requires HTTP.jl to be loaded.
"""
function run_http_mode(port::Int)
    function handle_request(req::HTTP.Request)
        # Handle CORS preflight
        if req.method == "OPTIONS"
            return HTTP.Response(200, [
                "Access-Control-Allow-Origin" => "*",
                "Access-Control-Allow-Methods" => "POST, GET, OPTIONS",
                "Access-Control-Allow-Headers" => "Content-Type"
            ])
        end

        # Health check
        if req.method == "GET" && req.target == "/health"
            return HTTP.Response(200,
                ["Content-Type" => "application/json", "Access-Control-Allow-Origin" => "*"],
                JSON3.write(Dict("status" => "ok"))
            )
        end

        # Handle POST requests
        if req.method == "POST"
            try
                body = String(req.body)
                if isempty(body)
                    error_resp = create_error_response(nothing, -32600, "Empty request body")
                    return HTTP.Response(400,
                        ["Content-Type" => "application/json", "Access-Control-Allow-Origin" => "*"],
                        JSON3.write(error_resp)
                    )
                end

                request = JSON3.read(body, Dict{String,Any})
                response = process_mcp_request(request)

                if !isnothing(response)
                    return HTTP.Response(200,
                        ["Content-Type" => "application/json", "Access-Control-Allow-Origin" => "*"],
                        JSON3.write(response)
                    )
                end

            catch e
                if e isa JSON3.Error
                    error_resp = create_error_response(nothing, -32700, "Parse error: $e")
                    return HTTP.Response(400,
                        ["Content-Type" => "application/json", "Access-Control-Allow-Origin" => "*"],
                        JSON3.write(error_resp)
                    )
                else
                    error_resp = create_error_response(nothing, -32603, "Internal error: $e")
                    return HTTP.Response(500,
                        ["Content-Type" => "application/json", "Access-Control-Allow-Origin" => "*"],
                        JSON3.write(error_resp)
                    )
                end
            end
        end

        # Invalid request
        error_resp = create_error_response(nothing, -32600, "Use POST for JSON-RPC requests")
        return HTTP.Response(400,
            ["Content-Type" => "application/json", "Access-Control-Allow-Origin" => "*"],
            JSON3.write(error_resp)
        )
    end

    println(stderr, "MCP Julia REPL Multiplexer running on http://localhost:$port")

    try
        HTTP.serve(handle_request, "localhost", port)
    catch e
        if e isa InterruptException
            println(stderr, "\nShutting down HTTP server")
        else
            rethrow(e)
        end
    end
end

"""
    parse_arguments(args::Vector{String}) -> Dict{String,Any}

Parse command line arguments using ArgParse.
"""
function parse_arguments(args::Vector{String})
    s = ArgParseSettings(
        prog = "julia -e 'using MCPRepl; MCPRepl.run_multiplexer(ARGS)' --",
        description = "MCP Julia REPL Multiplexer - MCP server that forwards to Julia REPL servers",
        epilog = "The Julia MCP server must be running in each project directory:\n  julia --project -e \"using MCPRepl; MCPRepl.start!(multiplex=true)\"",
        exit_after_help = false
    )

    @add_arg_table! s begin
        "--transport"
            help = "Transport mode"
            arg_type = String
            default = "stdio"
            range_tester = x -> x in ["stdio", "http"]
        "--port"
            help = "Port for HTTP mode"
            arg_type = Int
            default = 3000
    end

    return parse_args(args, s)
end

"""
    main(args::Vector{String}=ARGS)

Main entry point for the MCP Julia REPL Multiplexer.
"""
function main(args::Vector{String}=ARGS)
    parsed_args = parse_arguments(args)
    transport = parsed_args["transport"]
    port = parsed_args["port"]

    if transport == "stdio"
        run_stdio_mode()
    else
        run_http_mode(port)
    end
end

end # module

# Run main if this file is executed as a script
if abspath(PROGRAM_FILE) == @__FILE__
    MCPPlex.main()
end
