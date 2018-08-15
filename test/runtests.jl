using Rebugger
using Rebugger: StopException
using Test, UUIDs, InteractiveUtils
using Revise

if !isdefined(Main, :RebuggerTesting)
    includet("testmodule.jl")   # so the source code here gets loaded
end

const empty_kwvarargs = Rebugger.kwstasher()
uuidextractor(str) = UUID(match(r"getstored\(\"([a-z0-9\-]+)\"\)", str).captures[1])

struct ErrorsOnShow end
Base.show(io::IO, ::ErrorsOnShow) = throw(ArgumentError("no show"))

@testset "Rebugger" begin
    id = uuid1()
    @test uuidextractor("vars = getstored(\"$id\") and more stuff") == id
    @testset "Debug core" begin
        @testset "Deepcopy" begin
            args = (3.2, rand(3,3), Rebugger, [Rebugger], "hello", sum, (2,3))
            argc = Rebugger.safe_deepcopy(args...)
            @test argc == args
        end
        @testset "Caller buffer capture and insertion" begin
            function run_insertion(str, atstr)
                RebuggerTesting.cbdata1[] = RebuggerTesting.cbdata2[] = Rebugger.stashed[] = nothing
                io = IOBuffer()
                idx = findfirst(atstr, str)
                print(io, str)
                seek(io, first(idx)-1)
                callexpr = Rebugger.prepare_caller_capture!(io)
                capstring = String(take!(io))
                capexpr   = Meta.parse(capstring)
                try
                    Core.eval(RebuggerTesting, capexpr)
                catch err
                    isa(err, StopException) || rethrow(err)
                end
            end

            str = """
            for i = 1:5
                cbdata1[] = i
                foo(12, 13; akw="modified")
                cbdata2[] = i
            end
            """
            @test run_insertion(str, "foo")
            @test RebuggerTesting.cbdata1[] == 1
            @test RebuggerTesting.cbdata2[] == nothing
            @test Rebugger.stashed[] == (RebuggerTesting.foo, (12, 13), Rebugger.kwstasher(;akw="modified"))
            str = """
            for i = 1:5
                error("not caught")
                foo(12, 13; akw="modified")
            end
            """
            @test_throws ErrorException("not caught") run_insertion(str, "foo")
            @test_throws Rebugger.StepException("Rebugger can only step into expressions, got 77") run_insertion("x = 77", "77")

            # Module-scoped calls
            io = IOBuffer()
            cmdstr = "Scope.func(x, y, z)"
            print(io, cmdstr)
            seek(io, 0)
            callexpr = Rebugger.prepare_caller_capture!(io)
            @test callexpr == :(Scope.func(x, y, z))
            take!(io)

            # getindex and setindex! expressions
            cmdstr = "x = a[2,3]"
            print(io, cmdstr)
            seek(io, first(findfirst("a", cmdstr))-1)
            callexpr = Rebugger.prepare_caller_capture!(io)
            @test callexpr == :(getindex(a, 2, 3))
            take!(io)

            cmdstr = "a[2,3] = x"
            print(io, cmdstr)
            seek(io, 0)
            callexpr = Rebugger.prepare_caller_capture!(io)
            @test callexpr == :(setindex!(a, x, 2, 3))
            take!(io)

            # Expressions that go beyond "user intention".
            # More generally we should support marking, but in the case of && and || it's
            # handled by lowering, so there is nothing to step into anyway.
            for cmdstr in ("f1(x) && f2(z)", "f1(x) || f2(z)")
                print(io, cmdstr)
                seek(io, 0)
                callexpr = Rebugger.prepare_caller_capture!(io)
                @test callexpr == :(f1(x))
                take!(io)
            end

            # issue #5
            cmdstr = "abs(abs(x))"
            print(io, cmdstr)
            seek(io, 4)
            callexpr = Rebugger.prepare_caller_capture!(io)
            @test callexpr == :(abs(x))
            take!(io)

            # splat expressions
            cmdstr = "foo(bar(x)..., 1)"
            print(io, cmdstr)
            idx = findfirst("bar", cmdstr)
            seek(io, first(idx)-1)
            callexpr = Rebugger.prepare_caller_capture!(io)
            @test callexpr == :(bar(x))
        end

        @testset "Callee variable capture" begin
            def = quote
                function complexargs(x::A, y=1, str="1.0"; kw1=Float64, kw2=7, kwargs...) where A<:AbstractArray{T} where T
                    return (x .+ y, parse(kw1, str), kw2)
                end
            end
            f = Core.eval(RebuggerTesting, def)
            @test f([8,9]) == ([9,10], 1.0, 7)
            m = collect(methods(f))[end]
            uuid = Rebugger.method_capture_from_callee(m, def)
            @test  Rebugger.method_capture_from_callee(m, def) == uuid  # calling twice returns the previously-defined objects
            fc = Rebugger.storefunc[uuid]
            @test_throws StopException fc([8,9], 2, "13"; kw1=Int, kw2=0)
            @test Rebugger.stored[uuid].varnames == (:x, :y, :str, :kw1, :kw2, :kwargs, :A, :T)
            @test Rebugger.stored[uuid].varvals  == ([8,9], 2, "13", Int, 0, empty_kwvarargs, Vector{Int}, Int)
            @test_throws StopException fc([8,9]; otherkw=77)
            @test Rebugger.stored[uuid].varnames == (:x, :y, :str, :kw1, :kw2, :kwargs, :A, :T)
            @test Rebugger.stored[uuid].varvals  == ([8,9], 1, "1.0", Float64, 7, pairs((otherkw=77,)), Vector{Int}, Int)

            uuid2 = Rebugger.method_capture_from_callee(m, def; overwrite=true)
            @test uuid2 != uuid
            fc = Rebugger.storefunc[uuid2]
            @test fc([8,9], 2, "13"; kw1=Int, kw2=0) == ([10,11], 13, 0)
            Core.eval(RebuggerTesting, def)
            @test Rebugger.stored[uuid2].varnames == (:x, :y, :str, :kw1, :kw2, :kwargs, :A, :T)
            @test Rebugger.stored[uuid2].varvals  == ([8,9], 2, "13", Int, 0, empty_kwvarargs, Vector{Int}, Int)

            def = quote
                modifies!(x) = (x[1] += 1; x)
            end
            f = Core.eval(RebuggerTesting, def)
            @test f([8,9]) == [9,9]
            m = collect(methods(f))[end]
            uuid = Rebugger.method_capture_from_callee(m, def)
            fc = Rebugger.storefunc[uuid]
            @test_throws StopException fc([8,9])
            @test Rebugger.stored[uuid].varnames == (:x,)
            @test Rebugger.stored[uuid].varvals  == ([8,9],)

            # Extensions of functions from other modules
            m = @which RebuggerTesting.foo()
            uuid = Rebugger.method_capture_from_callee(m)
            fc = Rebugger.storefunc[uuid]
            @test_throws StopException fc()
            @test Rebugger.stored[uuid].varnames == Rebugger.stored[uuid].varvals == ()
        end

        @testset "Step in" begin
            function run_stepin(str, atstr)
                io = IOBuffer()
                idx = findfirst(atstr, str)
                @test !isempty(idx)
                print(io, str)
                seek(io, first(idx)-1)
                Rebugger.stepin(io)
            end

            str = "RebuggerTesting.snoop0()"
            uuidref, cmd = run_stepin(str, str)
            uuid1 = uuidextractor(cmd)
            @test uuid1 == uuidref
            @test cmd == """
            @eval Main.RebuggerTesting let () = Main.Rebugger.getstored("$uuid1")
            begin
                snoop1("Spy")
            end
            end"""
            _, cmd = run_stepin(cmd, "snoop1")
            uuid2 = uuidextractor(cmd)
            @test cmd == """
            @eval Main.RebuggerTesting let (word,) = Main.Rebugger.getstored("$uuid2")
            begin
                snoop2(word, "on")
            end
            end"""
            _, cmd = run_stepin(cmd, "snoop2")
            uuid3 = uuidextractor(cmd)
            @test cmd == """
            @eval Main.RebuggerTesting let (word1, word2) = Main.Rebugger.getstored("$uuid3")
            begin
                snoop3(word1, word2, "arguments")
            end
            end"""
            @test Rebugger.getstored(string(uuid1)) == ()
            @test Rebugger.getstored(string(uuid2)) == ("Spy",)
            @test Rebugger.getstored(string(uuid3)) == ("Spy", "on")

            str = "RebuggerTesting.kwvarargs(1)"
            _, cmd = run_stepin(str, str)
            uuid = uuidextractor(cmd)
            @test cmd == """
            @eval Main.RebuggerTesting let (x, kw1, kwargs) = Main.Rebugger.getstored("$uuid")
            begin
                kwvarargs2(x; kw1=kw1, kwargs...)
            end
            end"""
            @test Rebugger.getstored(string(uuid)) == (1, 1, empty_kwvarargs)
            cmd = run_stepin(cmd, "kwvarargs2")

            str = "RebuggerTesting.kwvarargs(1; passthrough=false)"
            _, cmd = run_stepin(str, str)
            uuid = uuidextractor(cmd)
            @test cmd == """
            @eval Main.RebuggerTesting let (x, kw1, kwargs) = Main.Rebugger.getstored("$uuid")
            begin
                kwvarargs2(x; kw1=kw1, kwargs...)
            end
            end"""
            @test Rebugger.getstored(string(uuid)) == (1, 1, pairs((passthrough=false,)))
            _, cmd = run_stepin(cmd, "kwvarargs2")

            # Step in to call-overloading methods
            str = "RebuggerTesting.hv_test(\"hi\")"
            _, cmd = run_stepin(str, str)
            uuid = uuidextractor(cmd)
            @test cmd == """
            @eval Main.RebuggerTesting let (hv, str) = Main.Rebugger.getstored("$uuid")
            begin
                hv.x
            end
            end"""
            @test Rebugger.getstored(string(uuid)) == (RebuggerTesting.hv_test, "hi")

            # Step in to methods that do tuple-destructuring of arguments
            str = "RebuggerTesting.destruct(1, (2,3), 4)"
            @test eval(Meta.parse(str)) == 2
            _, cmd = run_stepin(str, str)
            uuid = uuidextractor(cmd)
            @test cmd == """
            @eval Main.RebuggerTesting let (x, (a, b), y) = Main.Rebugger.getstored("$uuid")
            begin
                a
            end
            end"""
            @test Rebugger.getstored(string(uuid)) == (1, (2,3), 4)

            # Step in to a broadcast call
            str = "sum.([[1,2], (3,5)])"
            uuid, cmd = run_stepin(str, str)
            s = Rebugger.stored[uuid]
            @test s.method.name == :broadcast
            @test cmd == """
            @eval Base.Broadcast let (f, As, Tf) = Main.Rebugger.getstored("$uuid")
            begin
                materialize(broadcasted(f, As...))
            end
            end"""
            @test Rebugger.getstored(string(uuid)) == (sum, (Any[[1,2], (3,5)],), typeof(sum))
            Core.eval(Main, Meta.parse(cmd)) == [3,8]

            str = "max.([1,5], [2,-3])"
            uuid, cmd = run_stepin(str, str)
            s = Rebugger.stored[uuid]
            @test s.method.name == :broadcast
            @test cmd == """
            @eval Base.Broadcast let (f, As, Tf) = Main.Rebugger.getstored("$uuid")
            begin
                materialize(broadcasted(f, As...))
            end
            end"""
            @test Rebugger.getstored(string(uuid)) == (max, ([1,5], [2,-3]), typeof(max))
            Core.eval(Main, Meta.parse(cmd)) == [2,5]
        end

        @testset "Capture stacktrace" begin
            uuids = nothing
            mktemp() do path, iostacktrace
                redirect_stderr(iostacktrace) do
                    uuids = Rebugger.capture_stacktrace(RebuggerTesting, :(snoop0()))
                end
                flush(iostacktrace)
                str = read(path, String)
                @test occursin("snoop3", str)
            end
            @test Rebugger.stored[uuids[1]].varvals == ()
            @test Rebugger.stored[uuids[2]].varvals == ("Spy",)
            @test Rebugger.stored[uuids[3]].varvals == ("Spy", "on")
            @test Rebugger.stored[uuids[4]].varvals == ("Spy", "on", "arguments", "simply", empty_kwvarargs, String)
            @test_throws ErrorException("oops") RebuggerTesting.snoop0()
        end
    end

    @testset "User interface" begin
        @testset "Printing header" begin
            h = Rebugger.RebugHeader()
            h.uuid = uuid = uuid1()
            meth = @which RebuggerTesting.foo(1,2)
            h.current_method = meth
            Rebugger.stored[uuid] = Rebugger.Stored(meth, (:x, :y), (1, ErrorsOnShow()))
            h.warnmsg = "This is a warning"
            h.errmsg  = "You will not have a second chance"
            io = IOBuffer()
            Rebugger.print_header(io, h)
            str = String(take!(io))
            @test startswith(str, """
            This is a warning
            You will not have a second chance
            foo(x, y) in Main.RebuggerTesting at """) # skip the "upper" part of the file location
            @test endswith(str, "testmodule.jl:7\n  x = 1\n  y errors in its show method")
        end
    end
end

# TODO when I figure out how to test the REPL ui
# Try stepping in to Plots.histogram(randn(1000))    # issue #3, Plots is listed as the module but the file is in RecipesBase
# Try the same except position point at the beginning of histogram rather than Plots (or really any partial expression)
