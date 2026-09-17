%% C tokenizer.
%%
%% Produces a flat token list with {Line, Col} locations. Comments are skipped.
%% This is deliberately a single-pass maximal-munch scanner. The preprocessor
%% works on these tokens.
-module(fatcc_lex).

-export([scan/1, scan/2, keyword/1, format_error/1]).

-type loc() :: {pos_integer(), pos_integer()}.
-type token() ::
    {kw, atom(), loc()} |
    {id, string(), loc()} |
    {int, integer(), loc()} |
    {float, float(), loc()} |
    {char, integer(), loc()} |
    {str, binary(), loc()} |
    {punct, atom(), loc()} |
    {eof, loc()}.
-export_type([loc/0, token/0]).

%%====================================================================
%% API
%%====================================================================
-spec scan(iodata()) -> [token()].
scan(Text) -> scan(Text, {1, 1}).

-spec scan(iodata(), loc()) -> [token()].
scan(Text, Loc) when is_list(Text) ->
    scan(unicode:characters_to_binary(Text), Loc);
scan(Bin, Loc) when is_binary(Bin) ->
    toks(Bin, Loc, []).

-spec format_error(term()) -> string().
format_error(Reason) -> lists:flatten(io_lib:format("~p", [Reason])).

%%====================================================================
%% Scanner loop
%%====================================================================
toks(<<>>, Loc, Acc) ->
    lists:reverse([{eof, Loc} | Acc]);
toks(<<C, R/binary>>, {L, Co} = Loc, Acc) ->
    case C of
        $\s -> toks(R, {L, Co + 1}, Acc);
        $\t -> toks(R, {L, Co + 1}, Acc);
        $\v -> toks(R, {L, Co + 1}, Acc);
        $\f -> toks(R, {L, Co + 1}, Acc);
        $\r ->
            case R of
                <<$\n, R2/binary>> -> toks(R2, {L + 1, 1}, Acc);
                _ -> toks(R, {L + 1, 1}, Acc)
            end;
        $\n -> toks(R, {L + 1, 1}, Acc);
        $/ ->
            case R of
                <<$/, R2/binary>> ->
                    toks(skip_line(R2), {L, Co + 2}, Acc);
                <<$*, R2/binary>> ->
                    {L2, C2, R3} = skip_block(R2, L, Co + 2, Acc),
                    toks(R3, {L2, C2}, Acc);
                _ -> punct(<<C, R/binary>>, Loc, Acc)
            end;
        _ when C >= $a, C =< $z; C >= $A, C =< $Z; C =:= $_ ->
            {Name, R2, N} = take_ident(R, [C]),
            Tok = case keyword(Name) of
                      true -> {kw, list_to_atom(Name), Loc};
                      false -> {id, Name, Loc}
                  end,
            toks(R2, {L, Co + N}, [Tok | Acc]);
        _ when C >= $0, C =< $9 ->
            {Tok, R2, N} = number(<<C, R/binary>>, Loc),
            toks(R2, {L, Co + N}, [Tok | Acc]);
        $. ->
            case R of
                <<D, _/binary>> when D >= $0, D =< $9 ->
                    {Tok, R2, N} = number(<<C, R/binary>>, Loc),
                    toks(R2, {L, Co + N}, [Tok | Acc]);
                _ -> punct(<<C, R/binary>>, Loc, Acc)
            end;
        $" ->
            {Str, R2, N} = string_lit(R, [], 0),
            toks(R2, {L, Co + 1 + N + 1}, [{str, Str, Loc} | Acc]);
        $' ->
            {Val, R2, N} = char_lit(R, Loc),
            toks(R2, {L, Co + 1 + N + 1}, [{char, Val, Loc} | Acc]);
        _ ->
            punct(<<C, R/binary>>, Loc, Acc)
    end.

skip_line(<<$\n, R/binary>>) -> R;
skip_line(<<_, R/binary>>) -> skip_line(R);
skip_line(<<>>) -> <<>>.

%% Block comment: returns {Line, Col, Rest}
skip_block(<<$*, $/, R/binary>>, L, Co, _Acc) -> {L, Co + 2, R};
skip_block(<<$\n, R/binary>>, L, _Co, Acc) -> skip_block(R, L + 1, 1, Acc);
skip_block(<<_, R/binary>>, L, Co, Acc) -> skip_block(R, L, Co + 1, Acc);
skip_block(<<>>, L, Co, _Acc) -> {L, Co, <<>>}.

%%====================================================================
%% Identifiers / keywords
%%====================================================================
take_ident(<<C, R/binary>>, Acc)
  when C >= $a, C =< $z; C >= $A, C =< $Z; C >= $0, C =< $9; C =:= $_ ->
    take_ident(R, [C | Acc]);
take_ident(Bin, Acc) ->
    {lists:reverse(Acc), Bin, length(Acc)}.

keyword(Name) -> lists:member(Name, keywords()).

keywords() ->
    ["auto","break","case","char","const","continue","default","do","double",
     "else","enum","extern","float","for","goto","if","inline","int","long",
     "register","restrict","return","short","signed","sizeof","static","struct",
     "switch","typedef","union","unsigned","void","volatile","while",
     "_Bool","_Complex","_Imaginary","_Alignas","_Alignof","_Atomic",
     "_Noreturn","_Static_assert","_Thread_local","_Generic"].

%%====================================================================
%% Numbers
%%====================================================================
number(Bin, Loc) ->
    {Str, Rest} = take_ppnumber(Bin, []),
    N = length(Str),
    Tok = case is_float_literal(Str) of
              true -> {float, parse_float(Str), Loc};
              false -> {int, parse_int(Str), Loc}
          end,
    {Tok, Rest, N}.

take_ppnumber(<<C, R/binary>>, Acc) when C >= $0, C =< $9 -> take_ppnumber(R, [C | Acc]);
take_ppnumber(<<C, R/binary>>, Acc) when C >= $a, C =< $z; C >= $A, C =< $Z -> take_ppnumber(R, [C | Acc]);
take_ppnumber(<<$_, R/binary>>, Acc) -> take_ppnumber(R, [$_ | Acc]);
take_ppnumber(<<C, R/binary>>, Acc) when C =:= $. -> take_ppnumber(R, [$. | Acc]);
take_ppnumber(<<S, R/binary>>, Acc) when S =:= $+; S =:= $- ->
    case Acc of
        [P | _] when P =:= $e; P =:= $E; P =:= $p; P =:= $P ->
            take_ppnumber(R, [S | Acc]);
        _ ->
            {lists:reverse(Acc), <<S, R/binary>>}
    end;
take_ppnumber(Bin, Acc) ->
    {lists:reverse(Acc), Bin}.

is_float_literal("0x" ++ Rest) -> has_any(Rest, "pP");
is_float_literal("0X" ++ Rest) -> has_any(Rest, "pP");
is_float_literal(Str) -> has_any(Str, ".eE").

has_any(Str, Chars) -> lists:any(fun(C) -> lists:member(C, Chars) end, Str).

parse_int(Str0) ->
    Str = strip_int_suffix(Str0),
    case Str of
        "0x" ++ D -> list_to_integer(D, 16);
        "0X" ++ D -> list_to_integer(D, 16);
        "0b" ++ D -> list_to_integer(D, 2);
        "0B" ++ D -> list_to_integer(D, 2);
        [$0] -> 0;
        [$0 | D] when D =/= [] -> list_to_integer(D, 8);
        _ -> list_to_integer(Str, 10)
    end.

strip_int_suffix(Str) ->
    lists:reverse(strip_isuffix(lists:reverse(Str))).

strip_isuffix([C | R]) when C =:= $u; C =:= $U; C =:= $l; C =:= $L ->
    strip_isuffix(R);
strip_isuffix(L) -> L.

parse_float(Str0) ->
    Str1 = strip_fsuffix(Str0),
    Str2 = ensure_float(Str1),
    try list_to_float(Str2)
    catch error:badarg -> 0.0
    end.

strip_fsuffix(Str) ->
    case lists:reverse(Str) of
        [C | R] when C =:= $f; C =:= $F; C =:= $l; C =:= $L ->
            lists:reverse(R);
        _ -> Str
    end.

ensure_float(Str) ->
    S = case Str of
            [$. | _] -> [$0 | Str];
            _ -> Str
        end,
    case lists:member($., S) of
        true ->
            case lists:last(S) of
                $. -> S ++ "0";
                _ -> S
            end;
        false ->
            insert_dot_before_exp(S)
    end.

insert_dot_before_exp(S) ->
    insert_dot(S, []).
insert_dot([C | R], Acc) when C =:= $e; C =:= $E ->
    lists:reverse(Acc) ++ ".0" ++ [C | R];
insert_dot([C | R], Acc) -> insert_dot(R, [C | Acc]);
insert_dot([], Acc) -> lists:reverse(Acc) ++ ".0".

%%====================================================================
%% Character and string literals
%%====================================================================
string_lit(<<>>, Acc, N) -> {list_to_binary(lists:reverse(Acc)), <<>>, N};
string_lit(<<$", R/binary>>, Acc, N) -> {list_to_binary(lists:reverse(Acc)), R, N};
string_lit(<<$\\, R/binary>>, Acc, N) ->
    {Byte, R2} = escape(R),
    string_lit(R2, [Byte | Acc], N + 1 + consumed_escape(R));
string_lit(<<$\n, R/binary>>, Acc, N) ->
    %% unterminated string: stop
    {list_to_binary(lists:reverse(Acc)), <<$\n, R/binary>>, N};
string_lit(<<C, R/binary>>, Acc, N) ->
    string_lit(R, [C | Acc], N + 1).

char_lit(<<$\\, R/binary>>, _Loc) ->
    {Byte, R2} = escape(R),
    {Byte, R2, 1 + consumed_escape(R)};
char_lit(<<C, R/binary>>, _Loc) ->
    {C, R, 1};
char_lit(<<>>, _Loc) ->
    {0, <<>>, 0}.

%% number of source characters consumed by an escape (best effort for cols)
consumed_escape(Bin) -> consumed_escape(Bin, 0).
consumed_escape(<<$x, R/binary>>, _) -> 2 + hex_run(R, 0);
consumed_escape(<<C, R/binary>>, _) when C >= $0, C =< $7 ->
    1 + oct_run(R, 0);
consumed_escape(_, _) -> 1.

hex_run(<<C, R/binary>>, N) when (C >= $0 andalso C =< $9); (C >= $a andalso C =< $f); (C >= $A andalso C =< $F) ->
    hex_run(R, N + 1);
hex_run(_, N) -> N.

oct_run(<<C, R/binary>>, N) when C >= $0, C =< $7, N < 2 -> oct_run(R, N + 1);
oct_run(_, N) -> N.

escape(<<$n, R/binary>>) -> {$\n, R};
escape(<<$t, R/binary>>) -> {$\t, R};
escape(<<$r, R/binary>>) -> {$\r, R};
escape(<<$a, R/binary>>) -> {7, R};
escape(<<$b, R/binary>>) -> {8, R};
escape(<<$f, R/binary>>) -> {12, R};
escape(<<$v, R/binary>>) -> {11, R};
escape(<<$\\, R/binary>>) -> {$\\, R};
escape(<<$', R/binary>>) -> {$', R};
escape(<<$", R/binary>>) -> {$", R};
escape(<<$?, R/binary>>) -> {$?, R};
escape(<<$x, R/binary>>) ->
    {Hex, R2} = take_hex(R, []),
    case Hex of
        [] -> {$x, R};
        _ -> {list_to_integer(Hex, 16), R2}
    end;
escape(<<C, R/binary>>) when C >= $0, C =< $7 ->
    {Oct, R2} = take_oct(R, [C], 1),
    {list_to_integer(Oct, 8), R2};
escape(<<C, R/binary>>) -> {C, R};
escape(<<>>) -> {0, <<>>}.

take_hex(<<C, R/binary>>, Acc)
  when (C >= $0 andalso C =< $9); (C >= $a andalso C =< $f); (C >= $A andalso C =< $F) ->
    take_hex(R, [C | Acc]);
take_hex(Bin, Acc) -> {lists:reverse(Acc), Bin}.

take_oct(<<C, R/binary>>, Acc, N) when C >= $0, C =< $7, N < 3 ->
    take_oct(R, [C | Acc], N + 1);
take_oct(Bin, Acc, _) -> {lists:reverse(Acc), Bin}.

%%====================================================================
%% Punctuators (maximal munch)
%%====================================================================
punct(Bin, Loc, Acc) ->
    {Atom, Len, Rest} = match_punct(Bin),
    toks(Rest, bump(Loc, Len), [{punct, Atom, Loc} | Acc]).

bump({L, C}, N) -> {L, C + N}.

match_punct(<<"...", R/binary>>) -> {'...', 3, R};
match_punct(<<"<<=", R/binary>>) -> {'<<=', 3, R};
match_punct(<<">>=", R/binary>>) -> {'>>=', 3, R};
match_punct(<<"->", R/binary>>) -> {'->', 2, R};
match_punct(<<"++", R/binary>>) -> {'++', 2, R};
match_punct(<<"--", R/binary>>) -> {'--', 2, R};
match_punct(<<"<<", R/binary>>) -> {'<<', 2, R};
match_punct(<<">>", R/binary>>) -> {'>>', 2, R};
match_punct(<<"<=", R/binary>>) -> {'<=', 2, R};
match_punct(<<">=", R/binary>>) -> {'>=', 2, R};
match_punct(<<"==", R/binary>>) -> {'==', 2, R};
match_punct(<<"!=", R/binary>>) -> {'!=', 2, R};
match_punct(<<"&&", R/binary>>) -> {'&&', 2, R};
match_punct(<<"||", R/binary>>) -> {'||', 2, R};
match_punct(<<"+=", R/binary>>) -> {'+=', 2, R};
match_punct(<<"-=", R/binary>>) -> {'-=', 2, R};
match_punct(<<"*=", R/binary>>) -> {'*=', 2, R};
match_punct(<<"/=", R/binary>>) -> {'/=', 2, R};
match_punct(<<"%=", R/binary>>) -> {'%=', 2, R};
match_punct(<<"&=", R/binary>>) -> {'&=', 2, R};
match_punct(<<"|=", R/binary>>) -> {'|=', 2, R};
match_punct(<<"^=", R/binary>>) -> {'^=', 2, R};
match_punct(<<"##", R/binary>>) -> {'##', 2, R};
match_punct(<<C, R/binary>>) -> {single(C), 1, R}.

single($+) -> '+'; single($-) -> '-'; single($*) -> '*'; single($/) -> '/';
single($%) -> '%'; single($&) -> '&'; single($|) -> '|'; single($^) -> '^';
single($~) -> '~'; single($!) -> '!'; single($<) -> '<'; single($>) -> '>';
single($=) -> '='; single($() -> '('; single($)) -> ')'; single($[) -> '[';
single($]) -> ']'; single(${) -> '{'; single($}) -> '}'; single($,) -> ',';
single($;) -> ';'; single($:) -> ':'; single($?) -> '?'; single($.) -> '.';
single($#) -> '#'.
