%% Stack-based bytecode interpreter.
-module(fat_vm).
-include("fat_image.hrl").

-export([run/2]).

-define(MASK64, 16#FFFFFFFFFFFFFFFF).

%%====================================================================
%% Entry
%%====================================================================
run(Vm0, Args) ->
    try
        {Argc, Argv, Vm1} = build_argv(Args, Vm0),
        case maps:find(Vm1#vm.entry, Vm1#vm.funcs) of
            {ok, F} ->
                Vm2 = enter(Vm1, F, [Argc, Argv], [], {bootstrap}, 0, Vm1#vm.fp),
                loop(Vm2);
            error ->
                {error, {no_entry, Vm1#vm.entry}}
        end
    catch
        throw:{fat_fault, Reason, VmF} ->
            {error, {runtime, Reason, VmF}}
    end.

%%====================================================================
%% Main loop
%%====================================================================
loop(#vm{halted = true, exit_code = Code}) ->
    Code;
loop(Vm0) ->
    Vm = bump_step(Vm0),
    Instr = element(Vm#vm.pc, Vm#vm.code),
    case Vm#vm.trace of
        true ->
            io:format(standard_error, "pc=~w  ~p  stack=~p~n",
                      [Vm#vm.pc, Instr, lists:sublist(Vm#vm.stack, 5)]);
        false -> ok
    end,
    Vm1 = exec(Instr, Vm),
    loop(Vm1).

bump_step(#vm{max_steps = infinity} = Vm) ->
    Vm#vm{step = Vm#vm.step + 1};
bump_step(#vm{step = S, max_steps = Max} = Vm) when S < Max ->
    Vm#vm{step = S + 1};
bump_step(Vm) ->
    fault(step_limit_exceeded, Vm).

%%====================================================================
%% Instruction execution
%%====================================================================
exec({push, V}, Vm) -> bump(Vm#vm{stack = [V | Vm#vm.stack]});
exec({push_f, F}, Vm) -> bump(Vm#vm{stack = [F | Vm#vm.stack]});
exec({push_str, Idx}, Vm) ->
    Addr = maps:get(Idx, Vm#vm.strings),
    bump(Vm#vm{stack = [Addr | Vm#vm.stack]});
exec({push_func, Name}, Vm) ->
    Addr = maps:get(Name, Vm#vm.func_addrs),
    bump(Vm#vm{stack = [Addr | Vm#vm.stack]});
exec({push_global_addr, Name}, Vm) ->
    Addr = maps:get(Name, Vm#vm.globals),
    bump(Vm#vm{stack = [Addr | Vm#vm.stack]});
exec({pop}, Vm) ->
    [_ | S] = Vm#vm.stack,
    bump(Vm#vm{stack = S});
exec({dup}, Vm) ->
    [T | _] = Vm#vm.stack,
    bump(Vm#vm{stack = [T | Vm#vm.stack]});
exec({swap}, Vm) ->
    [A, B | S] = Vm#vm.stack,
    bump(Vm#vm{stack = [B, A | S]});
exec({load_local, Off, Size, Sign}, Vm) ->
    {V, _} = fat_mem:read(Vm#vm.mem, Vm#vm.fp + Off, Size, Sign),
    bump(Vm#vm{stack = [V | Vm#vm.stack]});
exec({store_local, Off, Size}, Vm) ->
    [V | S] = Vm#vm.stack,
    Mem = fat_mem:write(Vm#vm.mem, Vm#vm.fp + Off, Size, V),
    bump(Vm#vm{mem = Mem, stack = S});
exec({store_bytes_local, Off, Bin}, Vm) ->
    Mem = fat_mem:write_bytes(Vm#vm.mem, Vm#vm.fp + Off, Bin),
    bump(Vm#vm{mem = Mem});
exec({lea_local, Off}, Vm) ->
    bump(Vm#vm{stack = [Vm#vm.fp + Off | Vm#vm.stack]});
exec({load, Size, Sign}, Vm) ->
    [Addr | S] = Vm#vm.stack,
    {V, _} = fat_mem:read(Vm#vm.mem, Addr, Size, Sign),
    bump(Vm#vm{stack = [V | S]});
exec({store, Size}, Vm) ->
    [Val, Addr | S] = Vm#vm.stack,
    Mem = fat_mem:write(Vm#vm.mem, Addr, Size, Val),
    bump(Vm#vm{mem = Mem, stack = S});
exec({store_keep, Size}, Vm) ->
    [Val, Addr | S] = Vm#vm.stack,
    Mem = fat_mem:write(Vm#vm.mem, Addr, Size, Val),
    bump(Vm#vm{mem = Mem, stack = [Val | S]});
exec(add, Vm) -> b2(Vm, fun(A, B) -> A + B end);
exec(sub, Vm) -> b2(Vm, fun(A, B) -> A - B end);
exec(mul, Vm) -> b2(Vm, fun(A, B) -> A * B end);
exec(div_s, Vm) -> b2(Vm, fun(A, B) -> sdiv(A, B) end);
exec(div_u, Vm) -> b2(Vm, fun(A, B) -> udiv(A, B) end);
exec(mod_s, Vm) -> b2(Vm, fun(A, B) -> srem(A, B) end);
exec(mod_u, Vm) -> b2(Vm, fun(A, B) -> urem(A, B) end);
exec(neg, Vm) ->
    [A | S] = Vm#vm.stack,
    bump(Vm#vm{stack = [-A | S]});
exec(band_, Vm) -> b2(Vm, fun(A, B) -> A band B end);
exec(bor_, Vm) -> b2(Vm, fun(A, B) -> A bor B end);
exec(bxor_, Vm) -> b2(Vm, fun(A, B) -> A bxor B end);
exec(bnot_, Vm) ->
    [A | S] = Vm#vm.stack,
    bump(Vm#vm{stack = [bnot A | S]});
exec(lnot_, Vm) ->
    [A | S] = Vm#vm.stack,
    bump(Vm#vm{stack = [bool_int(A =:= 0) | S]});
exec(shl, Vm) -> b2(Vm, fun(A, B) -> A bsl (B band 63) end);
exec(shr_s, Vm) -> b2(Vm, fun(A, B) -> s64(A) bsr (B band 63) end);
exec(shr_u, Vm) -> b2(Vm, fun(A, B) -> (A band ?MASK64) bsr (B band 63) end);
exec(eq, Vm) -> b2(Vm, fun(A, B) -> bool_int(A =:= B) end);
exec(ne, Vm) -> b2(Vm, fun(A, B) -> bool_int(A =/= B) end);
exec(lt_s, Vm) -> b2(Vm, fun(A, B) -> bool_int(s64(A) < s64(B)) end);
exec(le_s, Vm) -> b2(Vm, fun(A, B) -> bool_int(s64(A) =< s64(B)) end);
exec(gt_s, Vm) -> b2(Vm, fun(A, B) -> bool_int(s64(A) > s64(B)) end);
exec(ge_s, Vm) -> b2(Vm, fun(A, B) -> bool_int(s64(A) >= s64(B)) end);
exec(lt_u, Vm) -> b2(Vm, fun(A, B) -> bool_int((A band ?MASK64) < (B band ?MASK64)) end);
exec(le_u, Vm) -> b2(Vm, fun(A, B) -> bool_int((A band ?MASK64) =< (B band ?MASK64)) end);
exec(gt_u, Vm) -> b2(Vm, fun(A, B) -> bool_int((A band ?MASK64) > (B band ?MASK64)) end);
exec(ge_u, Vm) -> b2(Vm, fun(A, B) -> bool_int((A band ?MASK64) >= (B band ?MASK64)) end);
exec(fadd, Vm) -> b2(Vm, fun(A, B) -> A + B end);
exec(fsub, Vm) -> b2(Vm, fun(A, B) -> A - B end);
exec(fmul, Vm) -> b2(Vm, fun(A, B) -> A * B end);
exec(fdiv, Vm) -> b2(Vm, fun(A, B) -> A / B end);
exec(feq, Vm) -> b2(Vm, fun(A, B) -> bool_int(A =:= B) end);
exec(fne, Vm) -> b2(Vm, fun(A, B) -> bool_int(A =/= B) end);
exec(flt, Vm) -> b2(Vm, fun(A, B) -> bool_int(A < B) end);
exec(fle, Vm) -> b2(Vm, fun(A, B) -> bool_int(A =< B) end);
exec(fgt, Vm) -> b2(Vm, fun(A, B) -> bool_int(A > B) end);
exec(fge, Vm) -> b2(Vm, fun(A, B) -> bool_int(A >= B) end);
exec({trunc, Size}, Vm) ->
    [A | S] = Vm#vm.stack,
    bump(Vm#vm{stack = [A band ((1 bsl (Size * 8)) - 1) | S]});
exec({f2i, Size}, Vm) ->
    [F | S] = Vm#vm.stack,
    bump(Vm#vm{stack = [trunc(F) band ((1 bsl (Size * 8)) - 1) | S]});
exec({i2f}, Vm) ->
    [A | S] = Vm#vm.stack,
    bump(Vm#vm{stack = [float(s64(A)) | S]});
exec({jmp, T}, Vm) ->
    Vm#vm{pc = T};
exec({jz, T}, Vm) ->
    [C | S] = Vm#vm.stack,
    case C of
        0 -> Vm#vm{pc = T, stack = S};
        _ -> bump(Vm#vm{stack = S})
    end;
exec({jnz, T}, Vm) ->
    [C | S] = Vm#vm.stack,
    case C of
        0 -> bump(Vm#vm{stack = S});
        _ -> Vm#vm{pc = T, stack = S}
    end;
exec({call, Name, Argc}, Vm) ->
    {Args, Rest} = pop_args(Argc, Vm#vm.stack),
    case maps:find(Name, Vm#vm.funcs) of
        {ok, F} ->
            enter(Vm, F, Args, Rest, Vm#vm.code, Vm#vm.pc + 1, Vm#vm.fp);
        error ->
            call_builtin(Name, Args, Rest, Vm)
    end;
exec({call_indirect, Argc}, Vm) ->
    {Args, Rest1} = pop_args(Argc, Vm#vm.stack),
    [FPtr | Rest] = Rest1,
    Name = case FPtr of
               {funcptr, N} -> N;
               A when is_integer(A) -> maps:get(A, Vm#vm.func_by_addr, undefined)
           end,
    case Name of
        undefined ->
            fault({bad_function_pointer, FPtr}, Vm);
        _ ->
            case maps:find(Name, Vm#vm.funcs) of
                {ok, F} -> enter(Vm, F, Args, Rest, Vm#vm.code, Vm#vm.pc + 1, Vm#vm.fp);
                error -> call_builtin(Name, Args, Rest, Vm)
            end
    end;
exec({ret}, Vm) ->
    [Val | _] = Vm#vm.stack,
    do_ret(Vm, Val);
exec({ret_void}, Vm) ->
    do_ret(Vm, novalue);
exec(Other, Vm) ->
    fault({bad_instruction, Other}, Vm).

%%====================================================================
%% Calls
%%====================================================================
enter(Vm, F, Args, RestStack, RetCode, RetPc, RetFp) ->
    FS = F#func.frame_size,
    FP = Vm#vm.sp - FS,
    Mem = write_params(Vm#vm.mem, FP, F#func.params, Args),
    Frame = #frame{
        name = F#func.name,
        fp = FP,
        frame_size = FS,
        ret_code = RetCode,
        ret_pc = RetPc,
        ret_fp = RetFp,
        ret_stack = RestStack,
        ret_type = F#func.ret_type,
        n_fixed = F#func.n_fixed,
        nactual = length(Args)
    },
    Vm#vm{code = F#func.code, pc = 1, stack = [], frames = [Frame | Vm#vm.frames],
          sp = FP, fp = FP, mem = Mem}.

write_params(Mem, _FP, [], _) -> Mem;
write_params(Mem, FP, [{_N, Type, Off} | RP], [V | RA]) ->
    Mem1 = fat_mem:write(Mem, FP + Off, fatcc_type:size(Type), V),
    write_params(Mem1, FP, RP, RA);
write_params(Mem, FP, [{_N, Type, Off} | RP], []) ->
    Mem1 = fat_mem:write(Mem, FP + Off, fatcc_type:size(Type), 0),
    write_params(Mem1, FP, RP, []).

call_builtin(Name, Args, Rest, Vm) ->
    case fat_libc:exists(Name) of
        true ->
            case fat_libc:call(Name, Args, Vm#vm{stack = Rest}) of
                {halt, Code, Vm1} ->
                    Vm1#vm{halted = true, exit_code = Code, stack = Rest};
                {Value, Vm1} ->
                    Vm1#vm{stack = [Value | Rest], pc = Vm#vm.pc + 1}
            end;
        false ->
            fault({undefined_symbol, Name}, Vm)
    end.

do_ret(Vm, Val) ->
    case Vm#vm.frames of
        [#frame{ret_code = {bootstrap}} | _] ->
            Code = case Val of
                       novalue -> 0;
                       _ -> Val band 16#FF
                   end,
            Vm#vm{halted = true, exit_code = Code};
        [Frame | Rest] ->
            Stack = case Val of
                        novalue -> Frame#frame.ret_stack;
                        _ -> [Val | Frame#frame.ret_stack]
                    end,
            Vm#vm{code = Frame#frame.ret_code,
                  pc = Frame#frame.ret_pc,
                  stack = Stack,
                  frames = Rest,
                  sp = Frame#frame.fp + Frame#frame.frame_size,
                  fp = Frame#frame.ret_fp};
        [] ->
            fault(bad_return, Vm)
    end.

%%====================================================================
%% Helpers
%%====================================================================
bump(Vm) -> Vm#vm{pc = Vm#vm.pc + 1}.

b2(Vm, F) ->
    [B, A | S] = Vm#vm.stack,
    bump(Vm#vm{stack = [F(A, B) | S]}).

bool_int(true) -> 1;
bool_int(false) -> 0.

s64(V) ->
    V1 = V band ?MASK64,
    case V1 >= (1 bsl 63) of
        true -> V1 - (1 bsl 64);
        false -> V1
    end.

sdiv(_, 0) -> error(division_by_zero);
sdiv(A, B) -> s64(A) div s64(B).

udiv(_, 0) -> error(division_by_zero);
udiv(A, B) -> (A band ?MASK64) div (B band ?MASK64).

srem(_, 0) -> error(division_by_zero);
srem(A, B) -> s64(A) rem s64(B).

urem(_, 0) -> error(division_by_zero);
urem(A, B) -> (A band ?MASK64) rem (B band ?MASK64).

pop_args(N, Stack) ->
    {Rev, Rest} = take(N, Stack),
    {lists:reverse(Rev), Rest}.

take(0, L) -> {[], L};
take(N, [H | T]) ->
    {R, Rest} = take(N - 1, T),
    {[H | R], Rest}.

fault(Reason, Vm) ->
    throw({fat_fault, Reason, Vm}).

%%====================================================================
%% argv construction
%%====================================================================
build_argv(Args, Vm0) ->
    {Mem1, Addrs, Top} = write_arg_strings(Args, Vm0#vm.mem, Vm0#vm.heap_top, []),
    Base = align8(Top),
    Mem2 = write_ptr_array(Addrs, Base, Mem1),
    Next = Base + 8 * (length(Addrs) + 1),
    {length(Addrs), Base, Vm0#vm{mem = Mem2, heap_top = Next}}.

write_arg_strings([], Mem, Top, Acc) -> {Mem, lists:reverse(Acc), Top};
write_arg_strings([S | R], Mem, Top, Acc) ->
    Bin = <<(unicode:characters_to_binary(S))/binary, 0>>,
    Mem1 = fat_mem:write_bytes(Mem, Top, Bin),
    write_arg_strings(R, Mem1, Top + byte_size(Bin), [Top | Acc]).

write_ptr_array(Addrs, Base, Mem) ->
    {Mem1, _} = lists:foldl(
        fun({I, A}, {M, _}) ->
            {fat_mem:write(M, Base + 8 * I, 8, A), 0}
        end, {Mem, 0}, lists:zip(lists:seq(0, length(Addrs) - 1), Addrs)),
    fat_mem:write(Mem1, Base + 8 * length(Addrs), 8, 0).

align8(N) -> ((N + 7) div 8) * 8.
