# MCPRepl.jl

I strongly believe that REPL-driven development is the best thing you can do in Julia, so AI Agents should learn it too!

MCPRepl.jl is a Julia package which exposes your REPL as an MCP server -- so that the agent can connect to it and execute code in your environment.
The code the Agent sends will show up in the REPL as well as your own commands. You're both working in the same state.


Ideally, this enables the Agent to, for example, execute and fix testsets interactively one by one, circumventing any time-to-first-plot issues.

> [!TIP]
> I am not sure how much work I'll put in this package in the future, check out @kahliburke's much more active [fork](https://github.com/kahliburke/MCPRepl.jl).

## Showcase

https://github.com/user-attachments/assets/1c7546c4-23a3-4528-b222-fc8635af810d

## Installation

This package is not registered in the official Julia General registry due to the security implications of its use. To install it, you must do so directly from the source repository.

You can add the package using the Julia package manager:

```julia
pkg> add https://github.com/hexaeder/MCPRepl.jl
```
or
```julia
pkg> dev https://github.com/hexaeder/MCPRepl.jl
```

## Usage

MCPRepl.jl supports two modes of operation:

1. **HTTP Mode (Simple, Default)**: Single REPL server on port 3000
2. **Socket Mode (Advanced)**: Multiple REPL servers with multiplexer routing

### HTTP Mode (Recommended for Single Project)

HTTP mode is simpler and suitable when working in one Julia project.

**Start the server:**

```julia-repl
julia> using MCPRepl
julia> MCPRepl.start!()
🚀 MCP Server running on port 3000 with 4 tools
```

**Configure Claude Code:**

```sh
claude mcp add julia-repl http://localhost:3000 --transport http
```

**Configure Claude Desktop:**

Add to `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS) or `%APPDATA%\Claude\claude_desktop_config.json` (Windows):

```json
{
  "mcpServers": {
    "julia-repl": {
      "command": "julia",
      "args": ["-e", "using MCPRepl; MCPRepl.start!(); wait()"],
      "url": "http://localhost:3000"
    }
  }
}
```

### Socket Mode (Advanced, Multi-Project)

Socket mode uses Unix sockets and a multiplexer to route requests to multiple Julia REPL servers running in different project directories.

**Start REPL servers in each project:**

```julia-repl
# In project 1
julia> using MCPRepl
julia> MCPRepl.start!(use_socket=true)
🚀 MCP Server running on /path/to/project1/.mcp-repl.sock with 4 tools

# In project 2
julia> using MCPRepl
julia> MCPRepl.start!(use_socket=true)
🚀 MCP Server running on /path/to/project2/.mcp-repl.sock with 4 tools
```

This creates a Unix socket file (`.mcp-repl.sock`) and PID file (`.mcp-repl.pid`) in each project directory.

**Configure Claude Code:**

```sh
claude mcp add julia-repl $(julia -e 'using MCPRepl; println(MCPRepl.multiplexer_command())')
```

**Configure Claude Desktop:**

```json
{
  "mcpServers": {
    "julia-repl": {
      "command": "julia",
      "args": ["-e", "using MCPRepl; MCPRepl.run_multiplexer(ARGS)", "--"]
    }
  }
}
```

**Configure Codeium (Windsurf):**

```json
{
  "mcpServers": {
    "julia-repl": {
      "command": "julia",
      "args": ["-e", "using MCPRepl; MCPRepl.run_multiplexer(ARGS)", "--"]
    }
  }
}
```

**Configure Gemini CLI:**

Add to `~/.config/gemini/mcp_config.json`:

```json
{
  "mcpServers": {
    "julia-repl": {
      "command": "julia",
      "args": ["-e", "using MCPRepl; MCPRepl.run_multiplexer(ARGS)", "--"]
    }
  }
}
```

### Using the Tools

**HTTP Mode tools:**
- **`exec_repl(expression)`**: Execute Julia code in the REPL
- **`investigate_environment()`**: Get information about packages and environment
- **`usage_instructions()`**: Get best practices for using the REPL
- **`remove-trailing-whitespace(file_path)`**: Clean up trailing whitespace in files

**Socket Mode tools** (require `project_dir` parameter):
- **`exec_repl(project_dir, expression)`**: Execute Julia code in the REPL
- **`investigate_environment(project_dir)`**: Get information about packages and environment
- **`usage_instructions(project_dir)`**: Get best practices for using the REPL

The `project_dir` parameter tells the multiplexer where to find the Julia server socket (by walking up from that directory to find `.mcp-repl.sock`).

## Disclaimer and Security Warning

The core functionality of MCPRepl.jl involves opening a network port and executing any code that is sent to it. This is inherently dangerous and borderline stupid, but that's how it is in the great new world of coding agents.

By using this software, you acknowledge and accept the following:

*   **Risk of Arbitrary Code Execution:** Anyone who can connect to the open port will be able to execute arbitrary code on the host machine with the same privileges as the Julia process.
*   **No Warranties:** This software is provided "as is" without any warranties of any kind. The developers are not responsible for any damage, data loss, or other security breaches that may result from its use.

It is strongly recommended that you only use this package on isolated systems or networks where you have complete control over who can access the port. **Use at your own risk.**


## Similar Packages
- [ModelContexProtocol.jl](https://github.com/JuliaSMLM/ModelContextProtocol.jl) offers a way of defining your own servers. Since MCPRepl is using a HTTP server I decieded to not go with this package.

- [REPLicant.jl](https://github.com/MichaelHatherly/REPLicant.jl) is very similar, but the focus of MCPRepl.jl is to integrate with the user repl so you can see what your agent is doing.
