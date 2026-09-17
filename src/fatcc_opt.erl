%% Conservative bytecode peephole optimizer.
%%
%% Level 0: no-op. Level >= 1: constant folding, algebraic identities and
%% removal of code after an unconditional transfer. Works purely on the flat
%% instruction list produced by fatcc_gen (labels included as {label, L}).
-module(fatcc_opt).

-export([optimize/2]).

-spec optimize(list(), non_neg_integer()) -> list().
optimize(Instrs, Level) when Level >= 1 ->
    case pass(Instrs) of
        Instrs -> Instrs;
        Once -> optimize(Once, Level)
    end;
optimize(Instrs, _Level) ->
    Instrs.

pass(Instrs) ->
    dead_code(peephole(const_fold(Instrs))).

%%--------------------------------------------------------------------
%% Constant folding: [push A, push B, op] -> [push (A op B)]
%%--------------------------------------------------------------------
const_fold([{push, A}, {push, B}, Op | R]) ->
    case fold_op(Op, A, B) of
        {ok, V} -> const_fold([{push, V} | R]);
        error -> [{push, A} | const_fold([{push, B}, Op | R])]
    end;
const_fold([I | R]) ->
    [I | const_fold(R)];
const_fold([]) ->
    [].

fold_op(add, A, B) -> {ok, A + B};
fold_op(sub, A, B) -> {ok, A - B};
fold_op(mul, A, B) -> {ok, A * B};
fold_op(band_, A, B) -> {ok, A band B};
fold_op(bor_, A, B) -> {ok, A bor B};
fold_op(bxor_, A, B) -> {ok, A bxor B};
fold_op(shl, A, B) -> {ok, A bsl (B band 63)};
fold_op(shr_u, A, B) -> {ok, (A band 16#FFFFFFFFFFFFFFFF) bsr (B band 63)};
fold_op(_, _, _) -> error.

%%--------------------------------------------------------------------
%% Algebraic identities and dead push/pop pairs
%%--------------------------------------------------------------------
peephole([{push, 0}, add | R]) -> peephole(R);
peephole([{push, 0}, sub | R]) -> peephole(R);
peephole([{push, 1}, mul | R]) -> peephole(R);
peephole([{push, 0}, bor_ | R]) -> peephole(R);
peephole([{push, _}, {pop} | R]) -> peephole(R);
peephole([{dup}, {pop} | R]) -> peephole(R);
peephole([I | R]) -> [I | peephole(R)];
peephole([]) -> [].

%%--------------------------------------------------------------------
%% Remove unreachable instructions after jmp/ret until the next label
%%--------------------------------------------------------------------
dead_code([{jmp, L} | R]) -> [{jmp, L} | skip_to_label(R)];
dead_code([{ret} = X | R]) -> [X | skip_to_label(R)];
dead_code([{ret_void} = X | R]) -> [X | skip_to_label(R)];
dead_code([I | R]) -> [I | dead_code(R)];
dead_code([]) -> [].

skip_to_label([{label, _} | _] = L) -> dead_code(L);
skip_to_label([_ | R]) -> skip_to_label(R);
skip_to_label([]) -> [].
