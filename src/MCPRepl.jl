module MCPRepl

using REPL
using HTTP
using JSON3
using Sockets

const SOCKET_NAME = ".mcp-repl.sock"
const PID_FILE_NAME = ".mcp-repl.pid"
const MCP_PROTOCOL_VERSION = "2024-11-05"

include("Tools.jl")
include("MCPServer.jl")
include("MCPPlex.jl")
include("setup.jl")

# Re-export commonly used functions from Tools for backward compatibility
using .Tools: execute_repllike, repl_status_report

"""
    get_project_dir()

Returns the directory containing the active project (Project.toml), or pwd() as fallback.
"""
function get_project_dir()
    proj = Base.active_project()
    if !isnothing(proj) && isfile(proj)
        return dirname(proj)
    end
    return pwd()
end

"""
    multiplexer_command()

Returns the command to run the MCP multiplexer.
This is useful for configuring MCP clients.

Example:
    julia -e 'using MCPRepl; println(MCPRepl.multiplexer_command())'
"""
function multiplexer_command()
    pkg_dir = dirname(dirname(pathof(@__MODULE__)))
    return "julia --project=$(pkg_dir) -e 'using MCPRepl; MCPRepl.run_multiplexer(ARGS)' --"
end

"""
    run_multiplexer(args::Vector{String}=ARGS)

Run the MCP multiplexer with the given arguments.
This is the entry point for the multiplexer when run as part of the MCPRepl package.

Example:
    julia -e 'using MCPRepl; MCPRepl.run_multiplexer(ARGS)' -- --transport stdio
"""
function run_multiplexer(args::Vector{String}=ARGS)
    return MCPPlex.main(args)
end

"""
    get_socket_path(socket_dir::String=get_project_dir())

Returns the path to the Unix socket file in the specified directory.
"""
function get_socket_path(socket_dir::String=get_project_dir())
    return joinpath(socket_dir, SOCKET_NAME)
end

"""
    get_pid_file_path(socket_dir::String=get_project_dir())

Returns the path to the PID file in the specified directory.
"""
function get_pid_file_path(socket_dir::String=get_project_dir())
    return joinpath(socket_dir, PID_FILE_NAME)
end

"""
    process_exists(pid::Integer) -> Bool

Check if a process with the given PID exists using kill(pid, 0).
This doesn't send a signal, just checks if we can signal the process.
Returns true if the process exists, false otherwise.
"""
function process_exists(pid::Integer)
    # kill(pid, 0) returns 0 if process exists and we can signal it
    # Returns -1 if process doesn't exist or we lack permission
    return ccall(:kill, Cint, (Cint, Cint), pid, 0) == 0
end

"""
    write_pid_file(socket_dir::String=get_project_dir()) -> Nothing

Writes the current process ID to the PID file.
"""
function write_pid_file(socket_dir::String=get_project_dir())
    pid_file = get_pid_file_path(socket_dir)
    write(pid_file, string(getpid()))
    return nothing
end

"""
    remove_socket_file(socket_dir::String=get_project_dir()) -> Nothing

Removes the socket file if it exists.
"""
function remove_socket_file(socket_dir::String=get_project_dir())
    socket_path = get_socket_path(socket_dir)
    ispath(socket_path) && rm(socket_path)
    return nothing
end

"""
    remove_pid_file(socket_dir::String=get_project_dir()) -> Nothing

Removes the PID file if it exists.
"""
function remove_pid_file(socket_dir::String=get_project_dir())
    pid_file = get_pid_file_path(socket_dir)
    ispath(pid_file) && rm(pid_file)
    return nothing
end

"""
    check_existing_server(socket_dir::String=get_project_dir())

Checks if an MCP server is already running by checking the PID file.
Returns true if a server is running, false otherwise.
Cleans up stale socket and PID files if no server is running.
"""
function check_existing_server(socket_dir::String=get_project_dir())
    pid_file = get_pid_file_path(socket_dir)
    socket_path = get_socket_path(socket_dir)

    !ispath(pid_file) && !ispath(socket_path) && return false

    # Check PID file
    if ispath(pid_file)
        try
            pid_str = strip(read(pid_file, String))
            pid = parse(Int, pid_str)

            # Check if process exists using direct system call
            if process_exists(pid)
                return true
            end
        catch
            # Invalid PID file or process doesn't exist
        end
    end

    # No server running, clean up stale files
    remove_socket_file(socket_dir)
    remove_pid_file(socket_dir)
    return false
end

SERVER = Ref{Union{Nothing,MCPServer}}(nothing)

function start!(; multiplex::Bool=false,
                 port::Int=3000,
                 socket_dir::Union{String,Nothing}=nothing,
                 verbose::Bool=true)
    SERVER[] !== nothing && stop!() # Stop existing server if running

    # Create tool objects using the Tools module
    # In multiplex mode, tools need project_dir parameter for routing
    include_project_dir = multiplex

    usage_instructions_tool = MCPTool(
        "usage_instructions",
        Tools.get_tool_description("usage_instructions"),
        Tools.make_tool_schema("usage_instructions"; include_project_dir=include_project_dir),
        args -> Tools.handle_usage_instructions()
    )

    repl_tool = MCPTool(
        "exec_repl",
        Tools.get_tool_description("exec_repl"),
        Tools.make_tool_schema("exec_repl"; include_project_dir=include_project_dir),
        args -> Tools.handle_exec_repl(get(args, "expression", ""))
    )

    whitespace_tool = MCPTool(
        "remove-trailing-whitespace",
        Tools.get_tool_description("remove-trailing-whitespace"),
        Tools.make_tool_schema("remove-trailing-whitespace"; include_project_dir=include_project_dir),
        args -> Tools.handle_remove_trailing_whitespace(get(args, "file_path", ""))
    )

    investigate_tool = MCPTool(
        "investigate_environment",
        Tools.get_tool_description("investigate_environment"),
        Tools.make_tool_schema("investigate_environment"; include_project_dir=include_project_dir),
        args -> Tools.handle_investigate_environment()
    )

    tools = [
        usage_instructions_tool,
        repl_tool,
        whitespace_tool,
        investigate_tool
    ]

    # Create and start server
    if multiplex
        # Socket mode for multiplexer
        socket_dir_actual = socket_dir === nothing ? get_project_dir() : socket_dir
        socket_path = get_socket_path(socket_dir_actual)

        # Check for existing server
        if check_existing_server(socket_dir_actual)
            error("MCP server already running at $socket_path")
        end

        SERVER[] = start_mcp_server(tools;
                                    mode=:socket,
                                    socket_path=socket_path,
                                    verbose=verbose)

        # Write PID file
        write_pid_file(socket_dir_actual)

        # Register atexit hook for cleanup
        atexit() do
            if SERVER[] !== nothing && SERVER[].handle isa MCPRepl.SocketServerHandle
                try
                    stop!()
                catch
                end
            end
        end
    else
        # HTTP mode (default)
        SERVER[] = start_mcp_server(tools;
                                    mode=:http,
                                    port=port,
                                    verbose=verbose)
    end

    if isdefined(Base, :active_repl)
        set_prefix!(Base.active_repl)
    else
        atreplinit(set_prefix!)
    end
    return nothing
end

function set_prefix!(repl)
    mode = get_mainmode(repl)
    mode.prompt = REPL.contextual_prompt(repl, "* julia> ")
    return nothing
end

function unset_prefix!(repl)
    mode = get_mainmode(repl)
    mode.prompt = REPL.contextual_prompt(repl, REPL.JULIA_PROMPT)
    return nothing
end

function get_mainmode(repl)
    if isdefined(REPL.LineEdit, :find_mode) && hasmethod(REPL.LineEdit.find_mode, Tuple{Any,Symbol})
        mode = REPL.LineEdit.find_mode(repl.interface.modes, :julia)
        !isnothing(mode) && return mode
    end

    modes = filter(repl.interface.modes) do mode
        mode isa REPL.LineEdit.Prompt && mode.prompt isa Function && contains(mode.prompt(), "julia>")
    end

    if isempty(modes)
        error("Could not find Julia REPL main mode")
    end

    return first(modes)
end

function stop!()
    if SERVER[] !== nothing
        println("Stop existing server...")
        stop_mcp_server(SERVER[])

        SERVER[] = nothing
        if isdefined(Base, :active_repl)
            unset_prefix!(Base.active_repl)
        end
    else
        println("No server running to stop.")
    end
end

end #module
