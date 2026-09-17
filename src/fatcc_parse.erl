%% Recursive-descent C parser with Pratt-style expression precedence.
%%
%% Typedef-name disambiguation is done with a (per-parse) process dictionary
%% mapping typedef names to their types, which is exactly the classic C
%% "lexer hack" applied at the parser level.
-module(fatcc_parse).

-export([parse/1, parse_pp_expr/1]).

%%====================================================================
%% Entry points
%%====================================================================
-spec parse([fatcc_lex:token()]) -> {ok, list()} | {error, list()}.
parse(Toks0) ->
    Toks = ensure_eof(Toks0),
    put(fatcc_typedefs, #{}),
    try
        {Items, Rest} = parse_items(Toks, []),
        case Rest of
            [{eof, _}] -> {ok, Items};
            [T | _] -> {error, [{tloc(T), "unexpected token at end of file"}]}
        end
    catch
        throw:{parse_error, Loc, Msg} ->
            {error, [{Loc, lists:flatten(Msg)}]}
    end.

ensure_eof([]) -> [{eof, {1, 1}}];
ensure_eof(Toks) ->
    case lists:last(Toks) of
        {eof, _} -> Toks;
        _ -> Toks ++ [{eof, {1, 1}}]
    end.
tloc({kw, _, L}) -> L;
tloc({id, _, L}) -> L;
tloc({int, _, L}) -> L;
tloc({float, _, L}) -> L;
tloc({char, _, L}) -> L;
tloc({str, _, L}) -> L;
tloc({punct, _, L}) -> L;
tloc({eof, L}) -> L.

err(Loc, Fmt, Args) -> throw({parse_error, Loc, io_lib:format(Fmt, Args)}).

expect_punct(P, [{punct, P, _} | R]) -> R;
expect_punct(P, [T | _]) -> err(tloc(T), "expected '~s'", [P]);
expect_punct(P, []) -> err({1, 1}, "expected '~s', got end of file", [P]).

expect_kw(K, [{kw, K, _} | R]) -> R;
expect_kw(K, [T | _]) -> err(tloc(T), "expected '~s'", [K]).

%%====================================================================
%% Typedef table (process dictionary)
%%====================================================================
is_typedef(Name) ->
    maps:is_key(Name, get(fatcc_typedefs)).

get_typedef(Name) ->
    maps:get(Name, get(fatcc_typedefs)).

add_typedef(Name, Type) ->
    put(fatcc_typedefs, maps:put(Name, Type, get(fatcc_typedefs))).

%%====================================================================
%% Top level
%%====================================================================
parse_items([{eof, _}] = T, Acc) -> {lists:reverse(Acc), T};
parse_items(Toks, Acc) ->
    {Items, Rest} = parse_top(Toks),
    parse_items(Rest, lists:reverse(Items) ++ Acc).

parse_top([{punct, ';', _} | R]) ->
    {[], R};
parse_top(Toks) ->
    {Storage, Base, T1} = parse_decl_specs(Toks),
    case T1 of
        [{punct, ';', _} | R] ->
            {[], R};
        _ ->
            {Name, DType, T2} = parse_declarator(T1, Base),
            case {T2, Storage} of
                {[{punct, '{', _} | _], St} when St =/= typedef, Name =/= "" ->
                    {Body, Rest} = parse_block(T2),
                    {[{func, ret_of(DType), Name, params_of(DType),
                       var_of(DType), Body}], Rest};
                _ ->
                    {Init, T3} = parse_opt_init(T2),
                    {More, T4} = parse_more_decls(T3, Base, []),
                    Decls = [{DType, Name, Init} | More],
                    Items = wrap_decls(Storage, Decls),
                    {Items, expect_punct(';', T4)}
            end
    end.

%% After the first declarator of a declaration list.
parse_more_decls([{punct, ',', _} | R], Base, Acc) ->
    {Name, Type, T1} = parse_declarator(R, Base),
    {Init, T2} = parse_opt_init(T1),
    parse_more_decls(T2, Base, [{Type, Name, Init} | Acc]);
parse_more_decls(Toks, _Base, Acc) ->
    {lists:reverse(Acc), Toks}.

parse_opt_init([{punct, '=', _} | R]) -> parse_init(R);
parse_opt_init(Toks) -> {none, Toks}.

parse_init([{punct, '{', _} | _] = Toks) ->
    {Items, R} = parse_init_list(Toks),
    {{init_list, Items}, R};
parse_init(Toks) ->
    parse_assign(Toks).

parse_init_list([{punct, '{', _} | R]) -> parse_init_items(R, []).

parse_init_items([{punct, '}', _} | R], Acc) -> {lists:reverse(Acc), R};
parse_init_items([{punct, '{', _} | _] = Toks, Acc) ->
    {Inner, R} = parse_init_list(Toks),
    parse_init_items_cont(R, [Inner | Acc]);
parse_init_items(Toks, Acc) ->
    {E, R} = parse_assign(Toks),
    parse_init_items_cont(R, [E | Acc]).

parse_init_items_cont([{punct, ',', _} | R], Acc) -> parse_init_items(R, Acc);
parse_init_items_cont(R, Acc) -> {lists:reverse(Acc), R}.

wrap_decls(typedef, Decls) ->
    lists:foreach(fun({T, N, _}) -> add_typedef(N, T) end, Decls),
    [];
wrap_decls(_Storage, Decls) ->
    [case T of
         {func, R, P, V} -> {proto, R, N, P, V};
         _ -> {global, T, N, Init}
     end || {T, N, Init} <- Decls].

ret_of({func, R, _, _}) -> R;
ret_of(T) -> T.
params_of({func, _, P, _}) -> P;
params_of(_) -> [].
var_of({func, _, _, V}) -> V;
var_of(_) -> false.

%%====================================================================
%% Declaration specifiers
%%====================================================================
parse_decl_specs(Toks) -> ds(Toks, none, []).

ds([{kw, K, _} | R], Storage, Flags)
  when K =:= typedef; K =:= extern; K =:= static; K =:= auto; K =:= register ->
    ds(R, K, Flags);
ds([{kw, const, _} | R], Storage, Flags) -> ds(R, Storage, [const | Flags]);
ds([{kw, volatile, _} | R], Storage, Flags) -> ds(R, Storage, [volatile | Flags]);
ds([{kw, restrict, _} | R], Storage, Flags) -> ds(R, Storage, [restrict | Flags]);
ds([{kw, '_Atomic', _} | R], Storage, Flags) -> ds(R, Storage, ['_Atomic' | Flags]);
ds([{kw, '_Alignas', _} | R], Storage, Flags) ->
    R1 = skip_balanced_parens(R),
    ds(R1, Storage, Flags);
ds([{kw, K, _} | R], Storage, Flags)
  when K =:= void; K =:= '_Bool'; K =:= char; K =:= short; K =:= int;
       K =:= long; K =:= float; K =:= double; K =:= signed; K =:= unsigned;
       K =:= '_Complex' ->
    ds(R, Storage, [K | Flags]);
ds([{kw, struct, _} | R], Storage, Flags) ->
    {T, R1} = parse_struct_or_union(struct, R),
    ds(R1, Storage, [T | Flags]);
ds([{kw, union, _} | R], Storage, Flags) ->
    {T, R1} = parse_struct_or_union(union, R),
    ds(R1, Storage, [T | Flags]);
ds([{kw, enum, _} | R], Storage, Flags) ->
    {T, R1} = parse_enum(R),
    ds(R1, Storage, [T | Flags]);
ds([{id, Name, _} = T | R], Storage, Flags) ->
    case is_typedef(Name) of
        true -> ds(R, Storage, [{typedef, Name} | Flags]);
        false -> {Storage, resolve_type(Flags), [T | R]}
    end;
ds(Toks, Storage, Flags) ->
    {Storage, resolve_type(Flags), Toks}.

skip_balanced_parens([{punct, '(', _} | R]) -> skip_balanced_parens(R, 1);
skip_balanced_parens(R) -> R.
skip_balanced_parens([{punct, '(', _} | R], D) -> skip_balanced_parens(R, D + 1);
skip_balanced_parens([{punct, ')', _} | R], 1) -> R;
skip_balanced_parens([{punct, ')', _} | R], D) -> skip_balanced_parens(R, D - 1);
skip_balanced_parens([_ | R], D) -> skip_balanced_parens(R, D);
skip_balanced_parens([], _) -> [].

resolve_type([]) -> int;
resolve_type(Flags0) ->
    Flags = lists:reverse(Flags0),
    case find_named_type(Flags) of
        {ok, T} -> T;
        error -> resolve_arith(Flags)
    end.

find_named_type([]) -> error;
find_named_type([{typedef, N} | _]) -> {ok, get_typedef(N)};
find_named_type([{struct, _, _} = T | _]) -> {ok, T};
find_named_type([{struct, _} = T | _]) -> {ok, T};
find_named_type([{union, _, _} = T | _]) -> {ok, T};
find_named_type([{union, _} = T | _]) -> {ok, T};
find_named_type([{enum, _, _} = T | _]) -> {ok, T};
find_named_type([{enum, _} = T | _]) -> {ok, T};
find_named_type([_ | R]) -> find_named_type(R).

resolve_arith(Flags) ->
    Void = lists:member(void, Flags),
    Bool = lists:member('_Bool', Flags),
    Flt = lists:member(float, Flags),
    Dbl = lists:member(double, Flags),
    Chr = lists:member(char, Flags),
    Uns = lists:member(unsigned, Flags),
    Sgn = lists:member(signed, Flags),
    Shorts = length([x || x <- Flags, x =:= short]),
    Longs = length([x || x <- Flags, x =:= long]),
    if
        Void -> void;
        Bool -> bool;
        Flt -> float;
        Dbl -> double;
        Chr -> if Uns -> uchar; Sgn -> schar; true -> char end;
        Shorts > 0 -> if Uns -> ushort; true -> short end;
        Longs >= 2 -> if Uns -> ullong; true -> llong end;
        Longs =:= 1 -> if Uns -> ulong; true -> long end;
        Uns -> uint;
        true -> int
    end.

%%====================================================================
%% struct / union / enum
%%====================================================================
parse_struct_or_union(Kind, Toks) ->
    {Tag, T1} = case Toks of
                    [{id, N, _} | R0] -> {list_to_atom(N), R0};
                    _ -> {undefined, Toks}
                end,
    case T1 of
        [{punct, '{', _} | R1] ->
            {Members, R2} = parse_members(R1, []),
            erlang:put({fatcc_tag, {Kind, Tag}}, Members),
            {{Kind, Tag, Members}, R2};
        _ ->
            {{Kind, Tag}, T1}
    end.

parse_members([{punct, '}', _} | R], Acc) ->
    {lists:reverse(Acc), R};
parse_members(Toks, Acc) ->
    {_St, Base, T1} = parse_decl_specs(Toks),
    {Members, T2} = parse_member_decls(T1, Base, []),
    case T2 of
        [{punct, ';', _} | R] -> parse_members(R, lists:reverse(Members) ++ Acc);
        _ -> err(tloc(hd(T2)), "expected ';' in struct/union body", [])
    end.

parse_member_decls([{punct, ';', _} | _] = Toks, _Base, Acc) ->
    {lists:reverse(Acc), Toks};
parse_member_decls(Toks, Base, Acc) ->
    {Name, Type, T1} = parse_declarator(Toks, Base),
    {Bits, T2} = case T1 of
                     [{punct, ':', _} | RB] -> {W, R1} = parse_assign(RB), {W, R1};
                     _ -> {none, T1}
                 end,
    Acc1 = [{Name, Type, Bits} | Acc],
    case T2 of
        [{punct, ',', _} | RC] -> parse_member_decls(RC, Base, Acc1);
        _ -> {lists:reverse(Acc1), T2}
    end.

parse_enum(Toks) ->
    {Tag, T1} = case Toks of
                    [{id, N, _} | R0] -> {list_to_atom(N), R0};
                    _ -> {undefined, Toks}
                end,
    case T1 of
        [{punct, '{', _} | R1] ->
            _ = parse_enumerators(R1, 0),
            {{enum, Tag}, skip_to_brace_close(R1)};
        _ ->
            {{enum, Tag}, T1}
    end.

parse_enumerators([{punct, '}', _} | _] = Toks, _V) -> Toks;
parse_enumerators([{id, _N, _} | R], V) ->
    case R of
        [{punct, '=', _} | R1] -> parse_enumerator_init(R1);
        _ -> skip_to_comma_or_close(R, V)
    end.

parse_enumerator_init(Toks) ->
    {_E, R} = parse_assign(Toks),
    skip_to_comma_or_close(R, 0).

skip_to_comma_or_close([{punct, ',', _} | R], V) -> skip_to_comma_or_close(R, V);
skip_to_comma_or_close([{punct, '}', _} | _] = T, _V) -> T;
skip_to_comma_or_close([_ | R], V) -> skip_to_comma_or_close(R, V);
skip_to_comma_or_close([], V) -> error({unterminated_enum, V}).

skip_to_brace_close([{punct, '}', _} | R]) -> R;
skip_to_brace_close([_ | R]) -> skip_to_brace_close(R);
skip_to_brace_close([]) -> [].

%%====================================================================
%% Declarators
%%====================================================================
parse_declarator(Toks, Base) ->
    {Base1, T1} = parse_pointers(Toks, Base),
    case T1 of
        [{punct, '(', _} | R] ->
            case is_param_start(R) of
                true ->
                    parse_name_and_suffix(T1, Base1);
                false ->
                    Dummy = {'$dummy'},
                    {_, _, After} = parse_declarator(R, Dummy),
                    After1 = expect_punct(')', After),
                    {Ty1, After2} = type_suffix(After1, Base1),
                    {Name, Ty2, After3} = parse_declarator(R, Ty1),
                    After4 = expect_punct(')', After3),
                    {Name, Ty2, After4}
            end;
        _ ->
            parse_name_and_suffix(T1, Base1)
    end.

parse_pointers([{punct, '*', _} | R], Base) ->
    {R1, _Quals} = parse_qualifiers(R),
    parse_pointers(R1, {ptr, Base});
parse_pointers(Toks, Base) ->
    {Base, Toks}.

parse_qualifiers([{kw, K, _} | R]) when K =:= const; K =:= volatile; K =:= restrict ->
    parse_qualifiers(R);
parse_qualifiers(Toks) -> {Toks, []}.

parse_name_and_suffix([{id, Name, _} | R], Base) ->
    {Type, R1} = type_suffix(R, Base),
    {Name, Type, R1};
parse_name_and_suffix(Toks, Base) ->
    {Type, R1} = type_suffix(Toks, Base),
    {"", Type, R1}.

type_suffix([{punct, '[', _} | R], Ty) ->
    {N, R1} = parse_array_size(R),
    R2 = expect_punct(']', R1),
    type_suffix(R2, {array, Ty, N});
type_suffix([{punct, '(', _} | R], Ty) ->
    {Params, Var, R1} = parse_params(R),
    R2 = expect_punct(')', R1),
    type_suffix(R2, {func, Ty, Params, Var});
type_suffix(Toks, Ty) ->
    {Ty, Toks}.

parse_array_size([{punct, ']', _} | _] = Toks) -> {undefined, Toks};
parse_array_size(Toks) ->
    case is_qualifier_or_static(Toks) of
        true -> parse_array_size(skip_static(Toks));
        false -> parse_assign(Toks)
    end.

is_qualifier_or_static([{kw, K, _} | _]) when K =:= const; K =:= volatile; K =:= restrict; K =:= static -> true;
is_qualifier_or_static(_) -> false.

skip_static([{kw, K, _} | R]) when K =:= const; K =:= volatile; K =:= restrict; K =:= static ->
    skip_static(R);
skip_static(R) -> R.

%% Parameter list (after '('), returns {Params, Variadic, Rest}
parse_params(Toks) -> pp_params(Toks, []).

pp_params([{punct, ')', _} | _] = Toks, Acc) ->
    {normalize_params(lists:reverse(Acc)), false, Toks};
pp_params([{punct, '...', _} | R], Acc) ->
    {normalize_params(lists:reverse(Acc)), true, R};
pp_params(Toks, Acc) ->
    {_St, Base, T1} = parse_decl_specs(Toks),
    {Name, FType, T2} =
        case T1 of
            [{punct, ')', _} | _] -> {"", Base, T1};
            [{punct, ',', _} | _] -> {"", Base, T1};
            _ -> parse_declarator(T1, Base)
        end,
    Name2 = case Name of
                "" -> "arg" ++ integer_to_list(length(Acc) + 1);
                _ -> Name
            end,
    T3 = case T2 of
             [{punct, ',', _} | R] -> R;
             _ -> T2
         end,
    pp_params(T3, [{FType, Name2} | Acc]).

normalize_params([{void, _}]) -> [];
normalize_params(P) -> P.

%%====================================================================
%% Type names (for casts / sizeof)
%%====================================================================
parse_type_name(Toks) ->
    {_St, Base, T1} = parse_decl_specs(Toks),
    {_Name, Type, T2} = parse_declarator(T1, Base),
    {Type, T2}.

is_param_start([]) -> true;
is_param_start([{punct, ')', _} | _]) -> true;
is_param_start([{punct, '...', _} | _]) -> true;
is_param_start(Toks) -> is_type_start(Toks).

is_type_start([{kw, K, _} | _]) -> is_type_kw(K);
is_type_start([{id, N, _} | _]) -> is_typedef(N);
is_type_start(_) -> false.

is_type_kw(K) ->
    lists:member(K, [void, '_Bool', char, short, int, long, float, double,
                     signed, unsigned, struct, union, enum, const, volatile,
                     restrict, auto, register, extern, static, typedef,
                     '_Atomic', '_Complex']).

is_decl_start(Toks) ->
    case Toks of
        [{kw, K, _} | _] ->
            lists:member(K, [typedef, extern, static, auto, register, const,
                             volatile, restrict, void, '_Bool', char, short,
                             int, long, float, double, signed, unsigned,
                             struct, union, enum, '_Atomic']);
        [{id, N, _} | _] -> is_typedef(N);
        _ -> false
    end.

%%====================================================================
%% Statements
%%====================================================================
parse_block([{punct, '{', _} | R]) ->
    parse_block_items(R, []).

parse_block_items([{punct, '}', _} | R], Acc) ->
    {{block, lists:reverse(Acc)}, R};
parse_block_items(Toks, Acc) ->
    {Items, Rest} = parse_block_item(Toks),
    parse_block_items(Rest, lists:reverse(Items) ++ Acc).

parse_block_item(Toks) ->
    case Toks of
        [{kw, '_Static_assert', _} | _] ->
            {[], skip_to_semi(Toks)};
        _ ->
            case is_decl_start(Toks) of
                true -> parse_local_decl(Toks);
                false ->
                    {S, R} = parse_stmt(Toks),
                    {[S], R}
            end
    end.

skip_to_semi([{punct, ';', _} | R]) -> R;
skip_to_semi([_ | R]) -> skip_to_semi(R);
skip_to_semi([]) -> [].

parse_local_decl(Toks) ->
    {Storage, Base, T1} = parse_decl_specs(Toks),
    {First, T2} = parse_local_declarator(T1, Base),
    {Rest, T3} = parse_local_more(T2, Base, []),
    Decls = [First | Rest],
    T4 = expect_punct(';', T3),
    case Storage of
        typedef ->
            lists:foreach(fun({T, N, _}) -> add_typedef(N, T) end, Decls),
            {[], T4};
        _ ->
            {[{var, T, N, I} || {T, N, I} <- Decls], T4}
    end.

parse_local_declarator(Toks, Base) ->
    {Name, Type, T1} = parse_declarator(Toks, Base),
    {Init, T2} = parse_opt_init(T1),
    {{Type, Name, Init}, T2}.

parse_local_more([{punct, ',', _} | R], Base, Acc) ->
    {D, T1} = parse_local_declarator(R, Base),
    parse_local_more(T1, Base, [D | Acc]);
parse_local_more(Toks, _Base, Acc) ->
    {lists:reverse(Acc), Toks}.

parse_stmt([{punct, '{', _} | _] = Toks) ->
    {Body, R} = parse_block(Toks),
    {Body, R};
parse_stmt([{punct, ';', _} | R]) ->
    {{block, []}, R};
parse_stmt([{kw, return, _} | R]) ->
    case R of
        [{punct, ';', _} | R1] -> {{ret, none}, R1};
        _ ->
            {E, R1} = parse_expr(R),
            {{ret, E}, expect_punct(';', R1)}
    end;
parse_stmt([{kw, 'if', _} | R]) ->
    R1 = expect_punct('(', R),
    {C, R2} = parse_expr(R1),
    R3 = expect_punct(')', R2),
    {Then, R4} = parse_stmt(R3),
    case R4 of
        [{kw, 'else', _} | R5] ->
            {Else, R6} = parse_stmt(R5),
            {{'if', C, Then, Else}, R6};
        _ ->
            {{'if', C, Then, {block, []}}, R4}
    end;
parse_stmt([{kw, while, _} | R]) ->
    R1 = expect_punct('(', R),
    {C, R2} = parse_expr(R1),
    R3 = expect_punct(')', R2),
    {Body, R4} = parse_stmt(R3),
    {{while, C, Body}, R4};
parse_stmt([{kw, do, _} | R]) ->
    {Body, R1} = parse_stmt(R),
    R2 = expect_kw(while, R1),
    R3 = expect_punct('(', R2),
    {C, R4} = parse_expr(R3),
    R5 = expect_punct(')', R4),
    {{do, Body, C}, expect_punct(';', R5)};
parse_stmt([{kw, for, _} | R]) ->
    R1 = expect_punct('(', R),
    {Init, R2} = parse_for_init(R1),
    R3 = expect_punct(';', R2),
    {Cond, R4} = case R3 of
                     [{punct, ';', _} | Rx] -> {none, Rx};
                     _ -> parse_expr(R3)
                 end,
    R5 = expect_punct(';', R4),
    {Step, R6} = case R5 of
                     [{punct, ')', _} | _] -> {none, R5};
                     _ -> parse_expr(R5)
                 end,
    R7 = expect_punct(')', R6),
    {Body, R8} = parse_stmt(R7),
    {{for, Init, Cond, Step, Body}, R8};
parse_stmt([{kw, break, _} | R]) -> {{break}, expect_punct(';', R)};
parse_stmt([{kw, continue, _} | R]) -> {{continue}, expect_punct(';', R)};
parse_stmt([{kw, goto, _} | R]) ->
    case R of
        [{id, Label, _} | R1] -> {{goto, Label}, expect_punct(';', R1)};
        _ -> err(tloc(hd(R)), "expected label after goto", [])
    end;
parse_stmt([{kw, switch, _} | R]) ->
    R1 = expect_punct('(', R),
    {E, R2} = parse_expr(R1),
    R3 = expect_punct(')', R2),
    {Body, R4} = parse_stmt(R3),
    {{switch, E, Body}, R4};
parse_stmt([{kw, 'case', _} | R]) ->
    {V, R1} = parse_assign(R),
    R2 = expect_punct(':', R1),
    {Body, R3} = parse_stmt(R2),
    {{'case', V, Body}, R3};
parse_stmt([{kw, default, _} | R]) ->
    R1 = expect_punct(':', R),
    {Body, R2} = parse_stmt(R1),
    {{default, Body}, R2};
parse_stmt([{id, Name, _}, {punct, ':', _} | R]) ->
    {Body, R1} = parse_stmt(R),
    {{label, Name, Body}, R1};
parse_stmt(Toks) ->
    {E, R} = parse_expr(Toks),
    {{expr, E}, expect_punct(';', R)}.

parse_for_init([{punct, ';', _} | _] = Toks) ->
    {none, Toks};
parse_for_init(Toks) ->
    case is_decl_start(Toks) of
        true ->
            {Storage, Base, T1} = parse_decl_specs(Toks),
            {First, T2} = parse_local_declarator(T1, Base),
            {Rest, T3} = parse_local_more(T2, Base, []),
            Decls = [First | Rest],
            case Storage of
                typedef ->
                    lists:foreach(fun({T, N, _}) -> add_typedef(N, T) end, Decls),
                    {none, T3};
                _ ->
                    {{decls, [{var, T, N, I} || {T, N, I} <- Decls]}, T3}
            end;
        false ->
            {E, R} = parse_expr(Toks),
            {{expr, E}, R}
    end.

%%====================================================================
%% Expressions
%%====================================================================
parse_expr(Toks) ->
    {E, R} = parse_assign(Toks),
    parse_comma_loop(R, E).

parse_comma_loop([{punct, ',', _} | R], E) ->
    {E2, R1} = parse_assign(R),
    parse_comma_loop(R1, {comma, E, E2});
parse_comma_loop(Toks, E) -> {E, Toks}.

parse_assign(Toks) ->
    {L, R} = parse_cond(Toks),
    case R of
        [{punct, Op, _} | R1] when Op =:= '='; Op =:= '+='; Op =:= '-='; Op =:= '*=';
                                   Op =:= '/='; Op =:= '%='; Op =:= '&='; Op =:= '|=';
                                   Op =:= '^='; Op =:= '<<='; Op =:= '>>=' ->
            {Rt, R2} = parse_assign(R1),
            {{assign, Op, L, Rt}, R2};
        _ -> {L, R}
    end.

parse_cond(Toks) ->
    {C, R} = parse_logor(Toks),
    case R of
        [{punct, '?', _} | R1] ->
            {T, R2} = parse_expr(R1),
            R3 = expect_punct(':', R2),
            {F, R4} = parse_cond(R3),
            {{ternary, C, T, F}, R4};
        _ -> {C, R}
    end.

parse_logor(Toks) -> parse_bin(Toks, fun parse_logand/1, ['||']).
parse_logand(Toks) -> parse_bin(Toks, fun parse_bitor/1, ['&&']).
parse_bitor(Toks) -> parse_bin(Toks, fun parse_bitxor/1, ['|']).
parse_bitxor(Toks) -> parse_bin(Toks, fun parse_bitand/1, ['^']).
parse_bitand(Toks) -> parse_bin(Toks, fun parse_eq/1, ['&']).
parse_eq(Toks) -> parse_bin(Toks, fun parse_rel/1, ['==', '!=']).
parse_rel(Toks) -> parse_bin(Toks, fun parse_shift/1, ['<', '>', '<=', '>=']).
parse_shift(Toks) -> parse_bin(Toks, fun parse_add/1, ['<<', '>>']).
parse_add(Toks) -> parse_bin(Toks, fun parse_mul/1, ['+', '-']).
parse_mul(Toks) -> parse_bin(Toks, fun parse_cast/1, ['*', '/', '%']).

parse_bin(Toks, Next, Ops) ->
    {L, R} = Next(Toks),
    parse_bin_loop(R, Next, Ops, L).

parse_bin_loop([T = {punct, Op, _} | R], Next, Ops, L) ->
    case lists:member(Op, Ops) of
        true ->
            {Rt, R1} = Next(R),
            parse_bin_loop(R1, Next, Ops, {bin, Op, L, Rt});
        false ->
            {L, [T | R]}
    end;
parse_bin_loop(Toks, _Next, _Ops, L) -> {L, Toks}.

parse_cast([{punct, '(', _} | _] = Toks) ->
    case is_type_start(tl(Toks)) of
        true ->
            try
                {Type, R1} = parse_type_name(tl(Toks)),
                case R1 of
                    [{punct, ')', _} | R2] ->
                        {E, R3} = parse_cast(R2),
                        {{cast, Type, E}, R3};
                    _ -> parse_unary(Toks)
                end
            catch
                throw:{parse_error, _, _} -> parse_unary(Toks)
            end;
        false -> parse_unary(Toks)
    end;
parse_cast(Toks) -> parse_unary(Toks).

parse_unary([{punct, '++', _} | R]) -> {E, R1} = parse_unary(R), {{preinc, E}, R1};
parse_unary([{punct, '--', _} | R]) -> {E, R1} = parse_unary(R), {{predec, E}, R1};
parse_unary([{punct, '&', _} | R]) -> {E, R1} = parse_cast(R), {{addr, E}, R1};
parse_unary([{punct, '*', _} | R]) -> {E, R1} = parse_cast(R), {{deref, E}, R1};
parse_unary([{punct, '+', _} | R]) -> parse_cast(R);
parse_unary([{punct, '-', _} | R]) -> {E, R1} = parse_cast(R), {{un, '-', E}, R1};
parse_unary([{punct, '~', _} | R]) -> {E, R1} = parse_cast(R), {{un, '~', E}, R1};
parse_unary([{punct, '!', _} | R]) -> {E, R1} = parse_cast(R), {{un, '!', E}, R1};
parse_unary([{kw, sizeof, _} | R0]) ->
    case R0 of
        [{punct, '(', _} | R] ->
            case is_type_start(R) of
                true ->
                    {Type, R1} = parse_type_name(R),
                    R2 = expect_punct(')', R1),
                    {{sizeof_type, Type}, R2};
                false ->
                    {E, R1} = parse_unary(R0),
                    {{sizeof_expr, E}, R1}
            end;
        _ ->
            {E, R1} = parse_unary(R0),
            {{sizeof_expr, E}, R1}
    end;
parse_unary([{kw, '_Alignof', _} | R0]) ->
    R1 = expect_punct('(', R0),
    {Type, R2} = parse_type_name(R1),
    R3 = expect_punct(')', R2),
    {{alignof_type, Type}, R3};
parse_unary(Toks) -> parse_postfix(Toks).

parse_postfix(Toks) ->
    {P, R} = parse_primary(Toks),
    parse_postfix_loop(R, P).

parse_postfix_loop([{punct, '[', _} | R], P) ->
    {I, R1} = parse_expr(R),
    R2 = expect_punct(']', R1),
    parse_postfix_loop(R2, {index, P, I});
parse_postfix_loop([{punct, '(', _} | R], P) ->
    {Args, R1} = parse_args(R),
    parse_postfix_loop(R1, {call, P, Args});
parse_postfix_loop([{punct, '.', _} | R], P) ->
    {Name, R1} = field_name(R),
    parse_postfix_loop(R1, {member, P, Name, false});
parse_postfix_loop([{punct, '->', _} | R], P) ->
    {Name, R1} = field_name(R),
    parse_postfix_loop(R1, {member, P, Name, true});
parse_postfix_loop([{punct, '++', _} | R], P) -> parse_postfix_loop(R, {postinc, P});
parse_postfix_loop([{punct, '--', _} | R], P) -> parse_postfix_loop(R, {postdec, P});
parse_postfix_loop(Toks, P) -> {P, Toks}.

field_name([{id, N, _} | R]) -> {N, R};
field_name([T | _]) -> err(tloc(T), "expected field name", []).

parse_args([{punct, ')', _} | _] = Toks) -> {[], Toks};
parse_args(Toks) -> parse_args(Toks, []).
parse_args(Toks, Acc) ->
    {E, R} = parse_assign(Toks),
    case R of
        [{punct, ',', _} | R1] -> parse_args(R1, [E | Acc]);
        [{punct, ')', _} | R1] -> {lists:reverse([E | Acc]), R1};
        [T | _] -> err(tloc(T), "expected ')' in argument list", []);
        [] -> err({1, 1}, "unterminated argument list", [])
    end.

parse_primary([{int, V, _} | R]) -> {{int, V}, R};
parse_primary([{float, F, _} | R]) -> {{float, F}, R};
parse_primary([{char, V, _} | R]) -> {{char, V}, R};
parse_primary([{str, B, _} | R]) -> parse_strings(R, B);
parse_primary([{id, Name, _} | R]) -> {{id, Name}, R};
parse_primary([{punct, '(', _} | R]) ->
    {E, R1} = parse_expr(R),
    {E, expect_punct(')', R1)};
parse_primary([T | _]) -> err(tloc(T), "expected expression, got ~p", [T]);
parse_primary([]) -> err({1, 1}, "expected expression, got end of file", []).

parse_strings([{str, B, _} | R], Acc) ->
    parse_strings(R, <<Acc/binary, B/binary>>);
parse_strings(R, Acc) -> {{str, Acc}, R}.

%%====================================================================
%% #if expression parser (no casts/typedefs needed)
%%====================================================================
parse_pp_expr(Toks) -> pp_ternary(Toks).

pp_ternary(Toks) ->
    {C, R} = pp_logor(Toks),
    case R of
        [{punct, '?', _} | R1] ->
            {T, R2} = parse_pp_expr(R1),
            R3 = expect_punct(':', R2),
            {F, R4} = pp_ternary(R3),
            {{ternary, C, T, F}, R4};
        _ -> {C, R}
    end.

pp_logor(Toks) -> pp_bin(Toks, fun pp_logand/1, ['||']).
pp_logand(Toks) -> pp_bin(Toks, fun pp_bitor/1, ['&&']).
pp_bitor(Toks) -> pp_bin(Toks, fun pp_bitxor/1, ['|']).
pp_bitxor(Toks) -> pp_bin(Toks, fun pp_bitand/1, ['^']).
pp_bitand(Toks) -> pp_bin(Toks, fun pp_eq/1, ['&']).
pp_eq(Toks) -> pp_bin(Toks, fun pp_rel/1, ['==', '!=']).
pp_rel(Toks) -> pp_bin(Toks, fun pp_shift/1, ['<', '>', '<=', '>=']).
pp_shift(Toks) -> pp_bin(Toks, fun pp_add/1, ['<<', '>>']).
pp_add(Toks) -> pp_bin(Toks, fun pp_mul/1, ['+', '-']).
pp_mul(Toks) -> pp_bin(Toks, fun pp_unary/1, ['*', '/', '%']).

pp_bin(Toks, Next, Ops) ->
    {L, R} = Next(Toks),
    pp_bin_loop(R, Next, Ops, L).

pp_bin_loop([T = {punct, Op, _} | R], Next, Ops, L) ->
    case lists:member(Op, Ops) of
        true ->
            {Rt, R1} = Next(R),
            pp_bin_loop(R1, Next, Ops, {bin, Op, L, Rt});
        false ->
            {L, [T | R]}
    end;
pp_bin_loop(Toks, _Next, _Ops, L) -> {L, Toks}.

pp_unary([{punct, '!', _} | R]) -> {E, R1} = pp_unary(R), {{un, '!', E}, R1};
pp_unary([{punct, '~', _} | R]) -> {E, R1} = pp_unary(R), {{un, '~', E}, R1};
pp_unary([{punct, '-', _} | R]) -> {E, R1} = pp_unary(R), {{un, '-', E}, R1};
pp_unary([{punct, '+', _} | R]) -> pp_unary(R);
pp_unary(Toks) -> pp_primary(Toks).

pp_primary([{int, V, _} | R]) -> {{int, V}, R};
pp_primary([{char, V, _} | R]) -> {{int, V}, R};
pp_primary([{id, Name, _} | R]) -> {{id, Name}, R};
pp_primary([{kw, K, _} | R]) -> {{id, atom_to_list(K)}, R};
pp_primary([{punct, '(', _} | R]) ->
    {E, R1} = parse_pp_expr(R),
    {E, expect_punct(')', R1)};
pp_primary([T | _]) -> err(tloc(T), "bad #if expression near ~p", [T]).
