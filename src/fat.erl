%% fat: command-line runtime for .fc bytecode images.
-module(fat).
-include("fat_image.hrl").

-export([main/1]).

-define(VERSION, "0.1.0").

main(Args) ->
    try
        {Opts, File, ProgArgs} = parse_args(Args, #{}, undefined, []),
        case File of
            undefined ->
                usage(),
                erlang:halt(2);
            _ ->
                case maps:get(dump, Opts, false) of
                    true -> dump(File), erlang:halt(0);
                    false -> ok
                end,
                ProgArgv = [File | ProgArgs],
                case fat_loader:start(File, ProgArgv, Opts) of
                    Code when is_integer(Code) ->
                        erlang:halt(Code);
                    {error, {runtime, Reason, Vm}} ->
                        print_runtime_error(Reason, Vm),
                        erlang:halt(1);
                    {error, Reason} ->
                        io:format(standard_error, "fat: ~p~n", [Reason]),
                        erlang:halt(1)
                end
        end
    catch
        ErrClass:ErrReason:ErrStack ->
            io:format(standard_error, "fat: internal error: ~p:~p~n~p~n",
                      [ErrClass, ErrReason, ErrStack]),
            erlang:halt(70)
    end.

print_runtime_error(Reason, Vm) ->
    io:format(standard_error, "runtime error: ~s~n", [describe_fault(Reason)]),
    print_stack(Vm#vm.frames).

print_stack(Frames) ->
    lists:foreach(
      fun(#frame{name = Name, ret_pc = Pc}) ->
          io:format(standard_error, "  at ~s (pc ~w)~n", [Name, Pc])
      end, Frames).

describe_fault({undefined_symbol, N}) -> "undefined symbol: " ++ N;
describe_fault({bad_instruction, I}) -> lists:flatten(io_lib:format("bad instruction: ~p", [I]));
describe_fault(step_limit_exceeded) -> "step limit exceeded";
describe_fault(division_by_zero) -> "division by zero";
describe_fault(Other) -> lists:flatten(io_lib:format("~p", [Other])).

dump(File) ->
    case fat_loader:load(File) of
        {ok, #image{} = Image} ->
            io:format("== image ==~nentry: ~s~nfunctions:~n", [Image#image.entry]),
            maps:foreach(
              fun(Name, F) ->
                  io:format("  ~s (ret ~s, frame ~w, params ~w)~n",
                            [Name, fatcc_type:describe(F#func.ret_type),
                             F#func.frame_size, length(F#func.params)])
              end, Image#image.funcs),
            io:format("globals: ~p~nstrings: ~w~n",
                      [maps:keys(Image#image.globals), length(Image#image.strings)]);
        {error, Reason} ->
            io:format(standard_error, "fat: cannot load ~s: ~p~n", [File, Reason]),
            erlang:halt(1)
    end.

%%====================================================================
%% CLI
%%====================================================================
parse_args([], Opts, File, Acc) -> {Opts, File, lists:reverse(Acc)};
parse_args(["--version" | _], _, _, _) ->
    io:format("fat ~s~n", [?VERSION]), erlang:halt(0);
parse_args(["-v" | _], _, _, _) ->
    io:format("fat ~s~n", [?VERSION]), erlang:halt(0);
parse_args(["--help" | _], _, _, _) ->
    usage(), erlang:halt(0);
parse_args(["-h" | _], _, _, _) ->
    usage(), erlang:halt(0);
parse_args(["--trace" | R], Opts, File, Acc) ->
    parse_args(R, maps:put(trace, true, Opts), File, Acc);
parse_args(["--dump" | R], Opts, File, Acc) ->
    parse_args(R, maps:put(dump, true, Opts), File, Acc);
parse_args(["--max-steps", N | R], Opts, File, Acc) ->
    parse_args(R, maps:put(max_steps, list_to_integer(N), Opts), File, Acc);
parse_args(["--max-steps=" ++ N | R], Opts, File, Acc) ->
    parse_args(R, maps:put(max_steps, list_to_integer(N), Opts), File, Acc);
parse_args(["--heap-size", N | R], Opts, File, Acc) ->
    parse_args(R, maps:put(heap_size, list_to_integer(N), Opts), File, Acc);
parse_args(["--heap-size=" ++ N | R], Opts, File, Acc) ->
    parse_args(R, maps:put(heap_size, list_to_integer(N), Opts), File, Acc);
parse_args(["--no-verify" | R], Opts, File, Acc) ->
    parse_args(R, maps:put(verify, false, Opts), File, Acc);
parse_args(["--" | R], Opts, File, Acc) ->
    {Opts, File, lists:reverse(Acc) ++ R};
parse_args(["-" ++ _ = Flag | _], _, _, _) ->
    io:format(standard_error, "fat: unknown option: ~s~n", [Flag]),
    erlang:halt(2);
parse_args([F | R], Opts, undefined, Acc) ->
    parse_args(R, Opts, F, Acc);
parse_args([A | R], Opts, File, Acc) ->
    parse_args(R, Opts, File, [A | Acc]).

usage() ->
    io:format(
      "usage: fat [options] prog.fc [program args...]~n"
      "  --trace            trace instructions~n"
      "  --max-steps N      instruction budget~n"
      "  --heap-size N      heap limit in bytes~n"
      "  --no-verify        skip bytecode verification~n"
      "  --dump             dump the loaded image~n"
      "  --version          print version~n"
      "  --help             print this help~n").
