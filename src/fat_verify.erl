%% Bytecode verifier: checks jump targets and operand-stack depth consistency
%% before execution. Runs once at load time.
-module(fat_verify).
-include("fat_image.hrl").

-export([verify/1]).

-spec verify(#image{}) -> ok | {error, term()}.
verify(#image{funcs = Funcs}) ->
    try
        maps:foreach(fun(_Name, F) -> verify_func(F) end, Funcs),
        ok
    catch
        throw:{verify_error, Reason} -> {error, Reason}
    end.

verify_func(#func{name = Name, code = Code} = F) ->
    N = tuple_size(Code),
    check_targets(Code, N, Name),
    NArgs = F#func.n_fixed,
    Seen = verify_loop([{1, 0}], #{}, Code, N, Name),
    _ = Seen,
    _ = NArgs,
    ok.

check_targets(Code, N, Name) ->
    lists:foreach(
      fun(Pc) ->
          case element(Pc, Code) of
              {jmp, T} -> check_target(T, N, Name, Pc);
              {jz, T} -> check_target(T, N, Name, Pc);
              {jnz, T} -> check_target(T, N, Name, Pc);
              _ -> ok
          end
      end, lists:seq(1, N)).

check_target(T, N, _Name, _Pc) when is_integer(T), T >= 1, T =< N -> ok;
check_target(T, _N, Name, Pc) ->
    throw({verify_error, {bad_jump_target, Name, Pc, T}}).

verify_loop([], Seen, _Code, _N, _Name) ->
    Seen;
verify_loop([{Pc, D} | Work], Seen, Code, N, Name) ->
    case maps:find(Pc, Seen) of
        {ok, D} ->
            verify_loop(Work, Seen, Code, N, Name);
        {ok, Other} ->
            throw({verify_error, {inconsistent_stack, Name, Pc, D, Other}});
        error ->
            case step(Pc, D, Code, N, Name) of
                {'end', _} ->
                    verify_loop(Work, maps:put(Pc, D, Seen), Code, N, Name);
                {next, Succ} ->
                    verify_loop(Succ ++ Work, maps:put(Pc, D, Seen), Code, N, Name)
            end
    end.

%% Returns {'end', []} for terminating instructions or {next, [{Pc,Depth}]}.
step(Pc, D, Code, _N, _Name) when Pc > tuple_size(Code) ->
    throw({verify_error, {fell_off_end, _Name, Pc, D}});
step(Pc, D, Code, _N, Name) ->
    I = element(Pc, Code),
    case I of
        {jmp, T} ->
            {next, [{T, D}]};
        {jz, T} ->
            require(D >= 1, Name, Pc, I, D),
            {next, [{T, D - 1}, {Pc + 1, D - 1}]};
        {jnz, T} ->
            require(D >= 1, Name, Pc, I, D),
            {next, [{T, D - 1}, {Pc + 1, D - 1}]};
        {ret} ->
            require(D >= 1, Name, Pc, I, D),
            {'end', []};
        {ret_void} ->
            {'end', []};
        _ ->
            Delta = effect(I),
            D1 = D + Delta,
            require(D1 >= 0, Name, Pc, I, D),
            {next, [{Pc + 1, D1}]}
    end.

require(true, _Name, _Pc, _I, _D) -> ok;
require(false, Name, Pc, I, D) ->
    throw({verify_error, {stack_underflow, Name, Pc, I, D}}).

%% Operand-stack delta for non-branching instructions.
effect({push, _}) -> 1;
effect({push_f, _}) -> 1;
effect({push_str, _}) -> 1;
effect({push_func, _}) -> 1;
effect({push_global_addr, _}) -> 1;
effect({pop}) -> -1;
effect({dup}) -> 1;
effect({swap}) -> 0;
effect({load_local, _, _, _}) -> 1;
effect({store_local, _, _}) -> -1;
effect({store_bytes_local, _, _}) -> 0;
effect({lea_local, _}) -> 1;
effect({load, _, _}) -> 0;
effect({load_off, _, _, _}) -> 0;
effect({store, _}) -> -2;
effect({store_keep, _}) -> -1;
effect(add) -> -1;
effect(sub) -> -1;
effect(mul) -> -1;
effect(div_s) -> -1;
effect(div_u) -> -1;
effect(mod_s) -> -1;
effect(mod_u) -> -1;
effect(neg) -> 0;
effect(band_) -> -1;
effect(bor_) -> -1;
effect(bxor_) -> -1;
effect(bnot_) -> 0;
effect(lnot_) -> 0;
effect(shl) -> -1;
effect(shr_s) -> -1;
effect(shr_u) -> -1;
effect(eq) -> -1;
effect(ne) -> -1;
effect(lt_s) -> -1;
effect(le_s) -> -1;
effect(gt_s) -> -1;
effect(ge_s) -> -1;
effect(lt_u) -> -1;
effect(le_u) -> -1;
effect(gt_u) -> -1;
effect(ge_u) -> -1;
effect(fadd) -> -1;
effect(fsub) -> -1;
effect(fmul) -> -1;
effect(fdiv) -> -1;
effect(feq) -> -1;
effect(fne) -> -1;
effect(flt) -> -1;
effect(fle) -> -1;
effect(fgt) -> -1;
effect(fge) -> -1;
effect({trunc, _}) -> 0;
effect({f2i, _}) -> 0;
effect({i2f}) -> 0;
effect({call, _, Argc}) -> 1 - Argc;
effect({call_indirect, Argc}) -> -Argc;
effect(_) -> 0.
