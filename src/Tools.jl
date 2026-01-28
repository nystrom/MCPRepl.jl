"""
Tools module containing tool definitions, schemas, and handler implementations.

This module provides:
- Tool metadata (descriptions, parameter specs)
- Schema generation with optional project_dir parameter
- Handler implementations for all tools
- Helper functions for REPL execution and environment inspection
"""
module Tools

using REPL

# Re-export Main.Pkg access for environment inspection
# Note: Main.Pkg must be available at runtime

#==============================================================================#
# Version Compatibility Helpers
#==============================================================================#

"""
    repl_eval_backend(expr, backend)

Evaluate an expression on the REPL backend.
Uses eval_on_backend (Julia 1.12+) or eval_with_backend (earlier versions).
"""
function repl_eval_backend(expr, backend)
    if VERSION >= v"1.12"
        return REPL.eval_on_backend(expr, backend)
    else
        return REPL.eval_with_backend(expr, backend)
    end
end

#==============================================================================#
# Tool Definitions
#==============================================================================#

"""
Tool definitions with metadata (name, description, parameter specs).
"""
const TOOL_DEFINITIONS = Dict(
    "exec_repl" => Dict(
        "description" => """Execute Julia code in a shared, persistent REPL session.

**PREREQUISITE**: Before using this tool, you MUST first call the `usage_instructions` tool.

The tool returns raw text output containing: all printed content from stdout and stderr streams, plus the mime text/plain representation of the expression's return value (unless the expression ends with a semicolon).

You may use this REPL to execute julia code, run test sets, get function documentation, etc.""",
        "parameters" => Dict(
            "expression" => Dict(
                "type" => "string",
                "description" => "Julia expression to evaluate (e.g., '2 + 3 * 4' or `import Pkg; Pkg.status()`)"
            )
        ),
        "required" => ["expression"]
    ),
    "investigate_environment" => Dict(
        "description" => """Investigate the current Julia environment including pwd, active project, packages, and development packages with their paths.

This tool provides comprehensive information about:
- Current working directory
- Active project and its details
- All packages in the environment with development status
- Development packages with their file system paths
- Current environment package status
- Revise.jl status for hot reloading""",
        "parameters" => Dict(),
        "required" => String[]
    ),
    "usage_instructions" => Dict(
        "description" => "Get detailed instructions for proper Julia REPL usage, best practices, and workflow guidelines.",
        "parameters" => Dict(),
        "required" => String[]
    ),
    "remove-trailing-whitespace" => Dict(
        "description" => """Remove trailing whitespace from all lines in a file.

This tool should be called to clean up any trailing spaces that AI agents tend to leave in files after editing.

**Usage Guidelines:**
- For single file edits: Call immediately after editing the file
- For multiple file edits: Call once on each modified file at the very end, before handing back to the user
- Always call this tool on files you've edited to maintain clean, professional code formatting

The tool efficiently removes all types of trailing whitespace (spaces, tabs, mixed) from every line in the file.""",
        "parameters" => Dict(
            "file_path" => Dict(
                "type" => "string",
                "description" => "Absolute path to the file to clean up"
            )
        ),
        "required" => ["file_path"]
    )
)

#==============================================================================#
# Schema Generation
#==============================================================================#

"""
    make_tool_schema(tool_name::String; include_project_dir::Bool=false) -> Dict

Generate a JSON schema for a tool's input parameters.

When `include_project_dir=true`, adds a project_dir parameter and makes it required.
This is used for multiplexed socket mode where the multiplexer needs to know which
Julia server to route requests to.
"""
function make_tool_schema(tool_name::String; include_project_dir::Bool=false)
    if !haskey(TOOL_DEFINITIONS, tool_name)
        error("Unknown tool: $tool_name")
    end

    tool_def = TOOL_DEFINITIONS[tool_name]
    properties = Dict{String,Any}()
    required = copy(tool_def["required"])

    # Add tool-specific parameters
    for (param_name, param_def) in tool_def["parameters"]
        properties[param_name] = param_def
    end

    # Add project_dir parameter if requested
    if include_project_dir
        properties["project_dir"] = Dict(
            "type" => "string",
            "description" => "Directory where the Julia project is located (used to find the REPL socket)"
        )
        pushfirst!(required, "project_dir")
    end

    return Dict(
        "type" => "object",
        "properties" => properties,
        "required" => required
    )
end

"""
    get_tool_description(tool_name::String) -> String

Get the description for a tool.
"""
function get_tool_description(tool_name::String)
    if !haskey(TOOL_DEFINITIONS, tool_name)
        error("Unknown tool: $tool_name")
    end
    return TOOL_DEFINITIONS[tool_name]["description"]
end

"""
    get_tool_names() -> Vector{String}

Get the list of all available tool names.
"""
function get_tool_names()
    return collect(keys(TOOL_DEFINITIONS))
end

#==============================================================================#
# Display Helper for REPL Output
#==============================================================================#

struct IOBufferDisplay <: AbstractDisplay
    io::IOBuffer
    IOBufferDisplay() = new(IOBuffer())
end
Base.displayable(::IOBufferDisplay, _) = true
Base.display(d::IOBufferDisplay, x) = show(d.io, MIME("text/plain"), x)
Base.display(d::IOBufferDisplay, mime, x) = show(d.io, mime, x)

#==============================================================================#
# Helper Functions for REPL Execution
#==============================================================================#

"""
    validate_expression(str::AbstractString) -> Union{String, Nothing}

Validate expression against policy rules. Returns error message if validation fails,
nothing if validation passes.
"""
function validate_expression(str::AbstractString)
    if contains(str, "Pkg.activate(")
        return """
            ERROR: Using Pkg.activate to change environments is not allowed.
            You should assume you are in the correct environment for your tasks.
            You may use Pkg.status() to see the current environment and available packages.
        """
    end

    if contains(str, "Pkg.add(")
        return """
            ERROR: Using Pkg.add to install packages is not allowed.
            You should assume all necessary packages are already installed in the environment.
            If you need another package, prompt the user.
        """
    end

    if contains(str, "varinfo(")
        return """
            ERROR: Using varinfo() is not allowed because it takes too long to execute.
            Use the investigate_environment tool instead to get information about the Julia environment.
            If unclear, ask the user.
        """
    end

    return nothing
end

"""
    preprocess_expression(str::AbstractString) -> String

Preprocess expression by wrapping using/import statements with @eval to suppress
interactive installation prompts.
"""
function preprocess_expression(str::AbstractString)
    if contains(str, r"(^|\n)using\s") || contains(str, r"(^|\n)import\s")
        str = replace(str, r"(^|\n)(using\s[^\n]*)" => s"\1@eval \2")
        str = replace(str, r"(^|\n)(import\s[^\n]*)" => s"\1@eval \2")
    end
    return str
end

"""
    print_response(io::IO, response, backend, show_value::Bool, have_color::Bool, disp)

Version-compatible wrapper for REPL.print_response that handles API changes in Julia 1.11+.
"""
function print_response(io::IO, response, backend, show_value::Bool, have_color::Bool, disp)
    if VERSION >= v"1.11"
        REPL.print_response(io, response, backend, show_value, have_color, disp)
    else
        REPL.print_response(io, response, show_value, have_color, disp)
    end
    return nothing
end

"""
    execute_repllike(str) -> String

Execute an expression in REPL-like fashion, capturing output and display.
"""
function execute_repllike(str)
    error_msg = validate_expression(str)
    if !isnothing(error_msg)
        return error_msg
    end

    str = preprocess_expression(str)

    repl = Base.active_repl
    expr = Base.parse_input_line(str)
    backend = repl.backendref

    REPL.prepare_next(repl)
    printstyled("\nagent> ", color=:red, bold=:true)
    print(str, "\n")

    captured_output = Pipe()
    response = redirect_stdout(captured_output) do
        redirect_stderr(captured_output) do
            r = repl_eval_backend(expr, backend)
            close(Base.pipe_writer(captured_output))
            return r
        end
    end
    captured_content = read(captured_output, String)
    print(captured_content)

    disp = IOBufferDisplay()

    show_value = !REPL.ends_with_semicolon(str)
    print_response(disp.io, response, backend, show_value, false, disp)

    REPL.print_response(repl, response, show_value, repl.hascolor)

    REPL.prepare_next(repl)
    REPL.LineEdit.refresh_line(repl.mistate)

    display_content = String(take!(disp.io))

    return captured_content * display_content
end

#==============================================================================#
# Helper Functions for Environment Inspection
#==============================================================================#

"""
    get_environment_info()

Gather basic environment information including current directory and active project.
Returns a Dict with keys: :cwd, :active_project, :project_data.
"""
function get_environment_info()
    if !isdefined(Main, :Pkg)
        @warn "Main.Pkg is not defined"
        return Dict(
            :cwd => pwd(),
            :active_project => nothing,
            :project_data => nothing
        )
    end
    Pkg = Main.Pkg

    active_proj = Base.active_project()
    project_data = nothing
    if active_proj !== nothing && isfile(active_proj)
        try
            project_data = Pkg.TOML.parsefile(active_proj)
        catch
            project_data = nothing
        end
    end

    return Dict(
        :cwd => pwd(),
        :active_project => active_proj,
        :project_data => project_data
    )
end

"""
    get_package_info(active_proj::Union{String,Nothing}, project_data::Union{Dict,Nothing})

Gather package information including dependencies, development packages, and current environment package.
Returns a Dict with keys: :current_env_package, :dev_deps, :regular_deps, :dev_packages, :has_revise.
"""
function get_package_info(active_proj::Union{String,Nothing}, project_data::Union{Dict,Nothing})
    if !isdefined(Main, :Pkg)
        @warn "Main.Pkg is not defined"
        return Dict(
            :current_env_package => nothing,
            :dev_deps => [],
            :regular_deps => [],
            :dev_packages => Dict{String,String}(),
            :has_revise => false
        )
    end
    Pkg = Main.Pkg

    current_env_package = nothing
    dev_deps = []
    regular_deps = []
    dev_packages = Dict{String,String}()

    try
        redirect_stdout(devnull) do
            Pkg.status(; mode = Pkg.PKGMODE_MANIFEST)
        end

        deps = Pkg.dependencies()

        for (uuid, pkg_info) in deps
            if pkg_info.is_direct_dep && pkg_info.is_tracking_path
                dev_packages[pkg_info.name] = pkg_info.source
            end
        end

        if !isnothing(project_data) && haskey(project_data, "uuid")
            pkg_name = get(project_data, "name", basename(dirname(active_proj)))
            pkg_dir = dirname(active_proj)
            dev_packages[pkg_name] = pkg_dir

            pkg_version = get(project_data, "version", "dev")
            pkg_uuid = project_data["uuid"]
            current_env_package = (name = pkg_name, version = pkg_version, uuid = pkg_uuid, path = pkg_dir)
        end

        for (uuid, pkg_info) in deps
            if pkg_info.is_direct_dep
                if haskey(dev_packages, pkg_info.name)
                    push!(dev_deps, pkg_info)
                else
                    push!(regular_deps, pkg_info)
                end
            end
        end
    catch e
        @warn "Error getting package status" exception=e
    end

    has_revise = isdefined(Main, :Revise)

    return Dict(
        :current_env_package => current_env_package,
        :dev_deps => dev_deps,
        :regular_deps => regular_deps,
        :dev_packages => dev_packages,
        :has_revise => has_revise
    )
end

"""
    format_status_report(env_info::Dict{Symbol,Any}, pkg_info::Dict{Symbol,Any}) -> Nothing

Format and print the status report from gathered environment and package information.
"""
function format_status_report(env_info::Dict{Symbol,Any}, pkg_info::Dict{Symbol,Any})
    println("Julia Environment Investigation")
    println("=" ^ 50)
    println()

    println("Current Directory:")
    println("   $(env_info[:cwd])")
    println()

    println("Active Project:")
    active_proj = env_info[:active_project]
    project_data = env_info[:project_data]
    if active_proj !== nothing
        println("   Path: $active_proj")
        if !isnothing(project_data)
            if haskey(project_data, "name")
                println("   Name: $(project_data["name"])")
            else
                println("   Name: $(basename(dirname(active_proj)))")
            end
            if haskey(project_data, "version")
                println("   Version: $(project_data["version"])")
            end
        else
            println("   Error reading project info")
        end
    else
        println("   No active project")
    end
    println()

    println("Package Environment:")
    current_env_package = pkg_info[:current_env_package]
    dev_deps = pkg_info[:dev_deps]
    regular_deps = pkg_info[:regular_deps]
    dev_packages = pkg_info[:dev_packages]

    has_dev_packages = !isempty(dev_deps) || current_env_package !== nothing
    if has_dev_packages
        println("   Development packages (tracked by Revise):")

        if current_env_package !== nothing
            println("      $(current_env_package.name) v$(current_env_package.version) [CURRENT ENV] => $(current_env_package.path)")
            try
                pkg_dir = pkgdir(current_env_package.name)
                if pkg_dir !== nothing && pkg_dir != current_env_package.path
                    println("         pkgdir(): $pkg_dir")
                end
            catch
            end
        end

        for pkg_info in dev_deps
            if current_env_package !== nothing && pkg_info.name == current_env_package.name
                continue
            end
            println("      $(pkg_info.name) v$(pkg_info.version) => $(dev_packages[pkg_info.name])")
            try
                pkg_dir = pkgdir(pkg_info.name)
                if pkg_dir !== nothing && pkg_dir != dev_packages[pkg_info.name]
                    println("         pkgdir(): $pkg_dir")
                end
            catch
            end
        end
        println()
    end

    if !isempty(regular_deps)
        println("   Other packages in environment:")
        for pkg_info in regular_deps
            println("      $(pkg_info.name) v$(pkg_info.version)")
        end
    end

    if isempty(dev_deps) && isempty(regular_deps) && current_env_package === nothing
        println("   No packages in environment")
    end

    println()
    println("Revise.jl Status:")
    if pkg_info[:has_revise]
        println("   Revise.jl is loaded and active")
        println("   Development packages will auto-reload on changes")
    else
        println("   Revise.jl is not loaded")
    end

    return nothing
end

"""
    repl_status_report() -> Nothing

Generate and print a comprehensive Julia environment status report.
"""
function repl_status_report()
    try
        env_info = get_environment_info()
        pkg_info = get_package_info(env_info[:active_project], env_info[:project_data])
        format_status_report(env_info, pkg_info)
        return nothing
    catch e
        println("Error generating environment report: $e")
        return nothing
    end
end

#==============================================================================#
# Tool Handler Implementations
#==============================================================================#

"""
    handle_exec_repl(expression::String) -> String

Execute Julia code in the REPL and return the output.
"""
function handle_exec_repl(expression::String)
    try
        execute_repllike(expression)
    catch e
        println("Error during execute_repllike", e)
        "Apparently there was an **internal** error to the MCP server: $e"
    end
end

"""
    handle_investigate_environment() -> String

Get comprehensive environment information and return as string.
"""
function handle_investigate_environment()
    try
        execute_repllike("MCPRepl.Tools.repl_status_report()")
    catch e
        "Error investigating environment: $e"
    end
end

"""
    handle_usage_instructions() -> String

Return the usage instructions markdown content.
"""
function handle_usage_instructions()
    try
        # Walk up from this file to find the package root
        pkg_dir = dirname(dirname(@__DIR__))
        workflow_path = joinpath(pkg_dir, "prompts", "julia_repl_workflow.md")
        if isfile(workflow_path)
            return read(workflow_path, String)
        else
            return "Error: julia_repl_workflow.md not found at $workflow_path"
        end
    catch e
        return "Error reading usage instructions: $e"
    end
end

"""
    handle_remove_trailing_whitespace(file_path::String) -> String

Remove trailing whitespace from all lines in a file.
"""
function handle_remove_trailing_whitespace(file_path::String)
    try
        if isempty(file_path)
            return "Error: file_path parameter is required"
        end

        if !isfile(file_path)
            return "Error: File does not exist: $file_path"
        end

        # Use sed to remove trailing whitespace (similar to emacs delete-trailing-whitespace)
        # This removes all trailing whitespace characters from each line
        result = run(pipeline(`sed -i '' 's/[[:space:]]*$//' $file_path`, stderr=devnull))

        if result.exitcode == 0
            return "Successfully removed trailing whitespace from $file_path"
        else
            return "Error: Failed to remove trailing whitespace from $file_path"
        end
    catch e
        return "Error removing trailing whitespace: $e"
    end
end

end # module Tools
