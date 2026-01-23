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

            @test server.mode == :http
            @test server.port == test_port
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

                @test server.mode == :socket
                @test server.socket_path == socket_path
                @test length(server.tools) == 2
                @test haskey(server.tools, "get_time")
                @test haskey(server.tools, "reverse_text")
                @test server.running == true

                # Verify socket file exists
                @test ispath(socket_path)

                # Give server time to start
                sleep(0.1)

                # Stop server
                MCPRepl.stop_mcp_server(server)

                # Verify socket file is removed
                @test !ispath(socket_path)
                @test server.running == false

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
end
