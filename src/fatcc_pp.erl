%% C preprocessor: line splicing, comment stripping, #include, object-like and
%% function-like #define, conditional compilation (#if/#ifdef/#ifndef/#else/
%% #elif/#endif), and token-level macro expansion.
%%
%% Operates line-by-line so directives and macros thread correctly through
%% nested includes.
-module(fatcc_pp).

-export([process/2, process_text/2]).

-record(pp, {
    macros = #{}        :: map(),
    dirs = []           :: [string()],
    seen = #{}          :: map(),
    curdir = "."        :: string(),
    depth = 0           :: non_neg_integer(),
    conds = []          :: list()
}).

-define(MAX_DEPTH, 200).

%%====================================================================
%% API
%%====================================================================
-spec process(string(), map()) -> {ok, [fatcc_lex:token()]} | {error, list()}.
process(File, Opts) ->
    Dirs = maps:get(include_dirs, Opts, []),
    St = #pp{dirs = Dirs, macros = seed_macros(Opts)},
    try
        {Toks, _St2} = process_file(File, St, []),
        {ok, Toks}
    catch
        throw:{pp_error, Loc, Msg} ->
            {error, [{Loc, lists:flatten(Msg)}]}
    end.

-spec process_text(binary() | string(), map()) -> {ok, [fatcc_lex:token()]} | {error, list()}.
process_text(Text, Opts) when is_list(Text) ->
    process_text(unicode:characters_to_binary(Text), Opts);
process_text(Bin, Opts) when is_binary(Bin) ->
    St = #pp{dirs = maps:get(include_dirs, Opts, []), macros = seed_macros(Opts)},
    try
        {Lines, _} = to_lines(Bin),
        {Toks, _} = pp_lines(Lines, 1, St, []),
        {ok, Toks}
    catch
        throw:{pp_error, Loc, Msg} -> {error, [{Loc, lists:flatten(Msg)}]}
    end.

%%====================================================================
%% File handling
%%====================================================================
process_file(File, St, Extra) ->
    Abs = filename:absname(File),
    case maps:get(Abs, St#pp.seen, false) of
        true -> {Extra, St};
        false ->
            case file:read_file(File) of
                {ok, Bin} ->
                    St1 = St#pp{seen = maps:put(Abs, true, St#pp.seen),
                                curdir = filename:dirname(Abs),
                                depth = St#pp.depth + 1},
                    check_depth(St1),
                    {Lines, StartLine} = to_lines(Bin),
                    {Toks, St2} = pp_lines(Lines, StartLine, St1, Extra),
                    {Toks, St2#pp{depth = St#pp.depth}};
                {error, Reason} ->
                    throw({pp_error, {1, 1},
                           io_lib:format("cannot read ~s: ~p", [File, Reason])})
            end
    end.

check_depth(#pp{depth = D}) when D > ?MAX_DEPTH ->
    throw({pp_error, {1, 1}, "include nesting too deep"});
check_depth(_) -> ok.

%%====================================================================
%% Seeded / predefined macros
%%====================================================================
seed_macros(Opts) ->
    Base = [{"__STDC__", "1"},
            {"__STDC_HOSTED__", "1"},
            {"__STDC_VERSION__", "201112L"}],
    Defs = maps:get(defines, Opts, []),
    lists:foldl(
      fun({Name, Value}, Acc) ->
          maps:put(Name, {obj, scan_body(Value)}, Acc)
      end, seed_base(Base), Defs).

seed_base([]) -> #{};
seed_base([{N, V} | R]) -> maps:put(N, {obj, scan_body(V)}, seed_base(R)).

to_lines(Bin0) ->
    Bin = splice(Bin0),
    List = strip_comments(binary_to_list(Bin)),
    {string:split(List, "\n", all), 1}.

splice(Bin) -> list_to_binary(splice_l(binary_to_list(Bin))).
splice_l([$\\, $\n | R]) -> splice_l(R);
splice_l([$\\, $\r, $\n | R]) -> splice_l(R);
splice_l([C | R]) -> [C | splice_l(R)];
splice_l([]) -> [].

strip_comments(List) -> lists:reverse(strip(List, normal, [])).

strip([], _S, Acc) -> Acc;
strip([$/,$/ | R], normal, Acc) -> strip(R, line_comment, Acc);
strip([$/,$* | R], normal, Acc) -> strip(R, block_comment, Acc);
strip([$" | R], normal, Acc) -> strip(R, string, [$" | Acc]);
strip([$' | R], normal, Acc) -> strip(R, char, [$' | Acc]);
strip([C | R], normal, Acc) -> strip(R, normal, [C | Acc]);
strip([$\n | R], line_comment, Acc) -> strip(R, normal, [$\n | Acc]);
strip([_ | R], line_comment, Acc) -> strip(R, line_comment, Acc);
strip([$*,$/ | R], block_comment, Acc) -> strip(R, normal, Acc);
strip([$\n | R], block_comment, Acc) -> strip(R, block_comment, [$\n | Acc]);
strip([_ | R], block_comment, Acc) -> strip(R, block_comment, Acc);
strip([$\\, C | R], string, Acc) -> strip(R, string, [C, $\\ | Acc]);
strip([$" | R], string, Acc) -> strip(R, normal, [$" | Acc]);
strip([C | R], string, Acc) -> strip(R, string, [C | Acc]);
strip([$\\, C | R], char, Acc) -> strip(R, char, [C, $\\ | Acc]);
strip([$' | R], char, Acc) -> strip(R, normal, [$' | Acc]);
strip([C | R], char, Acc) -> strip(R, char, [C | Acc]).

%%====================================================================
%% Line processing
%%====================================================================
pp_lines([], _N, St, Acc) ->
    {lists:reverse(Acc), St};
pp_lines([Line | Rest], N, St, Acc) ->
    Active = current_active(St),
    case directive(Line) of
        {ok, Name, Arg} ->
            IsCond = lists:member(Name, ["if","ifdef","ifndef","else","elif","endif"]),
            case Active orelse IsCond of
                true ->
                    {Extra, St2} = handle_directive(Name, Arg, N, St),
                    pp_lines(Rest, N + 1, St2, prepend(Extra, Acc));
                false ->
                    pp_lines(Rest, N + 1, St, Acc)
            end;
        none when Active ->
            Toks = strip_eof(fatcc_lex:scan(Line, {N, 1})),
            Expanded = expand(Toks, St, []),
            pp_lines(Rest, N + 1, St, prepend(Expanded, Acc));
        none ->
            pp_lines(Rest, N + 1, St, Acc)
    end.

prepend([], Acc) -> Acc;
prepend(Toks, Acc) -> lists:reverse(Toks) ++ Acc.

strip_eof(Toks) -> [T || T <- Toks, element(1, T) =/= eof].

directive(Line) ->
    case string:trim(Line, leading) of
        [$# | Rest0] ->
            Rest = string:trim(Rest0, leading),
            {Name, Arg} = split_word(Rest),
            {ok, Name, Arg};
        _ -> none
    end.

split_word(Str) -> split_word(Str, []).
split_word([C | R], Acc) when (C >= $a andalso C =< $z); (C >= $A andalso C =< $Z); C =:= $_ ->
    split_word(R, [C | Acc]);
split_word(R, Acc) ->
    {lists:reverse(Acc), string:trim(R, leading)}.

%%====================================================================
%% Directives
%%====================================================================
handle_directive("include", Arg, N, St) ->
    {Name, Angled} = include_name(Arg, N),
    Path = find_include(Name, Angled, St),
    case Path of
        undefined ->
            throw({pp_error, {N, 1}, io_lib:format("header not found: ~s", [Name])});
        _ ->
            process_file(Path, St, [])
    end;
handle_directive("define", Arg, N, St) ->
    {[], do_define(Arg, N, St)};
handle_directive("undef", Arg, _N, St) ->
    {Name, _} = split_word(Arg),
    {[], St#pp{macros = maps:remove(Name, St#pp.macros)}};
handle_directive("pragma", Arg, _N, St) ->
    {[], St};
handle_directive("error", Arg, N, _St) ->
    throw({pp_error, {N, 1}, io_lib:format("#error ~s", [Arg])});
handle_directive("warning", _Arg, _N, St) -> {[], St};
handle_directive("line", _Arg, _N, St) -> {[], St};
handle_directive("ifdef", Arg, N, St) ->
    {Name, _} = split_word(Arg),
    push_cond(maps:is_key(Name, St#pp.macros), N, St);
handle_directive("ifndef", Arg, N, St) ->
    {Name, _} = split_word(Arg),
    push_cond(not maps:is_key(Name, St#pp.macros), N, St);
handle_directive("if", Arg, N, St) ->
    push_cond(eval_cond(Arg, N, St), N, St);
handle_directive("elif", Arg, N, St) ->
    elif_cond(eval_cond(Arg, N, St), N, St);
handle_directive("else", _Arg, N, St) ->
    else_cond(N, St);
handle_directive("endif", _Arg, _N, St) ->
    pop_cond(St);
handle_directive(_Other, _Arg, _N, St) ->
    {[], St}.

%%====================================================================
%% Conditional stack
%%
%% Each entry: {ParentActive, BranchTaken, Active}
%%====================================================================
push_cond(Cond, _N, St) ->
    ParentActive = current_active(St),
    Active = ParentActive andalso cond_true(Cond),
    {[], St#pp{conds = [{ParentActive, Active, Active} | St#pp.conds]}}.

elif_cond(Cond, N, St) ->
    case St#pp.conds of
        [] -> throw({pp_error, {N, 1}, "#elif without #if"});
        [{Parent, Taken, _} | Rest] ->
            Active = Parent andalso (not Taken) andalso cond_true(Cond),
            {[], St#pp{conds = [{Parent, Taken orelse Active, Active} | Rest]}}
    end.

else_cond(N, St) ->
    case St#pp.conds of
        [] -> throw({pp_error, {N, 1}, "#else without #if"});
        [{Parent, Taken, _} | Rest] ->
            Active = Parent andalso (not Taken),
            {[], St#pp{conds = [{Parent, true, Active} | Rest]}}
    end.

pop_cond(St) ->
    case St#pp.conds of
        [] -> {[], St};
        [_ | Rest] -> {[], St#pp{conds = Rest}}
    end.

current_active(#pp{conds = []}) -> true;
current_active(#pp{conds = [{_, _, Active} | _]}) -> Active.

cond_true(true) -> true;
cond_true(false) -> false;
cond_true(Int) when is_integer(Int) -> Int =/= 0.

%%====================================================================
%% #if expression evaluation (integer constant expressions)
%%====================================================================
eval_cond(Arg, N, St) ->
    Toks = strip_eof(fatcc_lex:scan(Arg, {N, 1})),
    Expanded = expand(Toks, St, []),
    {Expr, Rest} = fatcc_parse:parse_pp_expr(Expanded),
    case Rest of
        [] -> eval_pp(Expr);
        _ -> throw({pp_error, {N, 1}, "trailing tokens in #if expression"})
    end.

eval_pp({int, V}) -> V;
eval_pp({id, _}) -> 0;   % undefined identifiers evaluate to 0
eval_pp({un, '!', A}) -> bool_to_int(eval_pp(A) =:= 0);
eval_pp({un, '~', A}) -> bnot eval_pp(A);
eval_pp({un, '-', A}) -> -eval_pp(A);
eval_pp({un, '+', A}) -> eval_pp(A);
eval_pp({bin, Op, A, B}) -> eval_bin(Op, eval_pp(A), eval_pp(B));
eval_pp({ternary, C, T, F}) -> case eval_pp(C) =/= 0 of true -> eval_pp(T); false -> eval_pp(F) end;
eval_pp(_) -> throw({pp_error, {1, 1}, "non-constant #if expression"}).

eval_bin('||', A, B) -> bool_to_int(A =/= 0 orelse B =/= 0);
eval_bin('&&', A, B) -> bool_to_int(A =/= 0 andalso B =/= 0);
eval_bin('|', A, B) -> A bor B;
eval_bin('^', A, B) -> A bxor B;
eval_bin('&', A, B) -> A band B;
eval_bin('==', A, B) -> bool_to_int(A =:= B);
eval_bin('!=', A, B) -> bool_to_int(A =/= B);
eval_bin('<', A, B) -> bool_to_int(A < B);
eval_bin('<=', A, B) -> bool_to_int(A =< B);
eval_bin('>', A, B) -> bool_to_int(A > B);
eval_bin('>=', A, B) -> bool_to_int(A >= B);
eval_bin('<<', A, B) -> A bsl B;
eval_bin('>>', A, B) -> A bsr B;
eval_bin('+', A, B) -> A + B;
eval_bin('-', A, B) -> A - B;
eval_bin('*', A, B) -> A * B;
eval_bin('/', A, B) when B =/= 0 -> A div B;
eval_bin('/', _, _) -> 0;
eval_bin('%', A, B) when B =/= 0 -> A rem B;
eval_bin('%', _, _) -> 0.

bool_to_int(true) -> 1;
bool_to_int(false) -> 0.

%%====================================================================
%% Include resolution
%%====================================================================
include_name(Arg, N) ->
    case string:trim(Arg) of
        [$" | R] -> {until(R, $", N), false};
        [$< | R] -> {until(R, $>, N), true};
        _ -> throw({pp_error, {N, 1}, "malformed #include"})
    end.

until(Str, Term, N) -> until(Str, Term, N, []).
until([C | R], Term, N, Acc) ->
    case C =:= Term of
        true -> lists:reverse(Acc);
        false -> until(R, Term, N, [C | Acc])
    end;
until([], _Term, N, _) ->
    throw({pp_error, {N, 1}, "unterminated #include"}).

find_include(Name, false, #pp{curdir = Cur, dirs = Dirs}) ->
    find_first([Cur | Dirs], Name);
find_include(Name, true, #pp{dirs = Dirs}) ->
    find_first(Dirs, Name).

find_first([], _Name) -> undefined;
find_first([D | Rest], Name) ->
    Path = filename:join(D, Name),
    case filelib:is_file(Path) of
        true -> Path;
        false -> find_first(Rest, Name)
    end.

%%====================================================================
%% Macro definitions
%%====================================================================
do_define(Arg, N, St) ->
    {Name, Rest0} = split_word(Arg),
    case Name of
        [] -> throw({pp_error, {N, 1}, "#define missing name"});
        _ -> ok
    end,
    case Rest0 of
        [$( | _] ->
            {Params, Var, Rest1} = parse_macro_params(Rest0, N),
            Body = scan_body(Rest1),
            St#pp{macros = maps:put(Name, {funm, Params, Var, Body}, St#pp.macros)};
        _ ->
            Body = scan_body(Rest0),
            St#pp{macros = maps:put(Name, {obj, Body}, St#pp.macros)}
    end.

parse_macro_params(Rest, N) ->
    {Inner, After} = take_parens(Rest, N),
    {Params, Var} = macro_params(Inner),
    {Params, Var, string:trim(After, leading)}.

take_parens([$( | R], N) -> take_parens(R, 1, [], N);
take_parens(_, N) -> throw({pp_error, {N, 1}, "malformed macro parameters"}).

take_parens([$) | R], 1, Acc, _N) -> {lists:reverse(Acc), R};
take_parens([$( | R], D, Acc, N) -> take_parens(R, D + 1, [$( | Acc], N);
take_parens([$) | R], D, Acc, N) -> take_parens(R, D - 1, [$) | Acc], N);
take_parens([C | R], D, Acc, N) -> take_parens(R, D, [C | Acc], N);
take_parens([], _, _, N) -> throw({pp_error, {N, 1}, "unterminated macro parameters"}).

macro_params(Inner) ->
    Parts = [string:trim(P) || P <- string:split(Inner, ",", all)],
    case Parts of
        [""] -> {[], false};
        _ ->
            case lists:last(Parts) of
                "..." -> {lists:droplast(Parts), true};
                _ -> {Parts, false}
            end
    end.

scan_body(Str) ->
    Raw = fatcc_lex:scan(Str, {1, 1}),
    [T || T <- Raw, element(1, T) =/= eof].

%%====================================================================
%% Macro expansion
%%====================================================================
expand([], _St, _Dis) -> [];
expand([T | Rest], St, Dis) ->
    case T of
        {id, Name, _} ->
            case maps:get(Name, St#pp.macros, undefined) of
                {obj, Body} ->
                    case lists:member(Name, Dis) of
                        true -> [T | expand(Rest, St, Dis)];
                        false -> expand(Body, St, [Name | Dis]) ++ expand(Rest, St, Dis)
                    end;
                {funm, Params, Var, Body} ->
                    case next_is_lparen(Rest) of
                        true ->
                            {Args, Rest2} = collect_args(Rest),
                            Sub = substitute(Body, Params, Var, Args),
                            expand(Sub, St, [Name | Dis]) ++ expand(Rest2, St, Dis);
                        false ->
                            [T | expand(Rest, St, Dis)]
                    end;
                undefined ->
                    [T | expand(Rest, St, Dis)]
            end;
        _ ->
            [T | expand(Rest, St, Dis)]
    end.

next_is_lparen([{punct, '(', _} | _]) -> true;
next_is_lparen(_) -> false.

collect_args([{punct, '(', _} | Rest]) -> collect_args(Rest, 1, [], []).

collect_args([T = {punct, '(', _} | R], D, Cur, Acc) ->
    collect_args(R, D + 1, [T | Cur], Acc);
collect_args([{punct, ')', _} | R], 1, Cur, Acc) ->
    {lists:reverse([lists:reverse(Cur) | Acc]), R};
collect_args([T = {punct, ')', _} | R], D, Cur, Acc) ->
    collect_args(R, D - 1, [T | Cur], Acc);
collect_args([{punct, ',', _} | R], 1, Cur, Acc) ->
    collect_args(R, 1, [], [lists:reverse(Cur) | Acc]);
collect_args([T | R], D, Cur, Acc) ->
    collect_args(R, D, [T | Cur], Acc);
collect_args([], _, _, _) ->
    throw({pp_error, {1, 1}, "unterminated macro arguments"}).

substitute(Body, Params, Var, Args) ->
    N = length(Params),
    Fixed = lists:sublist(Args, N),
    RestArgs = safe_nthtail(N, Args),
    Map = maps:from_list(lists:zip(Params, Fixed)),
    lists:flatmap(
      fun({id, Name, Loc}) ->
              case maps:find(Name, Map) of
                  {ok, ArgToks} -> ArgToks;
                  error ->
                      case Var andalso Name =:= "__VA_ARGS__" of
                          true -> join_args(RestArgs);
                          false -> [{id, Name, Loc}]
                      end
              end;
         (T) -> [T]
      end, Body).

safe_nthtail(N, L) ->
    case length(L) >= N of
        true -> lists:nthtail(N, L);
        false -> []
    end.

join_args([]) -> [];
join_args([A]) -> A;
join_args([A | Rest]) -> A ++ [{punct, ',', {0, 0}} | join_args(Rest)].
