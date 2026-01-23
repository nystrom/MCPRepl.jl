# Tool definition structure
struct MCPTool
    name::String
    description::String
    parameters::Dict{String,Any}
    handler::Function
end

# Server with tool registry supporting both HTTP and socket modes
mutable struct MCPServer
    mode::Symbol  # :http or :socket
    # HTTP mode fields
    port::Union{Int,Nothing}
    http_server::Union{HTTP.Server,Nothing}
    # Socket mode fields
    socket_path::Union{String,Nothing}
    socket_server::Union{Sockets.PipeServer,Nothing}
    # Common fields
    running::Bool
    client_tasks::Vector{Task}
    tools::Dict{String,MCPTool}
end

const MCP_PROTOCOL_VERSION = "2024-11-05"

# Process a JSON-RPC request and return a response Dict
function process_jsonrpc_request(request::Dict{String,Any}, tools::Dict{String,MCPTool})
    # Check if method field exists
    if !haskey(request, "method")
        return Dict(
            "jsonrpc" => "2.0",
            "id" => get(request, "id", 0),
            "error" => Dict(
                "code" => -32600,
                "message" => "Invalid Request - missing method field"
            )
        )
    end

    method = request["method"]
    request_id = get(request, "id", nothing)

    # Handle initialization
    if method == "initialize"
        return Dict(
            "jsonrpc" => "2.0",
            "id" => request_id,
            "result" => Dict(
                "protocolVersion" => MCP_PROTOCOL_VERSION,
                "capabilities" => Dict(
                    "tools" => Dict()
                ),
                "serverInfo" => Dict(
                    "name" => "julia-mcp-server",
                    "version" => "1.0.0"
                )
            )
        )
    end

    # Handle initialized notification
    if method == "notifications/initialized"
        return nothing  # Notifications don't get responses
    end

    # Handle tool listing
    if method == "tools/list"
        tool_list = [
            Dict(
                "name" => tool.name,
                "description" => tool.description,
                "inputSchema" => tool.parameters
            ) for tool in values(tools)
        ]
        return Dict(
            "jsonrpc" => "2.0",
            "id" => request_id,
            "result" => Dict("tools" => tool_list)
        )
    end

    # Handle tool calls
    if method == "tools/call"
        params = get(request, "params", Dict())
        tool_name = get(params, "name", "")
        if haskey(tools, tool_name)
            tool = tools[tool_name]
            args = get(params, "arguments", Dict())

            # Call the tool handler
            result_text = tool.handler(args)

            return Dict(
                "jsonrpc" => "2.0",
                "id" => request_id,
                "result" => Dict(
                    "content" => [
                        Dict(
                            "type" => "text",
                            "text" => result_text
                        )
                    ]
                )
            )
        else
            return Dict(
                "jsonrpc" => "2.0",
                "id" => request_id,
                "error" => Dict(
                    "code" => -32602,
                    "message" => "Tool not found: $tool_name"
                )
            )
        end
    end

    # Method not found
    return Dict(
        "jsonrpc" => "2.0",
        "id" => request_id,
        "error" => Dict(
            "code" => -32601,
            "message" => "Method not found: $method"
        )
    )
end

# Handle a single socket client connection
function handle_socket_client(client::IO, tools::Dict{String,MCPTool})
    try
        while isopen(client)
            line = readline(client)
            isempty(line) && continue

            request_id = 0
            try
                request = JSON3.read(line, Dict{String,Any})
                request_id = get(request, "id", 0)
                response = process_jsonrpc_request(request, tools)

                # Only send response if not a notification
                if !isnothing(response)
                    println(client, JSON3.write(response))
                end
            catch e
                if e isa EOFError
                    break
                end

                printstyled("\nMCP Server error: $e\n", color=:red)

                error_response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => request_id,
                    "error" => Dict(
                        "code" => -32603,
                        "message" => "Internal error: $e"
                    )
                )
                println(client, JSON3.write(error_response))
            end
        end
    catch e
        if !(e isa EOFError || e isa Base.IOError)
            printstyled("\nMCP client handler error: $e\n", color=:red)
        end
    finally
        try
            close(client)
        catch
        end
    end
end

# Create request handler with access to tools
function create_handler(tools::Dict{String,MCPTool}, port::Int)
    return function handle_request(req::HTTP.Request)
        # Parse JSON-RPC request
        body = String(req.body)

        try
            # Handle OAuth well-known metadata requests first (before JSON parsing)
            if req.target == "/.well-known/oauth-authorization-server"
                oauth_metadata = Dict(
                    "issuer" => "http://localhost:$port",
                    "authorization_endpoint" => "http://localhost:$port/oauth/authorize",
                    "token_endpoint" => "http://localhost:$port/oauth/token",
                    "registration_endpoint" => "http://localhost:$port/oauth/register",
                    "grant_types_supported" => ["authorization_code", "client_credentials"],
                    "response_types_supported" => ["code"],
                    "scopes_supported" => ["read", "write"],
                    "client_registration_types_supported" => ["dynamic"],
                    "code_challenge_methods_supported" => ["S256"]
                )
                return HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(oauth_metadata))
            end

            # Handle dynamic client registration
            if req.target == "/oauth/register" && req.method == "POST"
                client_id = "claude-code-" * string(rand(UInt64), base=16)
                client_secret = string(rand(UInt128), base=16)

                registration_response = Dict(
                    "client_id" => client_id,
                    "client_secret" => client_secret,
                    "client_id_issued_at" => Int(floor(time())),
                    "grant_types" => ["authorization_code", "client_credentials"],
                    "response_types" => ["code"],
                    "redirect_uris" => ["http://localhost:8080/callback", "http://127.0.0.1:8080/callback"],
                    "token_endpoint_auth_method" => "client_secret_basic",
                    "scope" => "read write"
                )
                return HTTP.Response(201, ["Content-Type" => "application/json"], JSON3.write(registration_response))
            end

            # Handle authorization endpoint
            if startswith(req.target, "/oauth/authorize")
                # For local development, auto-approve all requests
                uri = HTTP.URI(req.target)
                query_params = HTTP.queryparams(uri)
                redirect_uri = get(query_params, "redirect_uri", "")
                state = get(query_params, "state", "")

                auth_code = "auth_" * string(rand(UInt64), base=16)
                redirect_url = "$redirect_uri?code=$auth_code&state=$state"

                return HTTP.Response(302, ["Location" => redirect_url], "")
            end

            # Handle token endpoint
            if req.target == "/oauth/token" && req.method == "POST"
                access_token = "access_" * string(rand(UInt128), base=16)

                token_response = Dict(
                    "access_token" => access_token,
                    "token_type" => "Bearer",
                    "expires_in" => 3600,
                    "scope" => "read write"
                )
                return HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(token_response))
            end

            # Handle empty body (like GET requests)
            if isempty(body)
                error_response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => 0,
                    "error" => Dict(
                        "code" => -32600,
                        "message" => "Invalid Request - empty body"
                    )
                )
                return HTTP.Response(400, ["Content-Type" => "application/json"], JSON3.write(error_response))
            end

            # Parse JSON and convert to Dict{String,Any}
            request_raw = JSON3.read(body)
            request = Dict{String,Any}()
            for (k, v) in pairs(request_raw)
                request[string(k)] = v
            end

            # Process request using common function
            response = process_jsonrpc_request(request, tools)

            # Handle notifications (no response)
            if isnothing(response)
                return HTTP.Response(200, ["Content-Type" => "application/json"], "{}")
            end

            return HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(response))

        catch e
            # Internal error - show in REPL and return to client
            printstyled("\nMCP Server error: $e\n", color=:red)

            # Try to get the original request ID for proper JSON-RPC error response
            request_id = 0  # Default to 0 instead of nothing to satisfy JSON-RPC schema
            try
                if !isempty(body)
                    parsed_request = JSON3.read(body)
                    # Only use the request ID if it's a valid JSON-RPC ID (string or number)
                    raw_id = get(parsed_request, :id, 0)
                    if raw_id isa Union{String, Number}
                        request_id = raw_id
                    end
                end
            catch
                # If we can't parse the request, use default ID
                request_id = 0
            end

            error_response = Dict(
                "jsonrpc" => "2.0",
                "id" => request_id,
                "error" => Dict(
                    "code" => -32603,
                    "message" => "Internal error: $e"
                )
            )
            return HTTP.Response(500, ["Content-Type" => "application/json"], JSON3.write(error_response))
        end
    end
end

# Convenience function to create a simple text parameter schema
function text_parameter(name::String, description::String, required::Bool=true)
    schema = Dict(
        "type" => "object",
        "properties" => Dict(
            name => Dict(
                "type" => "string",
                "description" => description
            )
        )
    )
    if required
        schema["required"] = [name]
    end
    return schema
end

const MAX_CLIENTS = 10

function start_mcp_server(tools::Vector{MCPTool};
                         mode::Symbol=:http,
                         port::Int=3000,
                         socket_path::Union{String,Nothing}=nothing,
                         verbose::Bool=true)
    tools_dict = Dict(tool.name => tool for tool in tools)

    if mode == :http
        # HTTP mode
        handler = create_handler(tools_dict, port)

        # Suppress HTTP server logging
        http_server = HTTP.serve!(handler, port; verbose=false)

        if verbose
            # Check MCP status and show contextual message
            claude_status = MCPRepl.check_claude_status()
            gemini_status = MCPRepl.check_gemini_status()

            # Claude status
            if claude_status == :configured_http
                println("✅ Claude: MCP server configured (HTTP transport)")
            elseif claude_status == :configured_script
                println("✅ Claude: MCP server configured (script transport)")
            elseif claude_status == :configured_unknown
                println("✅ Claude: MCP server configured")
            elseif claude_status == :claude_not_found
                println("⚠️ Claude: Not found in PATH")
            else
                println("⚠️ Claude: MCP server not configured")
            end

            # Gemini status
            if gemini_status == :configured_http
                println("✅ Gemini: MCP server configured (HTTP transport)")
            elseif gemini_status == :configured_script
                println("✅ Gemini: MCP server configured (script transport)")
            elseif gemini_status == :configured_unknown
                println("✅ Gemini: MCP server configured")
            elseif gemini_status == :gemini_not_found
                println("⚠️ Gemini: Not found in PATH")
            else
                println("⚠️ Gemini: MCP server not configured")
            end

            # Show setup guidance if needed
            if claude_status == :not_configured || gemini_status == :not_configured
                println()
                println("💡 Call MCPRepl.setup() to configure MCP servers interactively")
            end

            println()
            println("🚀 MCP Server running on port $port with $(length(tools)) tools")
            println()
        else
            println("MCP Server running on port $port with $(length(tools)) tools")
        end

        return MCPServer(:http, port, http_server, nothing, nothing, true, Task[], tools_dict)

    elseif mode == :socket
        # Socket mode
        if isnothing(socket_path)
            error("socket_path is required for socket mode")
        end

        # Remove existing socket if present
        ispath(socket_path) && rm(socket_path)

        socket_server = Sockets.listen(socket_path)
        mcp_server = MCPServer(:socket, nothing, nothing, socket_path, socket_server, true, Task[], tools_dict)

        # Start accepting clients in background
        @async begin
            while mcp_server.running
                try
                    client = accept(socket_server)

                    # Clean up completed tasks before adding new one
                    filter!(t -> !istaskdone(t), mcp_server.client_tasks)

                    # Check client limit
                    if length(mcp_server.client_tasks) >= MAX_CLIENTS
                        printstyled("\nMCP Server: max clients ($MAX_CLIENTS) reached, rejecting connection\n", color=:yellow)
                        close(client)
                        continue
                    end

                    task = @async handle_socket_client(client, tools_dict)
                    push!(mcp_server.client_tasks, task)
                catch e
                    if mcp_server.running && !(e isa Base.IOError)
                        printstyled("\nMCP Server accept error: $e\n", color=:red)
                    end
                end
            end
        end

        if verbose
            println("🚀 MCP Server running on $socket_path with $(length(tools)) tools")
            println()
        else
            println("MCP Server running on $socket_path with $(length(tools)) tools")
        end

        return mcp_server

    else
        error("Invalid mode: $mode (must be :http or :socket)")
    end
end

function stop_mcp_server(server::MCPServer)
    if server.mode == :http
        # HTTP mode
        if !isnothing(server.http_server)
            HTTP.close(server.http_server)
        end
    elseif server.mode == :socket
        # Socket mode
        server.running = false

        # Close the server socket
        if !isnothing(server.socket_server)
            try
                close(server.socket_server)
            catch
            end
        end

        # Wait for client tasks to finish
        for task in server.client_tasks
            try
                wait(task)
            catch
            end
        end
        empty!(server.client_tasks)

        # Remove socket
        if !isnothing(server.socket_path) && ispath(server.socket_path)
            rm(server.socket_path)
        end
    end

    println("MCP Server stopped")
end
