module MCPRepl

using REPL
using HTTP
using JSON3
using Sockets

const SOCKET_NAME = ".mcp-repl.sock"
const PID_NAME = ".mcp-repl.pid"
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
    get_pid_path(socket_dir::String=get_project_dir())

Returns the path to the PID file in the specified directory.
"""
function get_pid_path(socket_dir::String=get_project_dir())
    return joinpath(socket_dir, PID_NAME)
end

"""
    write_pid_file(socket_dir::String=get_project_dir()) -> Nothing

Writes the current process PID to the PID file.
"""
function write_pid_file(socket_dir::String=get_project_dir())
    write(get_pid_path(socket_dir), string(getpid()))
    return nothing
end

"""
    remove_pid_file(socket_dir::String=get_project_dir()) -> Nothing

Removes the PID file if it exists.
"""
function remove_pid_file(socket_dir::String=get_project_dir())
    pid_path = get_pid_path(socket_dir)
    isfile(pid_path) && rm(pid_path)
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
    check_existing_server(socket_dir::String=get_project_dir())

Checks if an MCP server is already running. Returns true if a server is running,
false otherwise. Cleans up stale PID/socket files if the process is dead.

NOTE: There is a potential race condition between checking for an existing server
and writing the PID file. Two processes starting simultaneously could both see no
existing server and both proceed. This is an inherent limitation of PID file-based
locking and is acceptable for this use case where duplicate servers would fail
quickly due to socket binding conflicts.
"""
function check_existing_server(socket_dir::String=get_project_dir())
    pid_path = get_pid_path(socket_dir)
    socket_path = get_socket_path(socket_dir)

    if !isfile(pid_path)
        # No PID file, clean up any orphaned socket
        remove_socket_file(socket_dir)
        return false
    end

    # Read PID from file
    pid_str = strip(read(pid_path, String))
    pid = tryparse(Int, pid_str)

    if isnothing(pid)
        # Invalid PID file, clean up
        remove_pid_file(socket_dir)
        remove_socket_file(socket_dir)
        return false
    end

    # Check if process is alive (signal 0 tests existence)
    try
        run(pipeline(`kill -0 $pid`, stderr=devnull))
        # Process exists, server is running
        return true
    catch
        # Process is dead, clean up stale files
        remove_pid_file(socket_dir)
        remove_socket_file(socket_dir)
        return false
    end
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

    # Create and start server
    if multiplex
        # Socket mode for multiplexer
        socket_dir_actual = socket_dir === nothing ? get_project_dir() : socket_dir
        socket_path = get_socket_path(socket_dir_actual)

        # Check for existing server
        if check_existing_server(socket_dir_actual)
            error("MCP server already running. Check $(get_pid_path(socket_dir_actual)) for the PID.")
        end

        SERVER[] = start_mcp_server([usage_instructions_tool, repl_tool, whitespace_tool, investigate_tool];
                                    mode=:socket,
                                    socket_path=socket_path,
                                    verbose=verbose)

        # Write PID file after server starts
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
        SERVER[] = start_mcp_server([usage_instructions_tool, repl_tool, whitespace_tool, investigate_tool];
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

        # For socket mode, clean up socket and PID files
        if SERVER[].handle isa MCPRepl.SocketServerHandle
            socket_dir = dirname(SERVER[].handle.socket_path)
            stop_mcp_server(SERVER[])
            remove_pid_file(socket_dir)
            remove_socket_file(socket_dir)
        else
            stop_mcp_server(SERVER[])
        end

        SERVER[] = nothing
        if isdefined(Base, :active_repl)
            unset_prefix!(Base.active_repl)
        end
    else
        println("No server running to stop.")
    end
end

end #module
