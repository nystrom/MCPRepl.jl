using Test
using MCPRepl
using MCPRepl: MCPTool
using HTTP
using JSON3
using Dates
using Sockets

@testset "MCPRepl Tests" begin
    @testset "MCP Server Tests" begin
        # Create test tools
        time_tool = MCPTool(
            "get_time",
            "Get current time in specified format",
            MCPRepl.text_parameter("format", "DateTime format string (e.g., 'yyyy-mm-dd HH:MM:SS')"),
            args -> Dates.format(now(), get(args, "format", "yyyy-mm-dd HH:MM:SS"))
        )

        reverse_tool = MCPTool(
            "reverse_text",
            "Reverse the input text",
            MCPRepl.text_parameter("text", "Text to reverse"),
            args -> reverse(get(args, "text", ""))
        )

        calc_tool = MCPTool(
            "calculate",
            "Evaluate a simple Julia expression",
            MCPRepl.text_parameter("expression", "Julia expression to evaluate (e.g., '2 + 3 * 4')"),
            function(args)
                try
                    expr = Meta.parse(get(args, "expression", "0"))
                    result = eval(expr)
                    string(result)
                catch e
                    "Error: $e"
                end
            end
        )

        tools = [time_tool, reverse_tool, calc_tool]

        @testset "HTTP Server Startup and Shutdown" begin
            # Start server on test port
            test_port = 3001
            server = MCPRepl.start_mcp_server(tools; mode=:http, port=test_port, verbose=false)

            @test server.handle isa MCPRepl.HttpServerHandle
            @test server.handle.port == test_port
            @test length(server.tools) == 3
            @test haskey(server.tools, "get_time")
            @test haskey(server.tools, "reverse_text")
            @test haskey(server.tools, "calculate")

            # Give server time to start
            sleep(0.1)

            # Stop server
            MCPRepl.stop_mcp_server(server)

            # Give server time to stop
            sleep(0.1)
        end

        @testset "Empty Body Handling" begin
            # Start server for empty body tests
            test_port = 3002
            server = MCPRepl.start_mcp_server(tools; mode=:http, port=test_port, verbose=false)

            # Give server time to start
            sleep(0.1)

            try
                # Test GET request with empty body - expect 400 status exception
                response = try
                    HTTP.get("http://localhost:$test_port/")
                catch e
                    if e isa HTTP.Exceptions.StatusError && e.status == 400
                        e.response
                    else
                        rethrow(e)
                    end
                end

                @test response.status == 400
                @test HTTP.header(response, "Content-Type") == "application/json"

                # Parse response JSON
                body = String(response.body)
                json_response = JSON3.read(body)

                @test json_response.jsonrpc == "2.0"
                @test json_response.error.code == -32600
                @test occursin("Invalid Request", json_response.error.message)
                @test occursin("empty body", json_response.error.message)
                @test occursin("empty body", json_response.error.message)

            finally
                # Always stop server
                MCPRepl.stop_mcp_server(server)
                sleep(0.1)
            end
        end

        @testset "Tool Listing" begin
            # Start server for tool listing tests
            test_port = 3003
            server = MCPRepl.start_mcp_server(tools; mode=:http, port=test_port, verbose=false)

            # Give server time to start
            sleep(0.1)

            try
                # Test tools/list request
                request_body = JSON3.write(Dict(
                    "jsonrpc" => "2.0",
                    "id" => 1,
                    "method" => "tools/list"
                ))

                response = HTTP.post(
                    "http://localhost:$test_port/",
                    ["Content-Type" => "application/json"],
                    request_body
                )

                @test response.status == 200

                # Parse response
                body = String(response.body)
                json_response = JSON3.read(body)

                @test json_response.jsonrpc == "2.0"
                @test json_response.id == 1
                @test haskey(json_response.result, "tools")
                @test length(json_response.result.tools) == 3

                # Check tool names
                tool_names = [tool.name for tool in json_response.result.tools]
                @test "get_time" in tool_names
                @test "reverse_text" in tool_names
                @test "calculate" in tool_names

            finally
                # Always stop server
                MCPRepl.stop_mcp_server(server)
                sleep(0.1)
            end
        end

        @testset "Tool Execution" begin
            # Start server for tool execution tests
            test_port = 3004
            server = MCPRepl.start_mcp_server(tools; mode=:http, port=test_port, verbose=false)

            # Give server time to start
            sleep(0.1)

            try
                # Test reverse_text tool
                request_body = JSON3.write(Dict(
                    "jsonrpc" => "2.0",
                    "id" => 2,
                    "method" => "tools/call",
                    "params" => Dict(
                        "name" => "reverse_text",
                        "arguments" => Dict("text" => "hello")
                    )
                ))

                response = HTTP.post(
                    "http://localhost:$test_port/",
                    ["Content-Type" => "application/json"],
                    request_body
                )

                @test response.status == 200

                # Parse response
                body = String(response.body)
                json_response = JSON3.read(body)

                @test json_response.jsonrpc == "2.0"
                @test json_response.id == 2
                @test haskey(json_response.result, "content")
                @test length(json_response.result.content) == 1
                @test json_response.result.content[1].type == "text"
                @test json_response.result.content[1].text == "olleh"

                # Test calculate tool
                request_body = JSON3.write(Dict(
                    "jsonrpc" => "2.0",
                    "id" => 3,
                    "method" => "tools/call",
                    "params" => Dict(
                        "name" => "calculate",
                        "arguments" => Dict("expression" => "2 + 3 * 4")
                    )
                ))

                response = HTTP.post(
                    "http://localhost:$test_port/",
                    ["Content-Type" => "application/json"],
                    request_body
                )

                @test response.status == 200

                # Parse response
                body = String(response.body)
                json_response = JSON3.read(body)

                @test json_response.result.content[1].text == "14"

            finally
                # Always stop server
                MCPRepl.stop_mcp_server(server)
                sleep(0.1)
            end
        end
    end

    @testset "Socket Mode Tests" begin
        # Create test tools for socket mode
        time_tool = MCPTool(
            "get_time",
            "Get current time in specified format",
            MCPRepl.text_parameter("format", "DateTime format string (e.g., 'yyyy-mm-dd HH:MM:SS')"),
            args -> Dates.format(now(), get(args, "format", "yyyy-mm-dd HH:MM:SS"))
        )

        reverse_tool = MCPTool(
            "reverse_text",
            "Reverse the input text",
            MCPRepl.text_parameter("text", "Text to reverse"),
            args -> reverse(get(args, "text", ""))
        )

        tools = [time_tool, reverse_tool]

        @testset "Socket Server Startup and Shutdown" begin
            test_dir = mktempdir()
            socket_path = joinpath(test_dir, ".mcp-repl.sock")

            try
                # Start socket server
                server = MCPRepl.start_mcp_server(tools; mode=:socket, socket_path=socket_path, verbose=false)

                @test server.handle isa MCPRepl.SocketServerHandle
                @test server.handle.socket_path == socket_path
                @test length(server.tools) == 2
                @test haskey(server.tools, "get_time")
                @test haskey(server.tools, "reverse_text")
                @test server.handle.running == true

                # Verify socket file exists
                @test ispath(socket_path)

                # Give server time to start
                sleep(0.1)

                # Stop server
                MCPRepl.stop_mcp_server(server)

                # Verify socket file is removed
                @test !ispath(socket_path)
                @test server.handle.running == false

                # Give server time to stop
                sleep(0.1)
            finally
                rm(test_dir; recursive=true, force=true)
            end
        end

        @testset "Socket Communication" begin
            test_dir = mktempdir()
            socket_path = joinpath(test_dir, ".mcp-repl.sock")

            try
                # Start socket server
                server = MCPRepl.start_mcp_server(tools; mode=:socket, socket_path=socket_path, verbose=false)
                sleep(0.1)

                # Connect to socket and send request
                client = connect(socket_path)

                try
                    # Test initialize request
                    init_request = Dict(
                        "jsonrpc" => "2.0",
                        "id" => 1,
                        "method" => "initialize"
                    )
                    println(client, JSON3.write(init_request))
                    response_line = readline(client)
                    response = JSON3.read(response_line, Dict{String,Any})

                    @test response["jsonrpc"] == "2.0"
                    @test response["id"] == 1
                    @test haskey(response, "result")
                    @test response["result"]["protocolVersion"] == "2024-11-05"

                    # Test tools/list request
                    list_request = Dict(
                        "jsonrpc" => "2.0",
                        "id" => 2,
                        "method" => "tools/list"
                    )
                    println(client, JSON3.write(list_request))
                    response_line = readline(client)
                    response = JSON3.read(response_line, Dict{String,Any})

                    @test response["id"] == 2
                    @test haskey(response["result"], "tools")
                    @test length(response["result"]["tools"]) == 2

                    # Test tool execution
                    call_request = Dict(
                        "jsonrpc" => "2.0",
                        "id" => 3,
                        "method" => "tools/call",
                        "params" => Dict(
                            "name" => "reverse_text",
                            "arguments" => Dict("text" => "hello")
                        )
                    )
                    println(client, JSON3.write(call_request))
                    response_line = readline(client)
                    response = JSON3.read(response_line, Dict{String,Any})

                    @test response["id"] == 3
                    @test response["result"]["content"][1]["text"] == "olleh"
                finally
                    close(client)
                end

                # Stop server
                MCPRepl.stop_mcp_server(server)
            finally
                rm(test_dir; recursive=true, force=true)
            end
        end

        @testset "PID File Management" begin
            test_dir = mktempdir()
            socket_path = joinpath(test_dir, ".mcp-repl.sock")
            pid_path = joinpath(test_dir, ".mcp-repl.pid")

            try
                # Start socket server
                server = MCPRepl.start_mcp_server(tools; mode=:socket, socket_path=socket_path, verbose=false)
                sleep(0.1)

                # Write PID file
                MCPRepl.write_pid_file(test_dir)

                # Verify PID file exists and contains current PID
                @test isfile(pid_path)
                pid_content = strip(read(pid_path, String))
                @test parse(Int, pid_content) == getpid()

                # Stop server and cleanup
                MCPRepl.stop_mcp_server(server)
                MCPRepl.remove_pid_file(test_dir)

                # Verify PID file is removed
                @test !isfile(pid_path)
            finally
                rm(test_dir; recursive=true, force=true)
            end
        end

        @testset "Stale Server Detection" begin
            test_dir = mktempdir()
            socket_path = joinpath(test_dir, ".mcp-repl.sock")
            pid_path = joinpath(test_dir, ".mcp-repl.pid")

            try
                # Create stale PID file with non-existent PID
                write(pid_path, "999999")

                # check_existing_server should detect stale server and clean up
                @test MCPRepl.check_existing_server(test_dir) == false
                @test !isfile(pid_path)

                # Create stale socket file without PID
                touch(socket_path)

                # check_existing_server should clean up orphaned socket
                @test MCPRepl.check_existing_server(test_dir) == false
                @test !ispath(socket_path)
            finally
                rm(test_dir; recursive=true, force=true)
            end
        end

        @testset "Duplicate Server Prevention" begin
            test_dir = mktempdir()
            socket_path = joinpath(test_dir, ".mcp-repl.sock")
            pid_path = joinpath(test_dir, ".mcp-repl.pid")

            try
                # Start first server
                server = MCPRepl.start_mcp_server(tools; mode=:socket, socket_path=socket_path, verbose=false)
                sleep(0.1)

                # Write PID file
                MCPRepl.write_pid_file(test_dir)

                # Verify server is detected as running
                @test MCPRepl.check_existing_server(test_dir) == true

                # Stop server
                MCPRepl.stop_mcp_server(server)
                MCPRepl.remove_pid_file(test_dir)
                MCPRepl.remove_socket_file(test_dir)
            finally
                rm(test_dir; recursive=true, force=true)
            end
        end

        @testset "Multiple Concurrent Connections" begin
            test_dir = mktempdir()
            socket_path = joinpath(test_dir, ".mcp-repl.sock")

            try
                # Start socket server
                server = MCPRepl.start_mcp_server(tools; mode=:socket, socket_path=socket_path, verbose=false)
                sleep(0.1)

                # Create multiple concurrent clients
                clients = []
                responses = []

                for i in 1:3
                    client = connect(socket_path)
                    push!(clients, client)

                    # Send request from each client
                    request = Dict(
                        "jsonrpc" => "2.0",
                        "id" => i,
                        "method" => "tools/call",
                        "params" => Dict(
                            "name" => "reverse_text",
                            "arguments" => Dict("text" => "test$i")
                        )
                    )
                    println(client, JSON3.write(request))
                end

                # Collect responses
                for (i, client) in enumerate(clients)
                    response_line = readline(client)
                    response = JSON3.read(response_line, Dict{String,Any})
                    push!(responses, response)
                    close(client)
                end

                # Verify all responses received correctly
                @test length(responses) == 3
                for (i, response) in enumerate(responses)
                    @test response["id"] == i
                    @test response["result"]["content"][1]["text"] == reverse("test$i")
                end

                # Stop server
                MCPRepl.stop_mcp_server(server)
            finally
                rm(test_dir; recursive=true, force=true)
            end
        end

        @testset "Socket Path Helpers" begin
            test_dir = mktempdir()

            try
                # Test get_socket_path
                socket_path = MCPRepl.get_socket_path(test_dir)
                @test socket_path == joinpath(test_dir, ".mcp-repl.sock")

                # Test get_pid_path
                pid_path = MCPRepl.get_pid_path(test_dir)
                @test pid_path == joinpath(test_dir, ".mcp-repl.pid")

                # Test remove_socket_file with non-existent file
                MCPRepl.remove_socket_file(test_dir)
                @test !ispath(socket_path)

                # Test remove_pid_file with non-existent file
                MCPRepl.remove_pid_file(test_dir)
                @test !isfile(pid_path)
            finally
                rm(test_dir; recursive=true, force=true)
            end
        end
    end

    @testset "Multiplexer Tests" begin
        @testset "Socket Path Discovery" begin
            # Test find_socket_path with socket in current directory
            test_dir = mktempdir()
            try
                socket_path = joinpath(test_dir, ".mcp-repl.sock")
                touch(socket_path)

                found_path = MCPRepl.MCPPlex.find_socket_path(test_dir)
                @test found_path == socket_path

                rm(socket_path)
            finally
                rm(test_dir; recursive=true, force=true)
            end
        end

        @testset "Socket Path Discovery - Parent Directory" begin
            # Test find_socket_path walking up directory tree
            test_root = mktempdir()
            try
                # Create nested directory structure
                subdir = joinpath(test_root, "subdir")
                mkdir(subdir)
                subsubdir = joinpath(subdir, "subsubdir")
                mkdir(subsubdir)

                # Place socket in root
                socket_path = joinpath(test_root, ".mcp-repl.sock")
                touch(socket_path)

                # Search from nested directory should find parent socket
                found_path = MCPRepl.MCPPlex.find_socket_path(subsubdir)
                @test found_path == socket_path

                rm(socket_path)
            finally
                rm(test_root; recursive=true, force=true)
            end
        end

        @testset "Socket Path Discovery - Not Found" begin
            test_dir = mktempdir()
            try
                # No socket file exists
                found_path = MCPRepl.MCPPlex.find_socket_path(test_dir)
                @test isnothing(found_path)
            finally
                rm(test_dir; recursive=true, force=true)
            end
        end

        @testset "Socket Path Caching" begin
            test_dir = mktempdir()
            try
                socket_path = joinpath(test_dir, ".mcp-repl.sock")
                touch(socket_path)

                # First call should populate cache
                found1 = MCPRepl.MCPPlex.find_socket_path(test_dir)
                @test found1 == socket_path

                # Remove socket file
                rm(socket_path)

                # Second call within TTL should return cached result
                found2 = MCPRepl.MCPPlex.find_socket_path(test_dir)
                @test found2 == socket_path

                # Clear cache by waiting past TTL (or we can manipulate cache directly)
                # For testing, we'll check that the cache exists
                @test haskey(MCPRepl.MCPPlex.SOCKET_CACHE, abspath(test_dir))
            finally
                # Clear this entry from cache
                delete!(MCPRepl.MCPPlex.SOCKET_CACHE, abspath(test_dir))
                rm(test_dir; recursive=true, force=true)
            end
        end

        @testset "Check Server Running" begin
            test_dir = mktempdir()
            try
                socket_path = joinpath(test_dir, ".mcp-repl.sock")
                pid_path = joinpath(test_dir, ".mcp-repl.pid")

                # No PID file
                @test !MCPRepl.MCPPlex.check_server_running(socket_path)

                # Invalid PID
                write(pid_path, "not_a_number")
                @test !MCPRepl.MCPPlex.check_server_running(socket_path)
                rm(pid_path)

                # Stale PID
                write(pid_path, "999999")
                @test !MCPRepl.MCPPlex.check_server_running(socket_path)
                rm(pid_path)

                # Valid PID (current process)
                write(pid_path, string(getpid()))
                @test MCPRepl.MCPPlex.check_server_running(socket_path)
                rm(pid_path)
            finally
                rm(test_dir; recursive=true, force=true)
            end
        end

        @testset "Multi-Project Forwarding" begin
            # Create two separate project directories with servers
            proj1_dir = mktempdir()
            proj2_dir = mktempdir()

            time_tool = MCPTool(
                "get_time",
                "Get current time",
                MCPRepl.text_parameter("format", "Format string"),
                args -> Dates.format(now(), get(args, "format", "yyyy-mm-dd HH:MM:SS"))
            )

            echo_tool = MCPTool(
                "echo",
                "Echo text",
                MCPRepl.text_parameter("text", "Text to echo"),
                args -> get(args, "text", "")
            )

            try
                # Start server in proj1
                socket1 = joinpath(proj1_dir, ".mcp-repl.sock")
                server1 = MCPRepl.start_mcp_server([time_tool]; mode=:socket, socket_path=socket1, verbose=false)
                MCPRepl.write_pid_file(proj1_dir)
                sleep(0.1)

                # Start server in proj2
                socket2 = joinpath(proj2_dir, ".mcp-repl.sock")
                server2 = MCPRepl.start_mcp_server([echo_tool]; mode=:socket, socket_path=socket2, verbose=false)
                MCPRepl.write_pid_file(proj2_dir)
                sleep(0.1)

                # Test forwarding to proj1
                result1 = MCPRepl.MCPPlex.forward_to_julia_server("get_time", proj1_dir, Dict{String,Any}("format" => "yyyy-mm-dd"), false)
                @test occursin(r"\d{4}-\d{2}-\d{2}", result1)

                # Test forwarding to proj2
                result2 = MCPRepl.MCPPlex.forward_to_julia_server("echo", proj2_dir, Dict{String,Any}("text" => "hello from proj2"), false)
                @test result2 == "hello from proj2"

                # Stop servers
                MCPRepl.stop_mcp_server(server1)
                MCPRepl.stop_mcp_server(server2)
                MCPRepl.remove_pid_file(proj1_dir)
                MCPRepl.remove_pid_file(proj2_dir)
            finally
                rm(proj1_dir; recursive=true, force=true)
                rm(proj2_dir; recursive=true, force=true)
            end
        end

        @testset "Multiplexer Error Handling" begin
            test_dir = mktempdir()

            try
                # Test with non-existent server
                result = MCPRepl.MCPPlex.forward_to_julia_server("some_tool", test_dir, Dict{String,Any}(), true)
                @test occursin("Error: MCP REPL server not found", result)
                @test occursin("Start the server with", result)

                # Test with stale server (socket exists but process dead)
                socket_path = joinpath(test_dir, ".mcp-repl.sock")
                pid_path = joinpath(test_dir, ".mcp-repl.pid")
                touch(socket_path)
                write(pid_path, "999999")

                # Clear cache so it finds the socket we just created
                delete!(MCPRepl.MCPPlex.SOCKET_CACHE, abspath(test_dir))

                result = MCPRepl.MCPPlex.forward_to_julia_server("some_tool", test_dir, Dict{String,Any}(), true)
                @test occursin("Error: MCP REPL server not running", result)

                rm(socket_path)
                rm(pid_path)
            finally
                delete!(MCPRepl.MCPPlex.SOCKET_CACHE, abspath(test_dir))
                rm(test_dir; recursive=true, force=true)
            end
        end

        @testset "Multiplexer Tool Handlers" begin
            test_dir = mktempdir()
            socket_path = joinpath(test_dir, ".mcp-repl.sock")

            echo_tool = MCPTool(
                "echo",
                "Echo text",
                MCPRepl.text_parameter("text", "Text to echo"),
                args -> get(args, "text", "")
            )

            try
                server = MCPRepl.start_mcp_server([echo_tool]; mode=:socket, socket_path=socket_path, verbose=false)
                MCPRepl.write_pid_file(test_dir)
                sleep(0.1)

                # Test handle_exec_repl (would need actual REPL tools)
                result = MCPRepl.MCPPlex.handle_exec_repl(Dict{String,Any}("project_dir" => "", "expression" => "2+2"))
                @test occursin("Error: project_dir parameter is required", result)

                result = MCPRepl.MCPPlex.handle_exec_repl(Dict{String,Any}("project_dir" => test_dir, "expression" => ""))
                @test occursin("Error: expression parameter is required", result)

                # Test handle_investigate_environment
                result = MCPRepl.MCPPlex.handle_investigate_environment(Dict{String,Any}())
                @test occursin("Error: project_dir parameter is required", result)

                # Test handle_usage_instructions
                result = MCPRepl.MCPPlex.handle_usage_instructions(Dict{String,Any}())
                @test occursin("Error: project_dir parameter is required", result)

                MCPRepl.stop_mcp_server(server)
                MCPRepl.remove_pid_file(test_dir)
            finally
                delete!(MCPRepl.MCPPlex.SOCKET_CACHE, abspath(test_dir))
                rm(test_dir; recursive=true, force=true)
            end
        end

        @testset "Multiplexer MCP Request Processing" begin
            # Test initialize
            request = Dict("jsonrpc" => "2.0", "id" => 1, "method" => "initialize")
            response = MCPRepl.MCPPlex.process_mcp_request(request)

            @test response["jsonrpc"] == "2.0"
            @test response["id"] == 1
            @test response["result"]["protocolVersion"] == "2024-11-05"
            @test response["result"]["serverInfo"]["name"] == "julia-mcp-adapter"

            # Test notifications/initialized (should return nothing)
            request = Dict("jsonrpc" => "2.0", "method" => "notifications/initialized")
            response = MCPRepl.MCPPlex.process_mcp_request(request)
            @test isnothing(response)

            # Test tools/list
            request = Dict("jsonrpc" => "2.0", "id" => 2, "method" => "tools/list")
            response = MCPRepl.MCPPlex.process_mcp_request(request)
            @test haskey(response["result"], "tools")
            @test length(response["result"]["tools"]) == 4
            tool_names = [t["name"] for t in response["result"]["tools"]]
            @test "exec_repl" in tool_names
            @test "investigate_environment" in tool_names
            @test "usage_instructions" in tool_names
            @test "remove-trailing-whitespace" in tool_names

            # Test invalid method
            request = Dict("jsonrpc" => "2.0", "id" => 3, "method" => "invalid/method")
            response = MCPRepl.MCPPlex.process_mcp_request(request)
            @test haskey(response, "error")
            @test response["error"]["code"] == -32601
        end

        @testset "Multiplexer Dict Type Safety" begin
            # Test tool call with missing params field (triggers default Dict())
            request = Dict{String,Any}(
                "jsonrpc" => "2.0",
                "id" => 1,
                "method" => "tools/call"
            )
            response = MCPRepl.MCPPlex.process_mcp_request(request)
            @test haskey(response, "error")
            @test response["error"]["code"] == -32602

            # Test tool call with missing arguments field (triggers default Dict())
            # Handler receives empty Dict{String,Any} and returns error message as text
            request = Dict{String,Any}(
                "jsonrpc" => "2.0",
                "id" => 2,
                "method" => "tools/call",
                "params" => Dict{String,Any}(
                    "name" => "exec_repl"
                )
            )
            response = MCPRepl.MCPPlex.process_mcp_request(request)
            @test haskey(response, "result")
            @test haskey(response["result"], "content")
            @test occursin("project_dir parameter is required", response["result"]["content"][1]["text"])

            # Test tool call with empty arguments (ensures Dict{String,Any} is used)
            request = Dict{String,Any}(
                "jsonrpc" => "2.0",
                "id" => 3,
                "method" => "tools/call",
                "params" => Dict{String,Any}(
                    "name" => "usage_instructions",
                    "arguments" => Dict{String,Any}()
                )
            )
            response = MCPRepl.MCPPlex.process_mcp_request(request)
            @test haskey(response, "result")
            @test haskey(response["result"], "content")
            @test occursin("project_dir parameter is required", response["result"]["content"][1]["text"])

            # Test handler functions directly with Dict{String,Any}
            result = MCPRepl.MCPPlex.handle_exec_repl(Dict{String,Any}())
            @test occursin("Error: project_dir parameter is required", result)

            result = MCPRepl.MCPPlex.handle_investigate_environment(Dict{String,Any}())
            @test occursin("Error: project_dir parameter is required", result)

            result = MCPRepl.MCPPlex.handle_usage_instructions(Dict{String,Any}())
            @test occursin("Error: project_dir parameter is required", result)

            result = MCPRepl.MCPPlex.handle_remove_trailing_whitespace(Dict{String,Any}())
            @test occursin("Error: project_dir parameter is required", result)
        end

        @testset "Socket Server Dict Type Safety" begin
            test_dir = mktempdir()
            socket_path = joinpath(test_dir, ".mcp-repl.sock")

            echo_tool = MCPTool(
                "echo",
                "Echo text",
                MCPRepl.text_parameter("text", "Text to echo"),
                args -> get(args, "text", "")
            )

            try
                server = MCPRepl.start_mcp_server([echo_tool]; mode=:socket, socket_path=socket_path, verbose=false)
                sleep(0.1)

                client = connect(socket_path)

                try
                    # Test tool call with missing params
                    request = Dict{String,Any}(
                        "jsonrpc" => "2.0",
                        "id" => 1,
                        "method" => "tools/call"
                    )
                    println(client, JSON3.write(request))
                    response_line = readline(client)
                    response = JSON3.read(response_line, Dict{String,Any})

                    @test haskey(response, "error")
                    @test response["error"]["code"] == -32602

                    # Test tool call with missing arguments
                    request = Dict{String,Any}(
                        "jsonrpc" => "2.0",
                        "id" => 2,
                        "method" => "tools/call",
                        "params" => Dict{String,Any}(
                            "name" => "echo"
                        )
                    )
                    println(client, JSON3.write(request))
                    response_line = readline(client)
                    response = JSON3.read(response_line, Dict{String,Any})

                    @test haskey(response, "result")
                    @test response["result"]["content"][1]["text"] == ""

                    # Test tool call with empty arguments
                    request = Dict{String,Any}(
                        "jsonrpc" => "2.0",
                        "id" => 3,
                        "method" => "tools/call",
                        "params" => Dict{String,Any}(
                            "name" => "echo",
                            "arguments" => Dict{String,Any}()
                        )
                    )
                    println(client, JSON3.write(request))
                    response_line = readline(client)
                    response = JSON3.read(response_line, Dict{String,Any})

                    @test haskey(response, "result")
                    @test response["result"]["content"][1]["text"] == ""
                finally
                    close(client)
                end

                MCPRepl.stop_mcp_server(server)
            finally
                rm(test_dir; recursive=true, force=true)
            end
        end
    end
end
