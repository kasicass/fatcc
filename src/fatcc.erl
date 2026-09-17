%% fatcc driver: command line handling, preprocessing, parsing, codegen.
-module(fatcc).
-include("fat_image.hrl").

-export([main/1, compile/2]).

-define(VERSION, "0.1.0").

-record(opts, {
    out = undefined       :: undefined | string(),
    includes = []         :: [string()],
    defines = []          :: [{string(), string()}],
    files = []            :: [string()],
    preprocess_only = false :: boolean(),
    emit_asm = false      :: boolean(),
    debug = false         :: boolean(),
    compile_only = false  :: boolean(),
    opt = 0               :: non_neg_integer()
}).

%%====================================================================
%% CLI
%%====================================================================
main(Args) ->
    try
        do_main(Args)
    catch
        throw:{fatal, Code, Msg} ->
            io:format(standard_error, "fatcc: ~s~n", [Msg]),
            erlang:halt(Code);
        ErrClass:ErrReason:ErrStack ->
            io:format(standard_error, "fatcc: internal error: ~p:~p~n~p~n",
                      [ErrClass, ErrReason, ErrStack]),
            erlang:halt(70)
    end.

do_main(Args) ->
    Opts = parse_args(Args, #opts{}),
    case Opts#opts.files of
        [] -> throw({fatal, 2, "no input files"});
        Files -> compile(Files, Opts)
    end.

compile(Files, Opts) ->
    IncludeDirs = default_include_dirs() ++ Opts#opts.includes,
    PPOpts = #{include_dirs => IncludeDirs, defines => Opts#opts.defines},
    case Opts#opts.preprocess_only of
        true ->
            lists:foreach(fun(F) -> preprocess_only(F, PPOpts) end, Files),
            erlang:halt(0);
        false ->
            Images = [file_image(F, Opts, PPOpts) || F <- Files],
            case Opts#opts.compile_only of
                true ->
                    write_objects(Files, Images, Opts),
                    erlang:halt(0);
                false ->
                    {ok, Image} = fatcc_link:link(Images),
                    case Opts#opts.emit_asm of
                        true -> print_asm(Image), erlang:halt(0);
                        false ->
                            Out = out_name(Opts, Files),
                            ok = file:write_file(Out, fat_format:encode(Image)),
                            io:format("fatcc: wrote ~s~n", [Out]),
                            erlang:halt(0)
                    end
            end
    end.

file_image(F, Opts, PPOpts) ->
    case filename:extension(F) of
        ".fo" ->
            case file:read_file(F) of
                {ok, Bin} ->
                    case fat_format:decode(Bin) of
                        {ok, Image} -> Image;
                        {error, Reason} ->
                            throw({fatal, 1, io_lib:format("cannot read ~s: ~p", [F, Reason])})
                    end;
                {error, Reason} ->
                    throw({fatal, 1, io_lib:format("cannot read ~s: ~p", [F, Reason])})
            end;
        _ ->
            Items = compile_file(F, PPOpts),
            {ok, Image} = fatcc_gen:gen(Items, #{opt_level => Opts#opts.opt}),
            Image
    end.

write_objects(Files, Images, Opts) ->
    case {Files, Opts#opts.out} of
        {[_], Out} when Out =/= undefined ->
            [Img] = Images,
            ok = file:write_file(Out, fat_format:encode(Img)),
            io:format("fatcc: wrote ~s~n", [Out]);
        _ ->
            lists:foreach(
              fun({F, Img}) ->
                  Out = filename:rootname(F) ++ ".fo",
                  ok = file:write_file(Out, fat_format:encode(Img)),
                  io:format("fatcc: wrote ~s~n", [Out])
              end, lists:zip(Files, Images))
    end.

compile_file(File, PPOpts) ->
    case fatcc_pp:process(File, PPOpts) of
        {ok, Toks} ->
            case fatcc_parse:parse(Toks) of
                {ok, Items} -> Items;
                {error, Diags} -> report_errors(File, Diags)
            end;
        {error, Diags} ->
            report_errors(File, Diags)
    end.

preprocess_only(File, PPOpts) ->
    case fatcc_pp:process(File, PPOpts) of
        {ok, Toks} -> io:put_chars(render_tokens(Toks));
        {error, Diags} -> report_errors(File, Diags)
    end.

report_errors(File, Diags) ->
    lists:foreach(
      fun({Loc, Msg}) ->
          {L, C} = case Loc of
                       {Line, Col} -> {Line, Col};
                       Line when is_integer(Line) -> {Line, 1};
                       _ -> {0, 0}
                   end,
          io:format(standard_error, "~s:~w:~w: error: ~s~n", [File, L, C, Msg])
      end, Diags),
    erlang:halt(1).

render_tokens(Toks) ->
    [render_token(T) || T <- Toks, element(1, T) =/= eof].

render_token({kw, K, _}) -> atom_to_list(K) ++ " ";
render_token({id, N, _}) -> N ++ " ";
render_token({int, V, _}) -> integer_to_list(V) ++ " ";
render_token({float, F, _}) -> io_lib:format("~p ", [F]);
render_token({char, V, _}) -> integer_to_list(V) ++ " ";
render_token({str, B, _}) -> io_lib:format("~p ", [B]);
render_token({punct, P, _}) -> atom_to_list(P) ++ " ".

print_asm(#image{funcs = Funcs}) ->
    maps:foreach(
      fun(Name, #func{} = F) ->
          io:format("func ~s (ret ~s, frame ~w)~n",
                    [Name, fatcc_type:describe(F#func.ret_type), F#func.frame_size]),
          lists:foreach(fun(L) -> io:format("  ~s~n", [L]) end,
                        fatcc_asm:disassemble(F#func.code)),
          io:format("~n")
      end, Funcs).

out_name(#opts{out = undefined}, [First | _]) ->
    filename:rootname(First) ++ ".fc";
out_name(#opts{out = Out}, _) -> Out.

%%====================================================================
%% Argument parsing
%%====================================================================
parse_args([], Opts) -> Opts;
parse_args(["--version" | _], _) ->
    io:format("fatcc ~s~n", [?VERSION]), erlang:halt(0);
parse_args(["-v" | _], _) ->
    io:format("fatcc ~s~n", [?VERSION]), erlang:halt(0);
parse_args(["--help" | _], _) ->
    usage(), erlang:halt(0);
parse_args(["-h" | _], _) ->
    usage(), erlang:halt(0);
parse_args(["-o", Out | R], Opts) -> parse_args(R, Opts#opts{out = Out});
parse_args(["-I", Dir | R], Opts) -> parse_args(R, Opts#opts{includes = Opts#opts.includes ++ [Dir]});
parse_args(["-D", Def | R], Opts) ->
    parse_args(R, Opts#opts{defines = Opts#opts.defines ++ [split_define(Def)]});
parse_args(["-E" | R], Opts) -> parse_args(R, Opts#opts{preprocess_only = true});
parse_args(["-c" | R], Opts) -> parse_args(R, Opts#opts{compile_only = true});
parse_args(["-S" | R], Opts) -> parse_args(R, Opts#opts{emit_asm = true});
parse_args(["-g" | R], Opts) -> parse_args(R, Opts#opts{debug = true});
parse_args(["-O0" | R], Opts) -> parse_args(R, Opts#opts{opt = 0});
parse_args(["-O1" | R], Opts) -> parse_args(R, Opts#opts{opt = 1});
parse_args(["-O2" | R], Opts) -> parse_args(R, Opts#opts{opt = 2});
parse_args(["-O" | R], Opts) -> parse_args(R, Opts#opts{opt = 1});
parse_args(["-O" ++ _ | R], Opts) -> parse_args(R, Opts);
parse_args(["-W" ++ _ | R], Opts) -> parse_args(R, Opts);
parse_args(["-std=" ++ _ | R], Opts) -> parse_args(R, Opts);
parse_args(["-I" ++ Dir | R], Opts) -> parse_args(R, Opts#opts{includes = Opts#opts.includes ++ [Dir]});
parse_args(["-D" ++ Def | R], Opts) ->
    parse_args(R, Opts#opts{defines = Opts#opts.defines ++ [split_define(Def)]});
parse_args(["-" ++ _ = Flag | _], _) ->
    throw({fatal, 2, "unknown option: " ++ Flag});
parse_args([F | R], Opts) ->
    parse_args(R, Opts#opts{files = Opts#opts.files ++ [F]}).

split_define(Def) ->
    case string:split(Def, "=", leading) of
        [Name, Value] -> {Name, Value};
        [Name] -> {Name, "1"}
    end.

default_include_dirs() ->
    Extra = case os:getenv("FATCC_INCLUDE") of
                false -> [];
                "" -> [];
                S -> string:split(S, ":", all)
            end,
    Bundled =
        case code:which(?MODULE) of
            non_existing -> [];
            P ->
                Dir = filename:join([filename:dirname(P), "..", "priv", "include"]),
                case filelib:is_dir(Dir) of
                    true -> [Dir];
                    false -> []
                end
        end,
    Bundled ++ Extra.

usage() ->
    io:format(
      "usage: fatcc [options] file.c ...~n"
      "  -o <file>        write output to <file>~n"
      "  -I <dir>         add include search directory~n"
      "  -D<name>[=val]   predefine macro~n"
      "  -c               compile to .fo object~n"
      "  -E               preprocess only~n"
      "  -S               emit assembly listing~n"
      "  -g               emit debug info~n"
      "  --version        print version~n"
      "  --help           print this help~n").
