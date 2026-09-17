%% Built-in C standard library, implemented in Erlang.
%%
%% Symbols not defined in the loaded .fc image are looked up here by name at
%% CALL time. The bundled headers in priv/include declare exactly these.
-module(fat_libc).
-include("fat_image.hrl").

-export([exists/1, call/3, builtins/0]).

builtins() ->
    ["puts", "printf", "putchar", "getchar", "exit", "abort",
     "atoi", "atol", "strtol", "abs", "labs",
     "strlen", "strcmp", "strncmp", "strcpy", "strncpy", "strcat", "strncat",
     "strchr", "strrchr", "strstr", "strdup",
     "memset", "memcpy", "memmove", "memcmp", "memchr",
     "malloc", "calloc", "realloc", "free",
     "rand", "srand",
     "isalpha", "isdigit", "isalnum", "isspace", "isupper", "islower",
     "isprint", "ispunct", "isxdigit", "toupper", "tolower",
     "sqrt", "pow", "fabs", "sin", "cos", "tan", "floor", "ceil",
     "exp", "log", "log10", "fmod"].

exists(Name) -> lists:member(Name, builtins()).

%% Returns {Value, Vm} or {halt, ExitCode, Vm}.
-spec call(string(), [term()], #vm{}) -> {term(), #vm{}} | {halt, integer(), #vm{}}.
call("puts", [Addr], Vm) ->
    S = fat_mem:read_cstr(Vm#vm.mem, Addr),
    io:put_chars([S, $\n]),
    {0, Vm};
call("putchar", [C], Vm) ->
    io:put_chars([C band 16#FF]),
    {C band 16#FF, Vm};
call("getchar", [], Vm) ->
    {getchar(), Vm};
call("printf", [FmtAddr | Args], Vm) ->
    Fmt = fat_mem:read_cstr(Vm#vm.mem, FmtAddr),
    {Out, _Rest, Vm1} = format(Fmt, Args, Vm, []),
    io:put_chars(Out),
    {iolist_size(Out), Vm1};
call("exit", [Code], Vm) ->
    {halt, Code band 16#FF, Vm};
call("abort", [], Vm) ->
    {halt, 134, Vm};
call("atoi", [Addr], Vm) ->
    {parse_int_cstr(Addr, Vm), Vm};
call("atol", [Addr], Vm) ->
    {parse_int_cstr(Addr, Vm), Vm};
call("strtol", [Addr, _EndPtr, Base], Vm) ->
    {parse_int_base_cstr(Addr, Vm, Base), Vm};
call("abs", [X], Vm) -> {abs(X), Vm};
call("labs", [X], Vm) -> {abs(X), Vm};
call("strlen", [Addr], Vm) ->
    {byte_size(fat_mem:read_cstr(Vm#vm.mem, Addr)), Vm};
call("strcmp", [A, B], Vm) ->
    {strcmp(fat_mem:read_cstr(Vm#vm.mem, A), fat_mem:read_cstr(Vm#vm.mem, B)), Vm};
call("strncmp", [A, B, N], Vm) ->
    SA = fat_mem:read_bytes(Vm#vm.mem, A, N),
    SB = fat_mem:read_bytes(Vm#vm.mem, B, N),
    {strcmp(SA, SB), Vm};
call("strcpy", [Dst, Src], Vm) ->
    S = fat_mem:read_cstr(Vm#vm.mem, Src),
    Vm1 = fat_mem:write_bytes(Vm#vm.mem, Dst, <<S/binary, 0>>),
    {Dst, Vm#vm{mem = Vm1}};
call("strncpy", [Dst, Src, N], Vm) ->
    S = fat_mem:read_cstr(Vm#vm.mem, Src),
    Bin = pad_cstr(S, N),
    Vm1 = fat_mem:write_bytes(Vm#vm.mem, Dst, Bin),
    {Dst, Vm#vm{mem = Vm1}};
call("strcat", [Dst, Src], Vm) ->
    D = fat_mem:read_cstr(Vm#vm.mem, Dst),
    S = fat_mem:read_cstr(Vm#vm.mem, Src),
    Vm1 = fat_mem:write_bytes(Vm#vm.mem, Dst, <<D/binary, S/binary, 0>>),
    {Dst, Vm#vm{mem = Vm1}};
call("strncat", [Dst, Src, N], Vm) ->
    D = fat_mem:read_cstr(Vm#vm.mem, Dst),
    S0 = fat_mem:read_cstr(Vm#vm.mem, Src),
    S = case byte_size(S0) > N of true -> binary:part(S0, 0, N); false -> S0 end,
    Vm1 = fat_mem:write_bytes(Vm#vm.mem, Dst, <<D/binary, S/binary, 0>>),
    {Dst, Vm#vm{mem = Vm1}};
call("strchr", [Addr, C], Vm) ->
    {find_char(fat_mem:read_cstr(Vm#vm.mem, Addr), C band 16#FF, Addr), Vm};
call("strrchr", [Addr, C], Vm) ->
    {find_char_r(fat_mem:read_cstr(Vm#vm.mem, Addr), C band 16#FF, Addr), Vm};
call("strstr", [HAddr, NAddr], Vm) ->
    H = fat_mem:read_cstr(Vm#vm.mem, HAddr),
    N = fat_mem:read_cstr(Vm#vm.mem, NAddr),
    {find_str(H, N, HAddr), Vm};
call("strdup", [Addr], Vm) ->
    S = fat_mem:read_cstr(Vm#vm.mem, Addr),
    {P, Vm1} = alloc(Vm, byte_size(S) + 1),
    Mem2 = fat_mem:write_bytes(Vm1#vm.mem, P, <<S/binary, 0>>),
    {P, Vm1#vm{mem = Mem2}};
call("malloc", [Size], Vm) ->
    alloc(Vm, Size);
call("calloc", [N, Size], Vm) ->
    Total = N * Size,
    {P, Vm1} = alloc(Vm, Total),
    Bin = binary:copy(<<0>>, Total),
    Mem2 = fat_mem:write_bytes(Vm1#vm.mem, P, Bin),
    {P, Vm1#vm{mem = Mem2}};
call("realloc", [Ptr, Size], Vm) ->
    {NewP, Vm1} = alloc(Vm, Size),
    Old = fat_mem:read_bytes(Vm1#vm.mem, Ptr, Size),
    Mem2 = fat_mem:write_bytes(Vm1#vm.mem, NewP, Old),
    {NewP, Vm1#vm{mem = Mem2}};
call("free", [_Ptr], Vm) ->
    {0, Vm};
call("memchr", [Addr, C, N], Vm) ->
    Bin = fat_mem:read_bytes(Vm#vm.mem, Addr, N),
    {memchr(Bin, C band 16#FF, Addr), Vm};
call("memset", [Dst, C, N], Vm) ->
    Bin = binary:copy(<<(C band 16#FF)>>, N),
    Vm1 = fat_mem:write_bytes(Vm#vm.mem, Dst, Bin),
    {Dst, Vm#vm{mem = Vm1}};
call("memcpy", [Dst, Src, N], Vm) ->
    Bin = fat_mem:read_bytes(Vm#vm.mem, Src, N),
    Vm1 = fat_mem:write_bytes(Vm#vm.mem, Dst, Bin),
    {Dst, Vm#vm{mem = Vm1}};
call("memmove", [Dst, Src, N], Vm) ->
    Bin = fat_mem:read_bytes(Vm#vm.mem, Src, N),
    Vm1 = fat_mem:write_bytes(Vm#vm.mem, Dst, Bin),
    {Dst, Vm#vm{mem = Vm1}};
call("memcmp", [A, B, N], Vm) ->
    SA = fat_mem:read_bytes(Vm#vm.mem, A, N),
    SB = fat_mem:read_bytes(Vm#vm.mem, B, N),
    {strcmp(SA, SB), Vm};
call("rand", [], Vm) ->
    {rand:uniform(16#7FFFFFFF) - 1, Vm};
call("srand", [_Seed], Vm) ->
    {0, Vm};
call("isalpha", [C], Vm) -> {bool_i(is_alpha(C)), Vm};
call("isdigit", [C], Vm) -> {bool_i(C >= $0 andalso C =< $9), Vm};
call("isalnum", [C], Vm) -> {bool_i(is_alpha(C) orelse (C >= $0 andalso C =< $9)), Vm};
call("isspace", [C], Vm) -> {bool_i(lists:member(C, [32, 9, 10, 11, 12, 13])), Vm};
call("isupper", [C], Vm) -> {bool_i(C >= $A andalso C =< $Z), Vm};
call("islower", [C], Vm) -> {bool_i(C >= $a andalso C =< $z), Vm};
call("isprint", [C], Vm) -> {bool_i(C >= 32 andalso C < 127), Vm};
call("ispunct", [C], Vm) -> {bool_i(C >= 33 andalso C =< 126 andalso not is_alpha(C) andalso not (C >= $0 andalso C =< $9)), Vm};
call("isxdigit", [C], Vm) -> {bool_i(is_hex(C)), Vm};
call("toupper", [C], Vm) -> {if C >= $a andalso C =< $z -> C - 32; true -> C end, Vm};
call("tolower", [C], Vm) -> {if C >= $A andalso C =< $Z -> C + 32; true -> C end, Vm};
call("sqrt", [X], Vm) -> {math:sqrt(f(X)), Vm};
call("pow", [X, Y], Vm) -> {math:pow(f(X), f(Y)), Vm};
call("fabs", [X], Vm) -> {abs(f(X)), Vm};
call("sin", [X], Vm) -> {math:sin(f(X)), Vm};
call("cos", [X], Vm) -> {math:cos(f(X)), Vm};
call("tan", [X], Vm) -> {math:tan(f(X)), Vm};
call("floor", [X], Vm) -> {math:floor(f(X)), Vm};
call("ceil", [X], Vm) -> {math:ceil(f(X)), Vm};
call("exp", [X], Vm) -> {math:exp(f(X)), Vm};
call("log", [X], Vm) -> {math:log(f(X)), Vm};
call("log10", [X], Vm) -> {math:log10(f(X)), Vm};
call("fmod", [X, Y], Vm) -> {math:fmod(f(X), f(Y)), Vm};
call(Name, _Args, _Vm) ->
    error({unimplemented_builtin, Name}).

%%====================================================================
%% helpers
%%====================================================================
getchar() ->
    case io:get_chars(standard_io, "", 1) of
        eof -> -1;
        [C] -> C;
        _ -> -1
    end.

parse_int_cstr(Addr, Vm) ->
    S = binary_to_list(fat_mem:read_cstr(Vm#vm.mem, Addr)),
    parse_int(S).

parse_int_base_cstr(Addr, Vm, Base) ->
    S = string:trim(binary_to_list(fat_mem:read_cstr(Vm#vm.mem, Addr)), leading),
    {Sgn, S1} = case S of
                    [$- | R] -> {-1, R};
                    [$+ | R] -> {1, R};
                    _ -> {1, S}
                end,
    Digits = lists:takewhile(
               fun(C) -> digit_val(C) >= 0 andalso digit_val(C) < Base end, S1),
    case Digits of
        [] -> 0;
        _ -> Sgn * list_to_integer(Digits, Base)
    end.

digit_val(C) when C >= $0, C =< $9 -> C - $0;
digit_val(C) when C >= $a, C =< $z -> C - $a + 10;
digit_val(C) when C >= $A, C =< $Z -> C - $A + 10;
digit_val(_) -> -1.

parse_int(S) ->
    S1 = string:trim(S, leading),
    {Sgn, Digits0} = case S1 of
                         [$- | R1] -> {-1, R1};
                         [$+ | R1] -> {1, R1};
                         _ -> {1, S1}
                     end,
    Digits = lists:takewhile(fun(C) -> C >= $0 andalso C =< $9 end, Digits0),
    case Digits of
        [] -> 0;
        _ -> Sgn * list_to_integer(Digits)
    end.

strcmp(A, B) ->
    AL = binary_to_list(A), BL = binary_to_list(B),
    cmp(AL, BL).
cmp([], []) -> 0;
cmp([], _) -> -1;
cmp(_, []) -> 1;
cmp([X | R1], [X | R2]) -> cmp(R1, R2);
cmp([X | _], [Y | _]) -> if X < Y -> -1; true -> 1 end.

f(X) when is_float(X) -> X;
f(X) when is_integer(X) -> float(X).

bool_i(true) -> 1;
bool_i(false) -> 0.

is_alpha(C) -> (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z).
is_hex(C) ->
    (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f)
        orelse (C >= $A andalso C =< $F).

alloc(Vm, Size) ->
    Addr = (Vm#vm.heap_top + 7) band (bnot 7),
    {Addr, Vm#vm{heap_top = Addr + max(Size, 1)}}.

pad_cstr(S, N) ->
    case byte_size(S) >= N of
        true -> binary:part(S, 0, N);
        false -> <<S/binary, 0:((N - byte_size(S)) * 8)>>
    end.

find_char(<<>>, _C, _Addr) -> 0;
find_char(<<C, _/binary>>, C, Addr) -> Addr;
find_char(<<0, _/binary>>, _C, _Addr) -> 0;
find_char(<<_, R/binary>>, C, Addr) -> find_char(R, C, Addr + 1).

find_char_r(Bin, C, Base) ->
    find_char_r(binary_to_list(Bin), C, Base, 0, 0).
find_char_r([], _C, _Base, _Off, Last) -> Last;
find_char_r([0 | _], _C, _Base, _Off, Last) -> Last;
find_char_r([C | R], C, Base, Off, _Last) -> find_char_r(R, C, Base, Off + 1, Base + Off);
find_char_r([_ | R], C, Base, Off, Last) -> find_char_r(R, C, Base, Off + 1, Last).

find_str(_H, <<>>, Addr) -> Addr;
find_str(H, N, Addr) ->
    HL = binary_to_list(H), NL = binary_to_list(N),
    case starts_with(HL, NL) of
        true -> Addr;
        false ->
            case HL of
                [] -> 0;
                [_ | Rest] -> find_str(list_to_binary(Rest), list_to_binary(NL), Addr + 1)
            end
    end.

starts_with(_, []) -> true;
starts_with([X | R1], [X | R2]) -> starts_with(R1, R2);
starts_with(_, _) -> false.

memchr(Bin, C, Addr) ->
    memchr_list(binary_to_list(Bin), C, Addr).
memchr_list([], _C, _Addr) -> 0;
memchr_list([C | _], C, Addr) -> Addr;
memchr_list([_ | R], C, Addr) -> memchr_list(R, C, Addr + 1).

%%====================================================================
%% printf formatting
%%====================================================================
format(<<>>, Args, Vm, Acc) ->
    {lists:reverse(Acc), Args, Vm};
format(<<"%%", R/binary>>, Args, Vm, Acc) ->
    format(R, Args, Vm, ["%" | Acc]);
format(<<$%, R/binary>>, Args, Vm, Acc) ->
    {Conv, Mods, R1} = take_conv(R, []),
    case Args of
        [A | As] ->
            Str = apply_conv(Conv, Mods, A, Vm),
            format(R1, As, Vm, [Str | Acc]);
        [] ->
            {lists:reverse(Acc), [], Vm}
    end;
format(<<C, R/binary>>, Args, Vm, Acc) ->
    format(R, Args, Vm, [C | Acc]).

take_conv(<<C, R/binary>>, Mods) ->
    case is_conv(C) of
        true -> {C, lists:reverse(Mods), R};
        false -> take_conv(R, [C | Mods])
    end.

is_conv(C) -> lists:member(C, "diouxXcspfeEgGaA").

apply_conv($d, Mods, A, _Vm) -> pad(integer_to_list(trunc(A)), Mods);
apply_conv($i, Mods, A, _Vm) -> pad(integer_to_list(trunc(A)), Mods);
apply_conv($u, Mods, A, _Vm) -> pad(integer_to_list(A band 16#FFFFFFFF), Mods);
apply_conv($x, Mods, A, _Vm) -> pad(io_lib:format("~.16b", [A band 16#FFFFFFFF]), Mods);
apply_conv($X, Mods, A, _Vm) ->
    pad(string:uppercase(io_lib:format("~.16b", [A band 16#FFFFFFFF])), Mods);
apply_conv($o, Mods, A, _Vm) -> pad(io_lib:format("~.8b", [A band 16#FFFFFFFF]), Mods);
apply_conv($c, _Mods, A, _Vm) -> [A band 16#FF];
apply_conv($s, Mods, Addr, Vm) ->
    case Addr of
        0 -> pad("(null)", Mods);
        _ -> pad(fat_mem:read_cstr(Vm#vm.mem, Addr), Mods)
    end;
apply_conv($p, _Mods, Addr, _Vm) ->
    io_lib:format("0x~.16b", [Addr]);
apply_conv($f, _Mods, A, _Vm) -> io_lib:format("~.6f", [to_float(A)]);
apply_conv($e, _Mods, A, _Vm) -> io_lib:format("~.6e", [to_float(A)]);
apply_conv($g, _Mods, A, _Vm) -> io_lib:format("~p", [to_float(A)]);
apply_conv(_C, _Mods, A, _Vm) -> io_lib:format("~p", [A]).

to_float(A) when is_float(A) -> A;
to_float(A) when is_integer(A) -> float(A).

%% Very small width/left-align support; precision and other flags ignored.
pad(Str, Mods) ->
    Width = width_of(Mods),
    Left = lists:member($-, Mods),
    Flat = to_flat_list(Str),
    Len = length(Flat),
    case Width > Len of
        false -> Flat;
        true when Left -> Flat ++ lists:duplicate(Width - Len, $\s);
        true -> lists:duplicate(Width - Len, $\s) ++ Flat
    end.

to_flat_list(B) when is_binary(B) ->
    binary_to_list(B);
to_flat_list(L) when is_list(L) ->
    lists:flatten([to_flat_list(X) || X <- L]);
to_flat_list(I) when is_integer(I) ->
    [I];
to_flat_list(Other) ->
    lists:flatten(io_lib:format("~p", [Other])).

width_of(Mods) -> width_of(Mods, 0, false).
width_of([C | R], Acc, _Seen) when C >= $0, C =< $9 ->
    width_of(R, Acc * 10 + (C - $0), true);
width_of([_ | R], Acc, Seen) -> width_of(R, Acc, Seen);
width_of([], Acc, _Seen) -> Acc.
