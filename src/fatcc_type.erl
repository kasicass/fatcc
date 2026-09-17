%% C type helpers: sizes, alignment, signedness, usual arithmetic conversions.
-module(fatcc_type).
-compile({no_auto_import, [size/1, is_integer/1, is_float/1]}).

-export([size/1, align/1, is_integer/1, is_signed/1, is_unsigned/1,
         is_ptr/1, is_float/1, is_void/1, is_arith/1, is_scalar/1,
         base/1, decay/1, promote/1, usual/2, sign_of/1,
         describe/1, same/2, compatible/2]).

-type ctype() :: term().
-export_type([ctype/0]).

%%--------------------------------------------------------------------
%% Sizes (LP64)
%%--------------------------------------------------------------------
size(void)      -> 0;
size(bool)      -> 1;
size(char)      -> 1;
size(schar)     -> 1;
size(uchar)     -> 1;
size(short)     -> 2;
size(ushort)    -> 2;
size(int)       -> 4;
size(uint)      -> 4;
size(long)      -> 8;
size(ulong)     -> 8;
size(llong)     -> 8;
size(ullong)    -> 8;
size(float)     -> 4;
size(double)    -> 8;
size({ptr, _})  -> 8;
size({array, T, N}) when erlang:is_integer(N), N >= 0 -> size(T) * N;
size({array, _, _}) -> 0;
size({func, _, _, _}) -> 0;
size({struct, _, Members}) -> struct_size(Members);
size({union, _, Members}) -> union_size(Members);
size({struct, _, Members, _}) -> struct_size(Members);
size({union, _, Members, _}) -> union_size(Members);
size({struct, _}) -> 0;
size({union, _}) -> 0;
size({enum, _, _}) -> 4;
size(_) -> 8.

struct_size(Members) ->
    {Sz, _} = lists:foldl(
        fun({_Name, T, _Bit}, {Off, MaxA}) ->
            A = align(T),
            Off1 = align_up(Off, A),
            {Off1 + size(T), max(MaxA, A)}
        end, {0, 1}, Members),
    align_up(Sz, 1).

union_size([]) -> 0;
union_size(Members) ->
    lists:foldl(fun({_Name, T, _Bit}, Acc) -> max(Acc, size(T)) end, 0, Members).

align(void) -> 1;
align({array, T, _}) -> align(T);
align({struct, _, Members}) -> struct_align(Members);
align({union, _, Members}) -> struct_align(Members);
align({struct, _, Members, _}) -> struct_align(Members);
align({union, _, Members, _}) -> struct_align(Members);
align({struct, _}) -> 1;
align({union, _}) -> 1;
align({func, _, _, _}) -> 1;
align(T) -> min(max(size(T), 1), 8).

struct_align([]) -> 1;
struct_align(Members) ->
    lists:foldl(fun({_N, T, _B}, Acc) -> max(Acc, align(T)) end, 1, Members).

align_up(N, A) ->
    case A of
        0 -> N;
        _ -> ((N + A - 1) div A) * A
    end.

%%--------------------------------------------------------------------
%% Classification
%%--------------------------------------------------------------------
is_integer(T) ->
    lists:member(T, [bool, char, schar, uchar, short, ushort, int, uint,
                     long, ulong, llong, ullong, {enum, '_', 0}]) orelse
    is_enum(T).

is_enum({enum, _, _}) -> true;
is_enum(_) -> false.

is_signed(T) ->
    lists:member(T, [schar, char, short, int, long, llong]) orelse is_enum(T).

is_unsigned(T) -> is_integer(T) andalso not is_signed(T).

is_ptr({ptr, _}) -> true;
is_ptr({array, _, _}) -> true;
is_ptr(_) -> false.

is_float(float) -> true;
is_float(double) -> true;
is_float(_) -> false.

is_void(void) -> true;
is_void(_) -> false.

is_arith(T) -> is_integer(T) orelse is_float(T).

is_scalar(T) -> is_arith(T) orelse is_ptr(T).

base({ptr, T}) -> T;
base({array, T, _}) -> T;
base(T) -> T.

%% Array and function types decay to pointers in expressions.
decay({array, T, _}) -> {ptr, T};
decay({func, Ret, Params, Var}) -> {ptr, {func, Ret, Params, Var}};
decay(T) -> T.

%% Integer promotion (C11 6.3.1.1).
promote(T) ->
    case is_integer(T) of
        true ->
            case rank(T) < rank(int) of
                true -> int;
                false -> T
            end;
        false -> T
    end.

rank(bool) -> 0;
rank(char) -> 1; rank(schar) -> 1; rank(uchar) -> 1;
rank(short) -> 2; rank(ushort) -> 2;
rank(int) -> 3; rank(uint) -> 3;
rank(long) -> 4; rank(ulong) -> 4;
rank(llong) -> 5; rank(ullong) -> 5;
rank({enum, _, _}) -> 3;
rank(_) -> 3.

%% Usual arithmetic conversions. Returns the common type.
usual(A0, B0) ->
    A = promote(decay(A0)),
    B = promote(decay(B0)),
    case {is_float(A), is_float(B)} of
        {true, _} -> if A =:= double -> double; B =:= double -> double; true -> A end;
        {_, true} -> double;
        _ -> usual_int(A, B)
    end.

usual_int(A, B) ->
    RA = rank(A), RB = rank(B),
    {Hi, Lo} = if RA >= RB -> {A, B}; true -> {B, A} end,
    case is_signed(Hi) of
        true ->
            case is_signed(Lo) of
                true -> Hi;
                false ->
                    %% If signed type can represent all values of unsigned type, use it.
                    case size(Hi) > size(Lo) of
                        true -> Hi;
                        false -> unsigned_of(Hi)
                    end
            end;
        false -> unsigned_of(Hi)
    end.

unsigned_of(T) ->
    case T of
        char -> uchar; schar -> uchar; uchar -> uchar;
        short -> ushort; ushort -> ushort;
        int -> uint; uint -> uint;
        long -> ulong; ulong -> ulong;
        llong -> ullong; ullong -> ullong;
        {enum, _, _} -> uint;
        _ -> T
    end.

sign_of(T) ->
    case is_float(T) of
        true -> float;
        false ->
            case is_signed(T) of
                true -> signed;
                false -> unsigned
            end
    end.

%%--------------------------------------------------------------------
%% Comparisons (structural, ignoring struct member details)
%%--------------------------------------------------------------------
same(T, T) -> true;
same({ptr, A}, {ptr, B}) -> same(A, B);
same({array, A, N}, {array, B, N}) -> same(A, B);
same({struct, N}, {struct, N}) -> true;
same({struct, N, _, _}, {struct, N, _, _}) -> true;
same({union, N}, {union, N}) -> true;
same({union, N, _, _}, {union, N, _, _}) -> true;
same(_, _) -> false.

compatible(A, B) ->
    case {decay(A), decay(B)} of
        {void, {ptr, _}} -> true;   % void* conversions handled by caller
        {{ptr, _}, void} -> true;
        {X, X} -> true;
        {X, Y} -> same(X, Y)
    end.

%%--------------------------------------------------------------------
%% Pretty printing (diagnostics / listings)
%%--------------------------------------------------------------------
describe(void) -> "void";
describe(bool) -> "_Bool";
describe(char) -> "char";
describe(schar) -> "signed char";
describe(uchar) -> "unsigned char";
describe(short) -> "short";
describe(ushort) -> "unsigned short";
describe(int) -> "int";
describe(uint) -> "unsigned int";
describe(long) -> "long";
describe(ulong) -> "unsigned long";
describe(llong) -> "long long";
describe(ullong) -> "unsigned long long";
describe(float) -> "float";
describe(double) -> "double";
describe({ptr, T}) -> describe(T) ++ " *";
describe({array, T, N}) when erlang:is_integer(N) ->
    describe(T) ++ "[" ++ integer_to_list(N) ++ "]";
describe({array, T, _}) -> describe(T) ++ "[]";
describe({func, R, P, Var}) ->
    Ps = string:join([describe(X) || X <- P], ", "),
    Tail = case Var of true -> ", ..."; false -> "" end,
    describe(R) ++ " (" ++ Ps ++ Tail ++ ")";
describe({struct, N}) -> "struct " ++ to_str(N);
describe({struct, N, _, _}) -> "struct " ++ to_str(N);
describe({union, N}) -> "union " ++ to_str(N);
describe({union, N, _, _}) -> "union " ++ to_str(N);
describe({enum, N, _}) -> "enum " ++ to_str(N);
describe(Other) -> lists:flatten(io_lib:format("~p", [Other])).

to_str(N) when is_atom(N) -> atom_to_list(N);
to_str(N) when is_list(N) -> N;
to_str(N) -> lists:flatten(io_lib:format("~p", [N])).
