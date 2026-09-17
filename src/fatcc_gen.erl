%% AST -> stack bytecode code generator.
%%
%% This is deliberately a direct lowering (no separate IR yet): expressions
%% become postfix stack operations, control flow becomes labels + jumps.
-module(fatcc_gen).
-include("fat_image.hrl").

-export([gen/1, gen/2]).

-record(g, {
    funcs = #{}          :: map(),
    protos = #{}         :: map(),
    strings = #{}        :: map(),   % index -> binary
    strmap = #{}         :: map(),   % binary -> index
    strcount = 0         :: non_neg_integer(),
    globals = #{}        :: map(),
    scope = #{}          :: map(),
    frame = 0            :: non_neg_integer(),
    locals = []          :: list(),
    loops = []           :: list(),
    brks = []            :: list(),
    lbl = 0              :: non_neg_integer(),
    opt = 0              :: non_neg_integer()
}).

%%====================================================================
%% Entry
%%====================================================================
-spec gen(list()) -> {ok, #image{}}.
gen(Items) ->
    gen(Items, #{}).

-spec gen(list(), map()) -> {ok, #image{}}.
gen(Items, Opts) ->
    Protos = collect_protos(Items, #{}),
    G0 = #g{protos = Protos, opt = maps:get(opt_level, Opts, 0)},
    G1 = lists:foldl(fun gen_item/2, G0, Items),
    Strings = [maps:get(I, G1#g.strings) || I <- lists:seq(0, G1#g.strcount - 1)],
    Image = #image{
        entry = "main",
        funcs = G1#g.funcs,
        globals = G1#g.globals,
        strings = Strings
    },
    {ok, Image}.

collect_protos([{proto, R, N, P, V} | T], M) ->
    collect_protos(T, maps:put(N, {R, P, V}, M));
collect_protos([{func, R, N, P, V, _} | T], M) ->
    collect_protos(T, maps:put(N, {R, P, V}, M));
collect_protos([_ | T], M) ->
    collect_protos(T, M);
collect_protos([], M) -> M.

gen_item({proto, _, _, _, _}, G) -> G;
gen_item({global, Type, Name, Init}, G) ->
    add_global(Type, Name, Init, G);
gen_item({func, Ret, Name, Params, Var, Body}, G) ->
    gen_func(Ret, Name, Params, Var, Body, G).

%%====================================================================
%% Globals
%%====================================================================
add_global(Type, Name, Init, G0) ->
    Size = max(fatcc_type:size(Type), 1),
    {InitData, G1} = global_init(Type, Init, G0),
    Glob = #global{name = Name, type = Type, init = InitData, size = Size},
    G1#g{globals = maps:put(Name, Glob, G1#g.globals)}.

global_init(_Type, none, G) ->
    {none, G};
global_init({array, char, N}, {str, B}, G) ->
    {pad_bin(B, N), G};
global_init({array, char, undefined}, {str, B}, G) ->
    {<<B/binary, 0>>, G};
global_init({ptr, char}, {str, B}, G0) ->
    {Idx, G1} = add_string(B, G0),
    {{str_addr, Idx}, G1};
global_init({array, ElemT, N}, {init_list, Items}, G) when is_integer(N) ->
    Es = fatcc_type:size(ElemT),
    Bin = iolist_to_binary([int_bin(const_eval(I), Es) || I <- Items]),
    {pad_bin(Bin, N * Es), G};
global_init(Type, Init, G) ->
    case fatcc_type:is_integer(Type) orelse fatcc_type:is_ptr(Type) of
        true -> {int_bin(const_eval(Init), fatcc_type:size(Type)), G};
        false -> {none, G}
    end.

pad_bin(Bin, N) when byte_size(Bin) >= N -> binary:part(Bin, 0, N);
pad_bin(Bin, N) -> <<Bin/binary, 0:((N - byte_size(Bin)) * 8)>>.

int_bin(V, Size) ->
    Masked = V band ((1 bsl (Size * 8)) - 1),
    list_to_binary([(Masked bsr (8 * I)) band 16#FF || I <- lists:seq(0, Size - 1)]).

const_eval({int, V}) -> V;
const_eval({char, V}) -> V;
const_eval({un, '-', E}) -> -const_eval(E);
const_eval({un, '+', E}) -> const_eval(E);
const_eval({un, '~', E}) -> bnot const_eval(E);
const_eval({un, '!', E}) -> bool_int(const_eval(E) =:= 0);
const_eval({bin, Op, A, B}) ->
    eval_bin(Op, const_eval(A), const_eval(B));
const_eval({cast, _, E}) -> const_eval(E);
const_eval({sizeof_type, T}) -> fatcc_type:size(T);
const_eval(Other) -> error({non_constant_initializer, Other}).

eval_bin('+', A, B) -> A + B;
eval_bin('-', A, B) -> A - B;
eval_bin('*', A, B) -> A * B;
eval_bin('/', A, B) -> A div B;
eval_bin('%', A, B) -> A rem B;
eval_bin('&', A, B) -> A band B;
eval_bin('|', A, B) -> A bor B;
eval_bin('^', A, B) -> A bxor B;
eval_bin('<<', A, B) -> A bsl B;
eval_bin('>>', A, B) -> A bsr B;
eval_bin('==', A, B) -> bool_int(A =:= B);
eval_bin('!=', A, B) -> bool_int(A =/= B);
eval_bin('<', A, B) -> bool_int(A < B);
eval_bin('<=', A, B) -> bool_int(A =< B);
eval_bin('>', A, B) -> bool_int(A > B);
eval_bin('>=', A, B) -> bool_int(A >= B);
eval_bin('&&', A, B) -> bool_int(A =/= 0 andalso B =/= 0);
eval_bin('||', A, B) -> bool_int(A =/= 0 orelse B =/= 0).

bool_int(true) -> 1;
bool_int(false) -> 0.

%%====================================================================
%% Functions
%%====================================================================
gen_func(Ret, Name, Params, Var, Body, G0) ->
    {ParamEntries, NextOff} = assign_params(Params, G0),
    Scope = maps:from_list([{N, {T, Off}} || {N, T, Off} <- ParamEntries]),
    G2 = init_frame(G0, NextOff, Scope),
    {Instrs, _T, G3} = gen_stmt(Body, G2),
    All = fatcc_opt:optimize(Instrs ++ default_ret(Ret), G0#g.opt),
    {Code, _Labels} = fatcc_asm:assemble(All),
    Func = #func{
        name = Name,
        ret_type = Ret,
        params = [{N, T, Off} || {N, T, Off} <- ParamEntries],
        n_fixed = length(ParamEntries),
        variadic = Var,
        frame_size = G3#g.frame,
        code = Code,
        locals = G3#g.locals
    },
    G3#g{funcs = maps:put(Name, Func, G3#g.funcs),
         scope = #{}, frame = 0, locals = [], loops = []}.

assign_params(Params, _G) ->
    lists:mapfoldl(
      fun({Type0, Name}, Off) ->
          Type = fatcc_type:decay(Type0),
          Sz = slot_size(Type),
          {{Name, Type, Off}, Off + Sz}
      end, 0, Params).

init_frame(G, NextOff, Scope) ->
    G#g{scope = Scope, frame = NextOff, locals = [], loops = []}.

slot_size(Type) ->
    Sz = fatcc_type:size(Type),
    A = max(fatcc_type:align(Type), 1),
    align_up(max(Sz, 1), max(A, 8)).

%% A `char s[] = "..."` / `int a[] = {...}` declaration gets its size from
%% the initializer.
resolve_array_type({array, T, undefined}, {str, B}) ->
    {array, T, byte_size(B) + 1};
resolve_array_type({array, T, undefined}, {init_list, Items}) ->
    {array, T, length(Items)};
resolve_array_type(Type, _Init) -> Type.

align_up(N, A) when A =< 1 -> N;
align_up(N, A) -> ((N + A - 1) div A) * A.

default_ret(void) -> [{ret_void}];
default_ret(_) -> [{push, 0}, {ret}].

%%====================================================================
%% Statements
%%====================================================================
gen_stmt({block, Stmts}, G) ->
    lists:foldl(
      fun(Stmt, {Instrs, _T, Gx}) ->
          {I, T, Gy} = gen_stmt(Stmt, Gx),
          {Instrs ++ I, T, Gy}
      end, {[], void, G}, Stmts);
gen_stmt({var, Type0, Name, Init}, G0) ->
    Type = resolve_array_type(Type0, Init),
    {Off, G1} = alloc_local(Name, Type, G0),
    case Init of
        none -> {[], void, G1};
        {str, B} when is_tuple(Type), element(1, Type) =:= array ->
            {[{store_bytes_local, Off, pad_bin(B, fatcc_type:size(Type))}], void, G1};
        {init_list, Items} ->
            case is_struct_type(Type) of
                true -> gen_struct_init(Type, Off, Items, G1);
                false -> gen_array_init(Type, Off, Items, G1)
            end;
        _ ->
            {I, _T, G2} = gen_expr(Init, G1),
            {I ++ [{store_local, Off, fatcc_type:size(Type)}], void, G2}
    end;
gen_stmt({expr, E}, G0) ->
    {I, T, G1} = gen_expr(E, G0),
    I1 = case T of
             void -> I;
             _ -> I ++ [{pop}]
         end,
    {I1, void, G1};
gen_stmt({ret, none}, G) ->
    {[{ret_void}], void, G};
gen_stmt({ret, E}, G0) ->
    {I, _T, G1} = gen_expr(E, G0),
    {I ++ [{ret}], void, G1};
gen_stmt({'if', C, ThenS, ElseS}, G0) ->
    {LElse, G1} = fresh(G0),
    {LEnd, G2} = fresh(G1),
    {IC, _T, G3} = gen_expr(C, G2),
    {IT, _T2, G4} = gen_stmt(ThenS, G3),
    {IE, _T3, G5} = gen_stmt(ElseS, G4),
    {IC ++ [{jz, LElse}] ++ IT ++ [{jmp, LEnd}, {label, LElse}] ++ IE ++ [{label, LEnd}],
     void, G5};
gen_stmt({while, C, Body}, G0) ->
    {Lcond, G1} = fresh(G0),
    {Lend, G2} = fresh(G1),
    {IC, _T, G3} = gen_expr(C, G2),
    {IB, _T2, G4} = gen_loop_body(Body, Lend, Lcond, G3),
    {[{label, Lcond}] ++ IC ++ [{jz, Lend}] ++ IB ++ [{jmp, Lcond}, {label, Lend}],
     void, G4};
gen_stmt({do, Body, C}, G0) ->
    {Lbody, G1} = fresh(G0),
    {Lcond, G2} = fresh(G1),
    {Lend, G3} = fresh(G2),
    {IB, _T, G4} = gen_loop_body(Body, Lend, Lcond, G3),
    {IC, _T2, G5} = gen_expr(C, G4),
    {[{label, Lbody}] ++ IB ++ [{label, Lcond}] ++ IC ++ [{jnz, Lbody}, {label, Lend}],
     void, G5};
gen_stmt({for, Init, Cond, Step, Body}, G0) ->
    {II, G1} = gen_for_init(Init, G0),
    {Lcond, G2} = fresh(G1),
    {Lstep, G3} = fresh(G2),
    {Lend, G4} = fresh(G3),
    {IC, _T, G5} = case Cond of
                       none -> {[], void, G4};
                       _ -> gen_expr(Cond, G4)
                   end,
    {IB, _T2, G6} = gen_loop_body(Body, Lend, Lstep, G5),
    {IS0, StepT, G7} = case Step of
                            none -> {[], void, G6};
                            _ -> gen_expr(Step, G6)
                        end,
    IS = case StepT of
             void -> IS0;
             _ -> IS0 ++ [{pop}]
         end,
    CondCode = case Cond of
                   none -> [];
                   _ -> IC ++ [{jz, Lend}]
               end,
    {II ++ [{label, Lcond}] ++ CondCode ++ IB ++ [{label, Lstep}] ++ IS ++
     [{jmp, Lcond}, {label, Lend}], void, G7};
gen_stmt({break}, G) ->
    case G#g.brks of
        [Break | _] -> {[{jmp, Break}], void, G};
        [] -> error({break_outside_loop})
    end;
gen_stmt({continue}, G) ->
    case G#g.loops of
        [{_, Cont} | _] -> {[{jmp, Cont}], void, G};
        [] -> error({continue_outside_loop})
    end;
gen_stmt({goto, Label}, G) ->
    {[{jmp, {name, "C_" ++ Label}}], void, G};
gen_stmt({label, Name, Body}, G0) ->
    {I, T, G1} = gen_stmt(Body, G0),
    {[{label, {name, "C_" ++ Name}}] ++ I, T, G1};
gen_stmt({switch, E, Body}, G0) ->
    {LEnd, G1} = fresh(G0),
    {TmpOff, G2} = alloc_temp(int, G1),
    {IE, _T, G3} = gen_expr(E, G2),
    Items = flatten_block(Body),
    Flat = flatten_switch(Items),
    {Cases, CaseMap, G4} = collect_cases(Flat, G3),
    Dispatch = lists:append(
        [[{load_local, TmpOff, 4, signed}, {push, V}, eq, {jnz, L}]
         || {V, L} <- lists:reverse(Cases)]),
    DefaultJmp = case maps:find(default, CaseMap) of
                     {ok, LD} -> [{jmp, LD}];
                     error -> []
                 end,
    {IBody, G5} = gen_switch_body(Flat, CaseMap, LEnd, G4),
    {IE ++ [{store_local, TmpOff, 4}] ++ Dispatch ++ DefaultJmp ++ IBody ++ [{label, LEnd}],
     void, G5};
gen_stmt({'case', _V, _Body}, _G) ->
    error(case_outside_switch);
gen_stmt({default, _Body}, _G) ->
    error(default_outside_switch).

flatten_block({block, Items}) -> Items;
flatten_block(S) -> [S].

%% Turn consecutive/nested case labels into a flat stream.
flatten_switch(Items) -> lists:reverse(flatten_switch(Items, [])).
flatten_switch([], Acc) -> Acc;
flatten_switch([{'case', V, S} | R], Acc) ->
    flatten_switch([S | R], [{'case', V} | Acc]);
flatten_switch([{default, S} | R], Acc) ->
    flatten_switch([S | R], [default | Acc]);
flatten_switch([S | R], Acc) ->
    flatten_switch(R, [{stmt, S} | Acc]).

collect_cases(Flat, G0) ->
    lists:foldl(
      fun({'case', V}, {Cases, Map, G}) ->
              Val = const_eval(V),
              {L, G1} = fresh_label(G, "case"),
              {[{Val, L} | Cases], maps:put(Val, L, Map), G1};
         (default, {Cases, Map, G}) ->
              {L, G1} = fresh_label(G, "default"),
              {Cases, maps:put(default, L, Map), G1};
         (_, Acc) -> Acc
      end, {[], #{}, G0}, Flat).

gen_switch_body([], _Map, _LEnd, G) ->
    {[], G};
gen_switch_body([{'case', V} | R], Map, LEnd, G0) ->
    L = maps:get(const_eval(V), Map),
    {I2, G1} = gen_switch_body(R, Map, LEnd, G0),
    {[{label, L}] ++ I2, G1};
gen_switch_body([default | R], Map, LEnd, G0) ->
    L = maps:get(default, Map),
    {I2, G1} = gen_switch_body(R, Map, LEnd, G0),
    {[{label, L}] ++ I2, G1};
gen_switch_body([{stmt, S} | R], Map, LEnd, G0) ->
    {I, _T, G1} = gen_stmt(S, G0#g{brks = [LEnd | G0#g.brks]}),
    {I2, G2} = gen_switch_body(R, Map, LEnd, G1),
    {I ++ I2, G2}.

alloc_temp(Type, G) ->
    Off = G#g.frame,
    Sz = slot_size(Type),
    {Off, G#g{frame = Off + Sz}}.

fresh_label(G, Prefix) ->
    N = G#g.lbl,
    {[Prefix, "_", integer_to_list(N)], G#g{lbl = N + 1}}.

gen_loop_body(Body, Break, Cont, G) ->
    gen_stmt(Body, G#g{loops = [{Break, Cont} | G#g.loops],
                       brks = [Break | G#g.brks]}).

gen_for_init(none, G) -> {[], G};
gen_for_init({decls, Decls}, G) ->
    lists:foldl(
      fun(D, {I, Gx}) -> {I2, _, Gy} = gen_stmt(D, Gx), {I ++ I2, Gy} end,
      {[], G}, Decls);
gen_for_init({expr, E}, G0) ->
    {I, _T, G1} = gen_expr(E, G0),
    {I ++ [{pop}], G1}.

gen_array_init(_Type, _Off, [], G) ->
    {[], void, G};
gen_array_init(Type, Off, [First | Rest], G0) ->
    ElemT = case Type of
                {array, T, _} -> T;
                _ -> Type
            end,
    ES = max(fatcc_type:size(ElemT), 1),
    {I0, _T, G1} = gen_expr(First, G0),
    More = gen_array_rest(Rest, Off + ES, ES, G1, []),
    {I0 ++ [{store_local, Off, ES}] ++ More, void, G1}.

gen_array_rest([], _Off, _ES, G, Acc) ->
    _ = G, lists:append(lists:reverse(Acc));
gen_array_rest([E | R], Off, ES, G, Acc) ->
    {I, _T, _} = gen_expr(E, G),
    gen_array_rest(R, Off + ES, ES, G, [I ++ [{store_local, Off, ES}] | Acc]).

is_struct_type({struct, _, _}) -> true;
is_struct_type({struct, _, _, _}) -> true;
is_struct_type({union, _, _}) -> true;
is_struct_type({union, _, _, _}) -> true;
is_struct_type(_) -> false.

gen_struct_init(Type, Off, Items, G) ->
    Members = struct_members(Type),
    gen_struct_fields(zip(Items, Members), Type, Off, G, []).

gen_struct_fields([], _Type, _Off, _G, Acc) ->
    {lists:append(lists:reverse(Acc)), void, _G};
gen_struct_fields([{Item, {MName, MType, _Bits}} | R], Type, Off, G, Acc) ->
    FOff = Off + field_offset(Type, struct_members(Type), MName),
    I = case {Item, is_struct_type(MType)} of
            {{init_list, Sub}, true} ->
                {IS, _, _} = gen_struct_init(MType, FOff, Sub, G),
                IS;
            {{init_list, Sub}, false} ->
                {IS, _, _} = gen_array_init(MType, FOff, Sub, G),
                IS;
            _ ->
                {IE, _T, _} = gen_expr(Item, G),
                IE ++ [{store_local, FOff, max(fatcc_type:size(MType), 1)}]
        end,
    gen_struct_fields(R, Type, Off, G, [I | Acc]).

zip([], _) -> [];
zip(_, []) -> [];
zip([A | As], [B | Bs]) -> [{A, B} | zip(As, Bs)].

%%====================================================================
%% Local allocation
%%====================================================================
alloc_local(Name, Type, G) ->
    Off = G#g.frame,
    Sz = slot_size(Type),
    G1 = G#g{frame = Off + Sz,
             scope = maps:put(Name, {Type, Off}, G#g.scope),
             locals = G#g.locals ++ [{Name, Type, Off}]},
    {Off, G1}.

%%====================================================================
%% Expressions
%%====================================================================
gen_expr({int, V}, G) -> {[{push, V}], int, G};
gen_expr({char, V}, G) -> {[{push, V}], int, G};
gen_expr({float, F}, G) -> {[{push_f, F}], double, G};
gen_expr({str, B}, G0) ->
    {Idx, G1} = add_string(B, G0),
    {[{push_str, Idx}], {ptr, char}, G1};
gen_expr({id, Name}, G) ->
    case maps:find(Name, G#g.scope) of
        {ok, {Type, Off}} ->
            case is_array_or_func(Type) of
                true ->
                    {[{lea_local, Off}], {ptr, fatcc_type:base(Type)}, G};
                false ->
                    {[{load_local, Off, fatcc_type:size(Type), fatcc_type:sign_of(Type)}], Type, G}
            end;
        error ->
            case maps:find(Name, G#g.protos) of
                {ok, {Ret, P, V}} ->
                    {[{push_func, Name}], {ptr, {func, Ret, P, V}}, G};
                error ->
                    case maps:find(Name, G#g.globals) of
                        {ok, #global{type = Type}} ->
                            case is_array_or_func(Type) of
                                true ->
                                    {[{push_global_addr, Name}], {ptr, fatcc_type:base(Type)}, G};
                                false ->
                                    {[{push_global_addr, Name},
                                      {load, fatcc_type:size(Type), fatcc_type:sign_of(Type)}],
                                     Type, G}
                            end;
                        error ->
                            error({undefined, Name})
                    end
            end
    end;
gen_expr({bin, Op, L, R}, G) when Op =:= '&&'; Op =:= '||' ->
    {Lfalse, G1} = fresh(G),
    {Lend, G2} = fresh(G1),
    {IL, _TL, G3} = gen_expr(L, G2),
    {IR, _TR, G4} = gen_expr(R, G3),
    I = case Op of
            '&&' ->
                IL ++ [{jz, Lfalse}] ++ IR ++
                [{jz, Lfalse}, {push, 1}, {jmp, Lend},
                 {label, Lfalse}, {push, 0}, {label, Lend}];
            '||' ->
                IL ++ [{jnz, Lfalse}] ++ IR ++
                [{jnz, Lfalse}, {push, 0}, {jmp, Lend},
                 {label, Lfalse}, {push, 1}, {label, Lend}]
        end,
    {I, int, G4};
gen_expr({bin, Op, L, R}, G0) ->
    {IL, TL0, G1} = gen_expr(L, G0),
    {IR, TR0, G2} = gen_expr(R, G1),
    TL = fatcc_type:decay(TL0),
    TR = fatcc_type:decay(TR0),
    {Scale, OpType} = scale_for(Op, TL, TR),
    Instr = op_instr(Op, OpType),
    {IL ++ Scale(IR) ++ [Instr], result_type(Op, TL, TR), G2};
gen_expr({un, '-', E}, G0) ->
    {I, T, G1} = gen_expr(E, G0),
    {I ++ [neg], T, G1};
gen_expr({un, '+', E}, G0) ->
    gen_expr(E, G0);
gen_expr({un, '~', E}, G0) ->
    {I, T, G1} = gen_expr(E, G0),
    {I ++ [bnot_], T, G1};
gen_expr({un, '!', E}, G0) ->
    {I, _T, G1} = gen_expr(E, G0),
    {I ++ [lnot_], int, G1};
gen_expr({call, {id, Name}, Args}, G0) ->
    case maps:is_key(Name, G0#g.scope) orelse maps:is_key(Name, G0#g.globals) of
        true ->
            {IF, _FT, G1} = gen_expr({id, Name}, G0),
            {ArgI, _ArgTypes, G2} = gen_args(Args, G1),
            {IF ++ ArgI ++ [{call_indirect, length(Args)}], int, G2};
        false ->
            {ArgI, _ArgTypes, G1} = gen_args(Args, G0),
            Ret = case maps:find(Name, G1#g.protos) of
                      {ok, {R, _P, _V}} -> R;
                      error -> int
                  end,
            {ArgI ++ [{call, Name, length(Args)}], Ret, G1}
    end;
gen_expr({call, F, Args}, G0) ->
    {IF, _FT, G1} = gen_expr(F, G0),
    {ArgI, _ArgTypes, G2} = gen_args(Args, G1),
    {IF ++ ArgI ++ [{call_indirect, length(Args)}], int, G2};
gen_expr({assign, Op, L, R}, G0) ->
    gen_assign(Op, L, R, G0);
gen_expr({ternary, C, T, F}, G0) ->
    {LElse, G1} = fresh(G0),
    {LEnd, G2} = fresh(G1),
    {IC, _TC, G3} = gen_expr(C, G2),
    {IT, TT, G4} = gen_expr(T, G3),
    {IF, _TF, G5} = gen_expr(F, G4),
    {IC ++ [{jz, LElse}] ++ IT ++ [{jmp, LEnd}, {label, LElse}] ++ IF ++ [{label, LEnd}],
     TT, G5};
gen_expr({comma, L, R}, G0) ->
    {IL, _TL, G1} = gen_expr(L, G0),
    {IR, TR, G2} = gen_expr(R, G1),
    {IL ++ [{pop}] ++ IR, TR, G2};
gen_expr({index, A, I}, G0) ->
    {IA, TA, G1} = gen_addr({index, A, I}, G0),
    _ = TA,
    {IA ++ [{load, fatcc_type:size(elem_type(A, G1)), fatcc_type:sign_of(elem_type(A, G1))}],
     elem_type(A, G1), G1};
gen_expr({deref, E}, G0) ->
    {IE, TE, G1} = gen_expr(E, G0),
    T = fatcc_type:base(TE),
    {IE ++ [{load, fatcc_type:size(T), fatcc_type:sign_of(T)}], T, G1};
gen_expr({addr, E}, G0) ->
    {IA, TA, G1} = gen_addr(E, G0),
    {IA, {ptr, TA}, G1};
gen_expr({member, E, Name, Arrow}, G0) ->
    {IA, T, G1} = gen_member_addr(E, Name, Arrow, G0),
    case is_array_or_func(T) of
        true ->
            {IA, {ptr, fatcc_type:base(T)}, G1};
        false ->
            {IA ++ [{load, fatcc_type:size(T), fatcc_type:sign_of(T)}], T, G1}
    end;
gen_expr({cast, Type, E}, G0) ->
    {I, T, G1} = gen_expr(E, G0),
    {I ++ conversion(T, Type), Type, G1};
gen_expr({sizeof_type, Type}, G) ->
    {[{push, fatcc_type:size(Type)}], ulong, G};
gen_expr({sizeof_expr, E}, G) ->
    {[{push, fatcc_type:size(expr_type(E, G))}], ulong, G};
gen_expr({alignof_type, Type}, G) ->
    {[{push, fatcc_type:align(Type)}], ulong, G};
gen_expr({preinc, E}, G0) ->
    gen_assign('+=', E, {int, 1}, G0);
gen_expr({predec, E}, G0) ->
    gen_assign('-=', E, {int, 1}, G0);
gen_expr({postinc, E}, G0) ->
    gen_post_incdec(E, 1, G0);
gen_expr({postdec, E}, G0) ->
    gen_post_incdec(E, -1, G0);
gen_expr(Other, _G) ->
    error({unsupported_expr, Other}).

gen_args(Args, G) ->
    lists:foldl(
      fun(A, {I, Ts, Gx}) ->
          {IA, TA, Gy} = gen_expr(A, Gx),
          {I ++ IA, Ts ++ [TA], Gy}
      end, {[], [], G}, Args).

gen_assign('=', L, R, G0) ->
    {IA, LT, G1} = gen_addr(L, G0),
    {IR, _RT, G2} = gen_expr(R, G1),
    {IA ++ IR ++ [{store_keep, fatcc_type:size(LT)}], LT, G2};
gen_assign(Op, L, R, G0) ->
    BinOp = compound_to_bin(Op),
    {IA, LT, G1} = gen_addr(L, G0),
    Sz = fatcc_type:size(LT),
    Sgn = fatcc_type:sign_of(LT),
    {IR, _RT, G2} = gen_expr(R, G1),
    {IA ++ [{dup}, {load, Sz, Sgn}] ++ IR ++ [op_instr(BinOp, LT)] ++ [{store_keep, Sz}],
     LT, G2}.

compound_to_bin('+=') -> '+';
compound_to_bin('-=') -> '-';
compound_to_bin('*=') -> '*';
compound_to_bin('/=') -> '/';
compound_to_bin('%=') -> '%';
compound_to_bin('&=') -> '&';
compound_to_bin('|=') -> '|';
compound_to_bin('^=') -> '^';
compound_to_bin('<<=') -> '<<';
compound_to_bin('>>=') -> '>>'.

gen_post_incdec(E, Delta, G0) ->
    {IA, T, G1} = gen_addr(E, G0),
    Sz = fatcc_type:size(T),
    Sgn = fatcc_type:sign_of(T),
    {IA ++ [{dup}, {load, Sz, Sgn}, {swap}, {dup}, {load, Sz, Sgn},
            {push, Delta}, add, {store, Sz}], T, G1}.

%%====================================================================
%% Address generation
%%====================================================================
gen_addr({id, Name}, G) ->
    case maps:find(Name, G#g.scope) of
        {ok, {Type, Off}} -> {[{lea_local, Off}], Type, G};
        error ->
            case maps:find(Name, G#g.globals) of
                {ok, #global{type = Type}} -> {[{push_global_addr, Name}], Type, G};
                error -> error({undefined_lvalue, Name})
            end
    end;
gen_addr({deref, E}, G0) ->
    {IE, TE, G1} = gen_expr(E, G0),
    {IE, fatcc_type:base(TE), G1};
gen_addr({index, A, I}, G0) ->
    {IA, TA, G1} = gen_expr(A, G0),
    {II, _TI, G2} = gen_expr(I, G1),
    T = fatcc_type:base(fatcc_type:decay(TA)),
    Sz = fatcc_type:size(T),
    {IA ++ II ++ [{push, Sz}, mul, add], T, G2};
gen_addr({member, E, Name, Arrow}, G0) ->
    gen_member_addr(E, Name, Arrow, G0);
gen_addr({comma, L, R}, G0) ->
    {IL, _TL, G1} = gen_expr(L, G0),
    {IA, T, G2} = gen_addr(R, G1),
    {IL ++ [{pop}] ++ IA, T, G2};
gen_addr(E, _G) ->
    error({not_an_lvalue, E}).

gen_member_addr(E, Name, Arrow, G0) ->
    {BaseI, BaseT, G1} = case Arrow of
                             true -> gen_expr(E, G0);
                             false -> gen_addr(E, G0)
                         end,
    StructT = case Arrow of
                  true -> fatcc_type:base(BaseT);
                  false -> BaseT
              end,
    Members = struct_members(StructT),
    Off = field_offset(StructT, Members, Name),
    T = field_type(Members, Name),
    {BaseI ++ [{push, Off}, add], T, G1}.

struct_members({struct, _Tag, Members}) when is_list(Members) -> Members;
struct_members({union, _Tag, Members}) when is_list(Members) -> Members;
struct_members({struct, Tag}) -> tag_members({struct, Tag});
struct_members({union, Tag}) -> tag_members({union, Tag});
struct_members(_) -> [].

tag_members(Key) ->
    case erlang:get({fatcc_tag, Key}) of
        undefined -> error({unknown_struct, Key});
        Members -> Members
    end.

field_offset({union, _, _}, _Members, _Name) -> 0;
field_offset(_, Members, Name) -> fo(Members, Name, 0).

fo([{Name, T, _Bits} | _], Name, Off) -> align_up(Off, max(fatcc_type:align(T), 1));
fo([{_, T, _Bits} | R], Name, Off) ->
    fo(R, Name, align_up(Off, max(fatcc_type:align(T), 1)) + fatcc_type:size(T));
fo([], Name, _Off) -> error({no_such_field, Name}).

field_type(Members, Name) ->
    case lists:keyfind(Name, 1, Members) of
        {_, T, _} -> T;
        false -> error({no_such_field, Name})
    end.

elem_type(A, G) ->
    TA = expr_type(A, G),
    fatcc_type:base(fatcc_type:decay(TA)).

is_array_or_func({array, _, _}) -> true;
is_array_or_func({func, _, _, _}) -> true;
is_array_or_func(_) -> false.

%%====================================================================
%% Arithmetic helpers
%%====================================================================
scale_for(Op, TL, TR) ->
    case {Op, is_ptr_type(TL), is_ptr_type(TR)} of
        {'+', true, false} -> scaler_right(TL);
        {'+', false, true} -> scaler_left(TR);
        {'-', true, false} -> scaler_right(TL);
        {'-', true, true} ->
            {fun(IR) -> IR ++ [{push, psize(TL)}, {div_s}] end, long};
        _ ->
            {fun(IR) -> IR end, fatcc_type:usual(TL, TR)}
    end.

is_ptr_type({ptr, _}) -> true;
is_ptr_type(_) -> false.

psize({ptr, T}) -> max(fatcc_type:size(T), 1);
psize(_) -> 1.

scaler_right(PT) ->
    S = psize(PT),
    {fun(IR) -> IR ++ [{push, S}, mul] end, PT}.

scaler_left(PT) ->
    S = psize(PT),
    {fun(IR) -> [{push, S}, mul] ++ IR end, PT}.

op_instr(Op, Type) ->
    case fatcc_type:is_float(Type) of
        true -> float_op(Op);
        false -> int_op(Op, Type)
    end.

int_op('+', _) -> add;
int_op('-', _) -> sub;
int_op('*', _) -> mul;
int_op('/', T) -> case fatcc_type:is_signed(T) of true -> div_s; false -> div_u end;
int_op('%', T) -> case fatcc_type:is_signed(T) of true -> mod_s; false -> mod_u end;
int_op('&', _) -> band_;
int_op('|', _) -> bor_;
int_op('^', _) -> bxor_;
int_op('<<', _) -> shl;
int_op('>>', T) -> case fatcc_type:is_signed(T) of true -> shr_s; false -> shr_u end;
int_op('==', _) -> eq;
int_op('!=', _) -> ne;
int_op('<', T) -> case fatcc_type:is_signed(T) of true -> lt_s; false -> lt_u end;
int_op('<=', T) -> case fatcc_type:is_signed(T) of true -> le_s; false -> le_u end;
int_op('>', T) -> case fatcc_type:is_signed(T) of true -> gt_s; false -> gt_u end;
int_op('>=', T) -> case fatcc_type:is_signed(T) of true -> ge_s; false -> ge_u end.

float_op('+') -> fadd;
float_op('-') -> fsub;
float_op('*') -> fmul;
float_op('/') -> fdiv;
float_op('==') -> feq;
float_op('!=') -> fne;
float_op('<') -> flt;
float_op('<=') -> fle;
float_op('>') -> fgt;
float_op('>=') -> fge.

result_type('-', {ptr, _}, {ptr, _}) -> long;
result_type(Op, _TL, _TR) when Op =:= '=='; Op =:= '!='; Op =:= '<'; Op =:= '<=';
                                Op =:= '>'; Op =:= '>=' -> int;
result_type(Op, TL, _TR) when Op =:= '<<'; Op =:= '>>' -> fatcc_type:promote(TL);
result_type(_, TL, TR) -> fatcc_type:usual(TL, TR).

conversion(T, T) -> [];
conversion({ptr, _}, {ptr, _}) -> [];
conversion(From, To) ->
    case {fatcc_type:is_float(From), fatcc_type:is_float(To)} of
        {false, false} -> [{trunc, fatcc_type:size(To)}];
        {true, false} -> [{f2i, fatcc_type:size(To)}];
        {false, true} -> [{i2f}];
        {true, true} -> []
    end.

%%====================================================================
%% Type inference (for sizeof and addressing)
%%====================================================================
expr_type({int, _}, _G) -> int;
expr_type({char, _}, _G) -> int;
expr_type({float, _}, _G) -> double;
expr_type({str, _}, _G) -> {ptr, char};
expr_type({id, Name}, G) ->
    case maps:find(Name, G#g.scope) of
        {ok, {Type, _}} -> Type;
        error ->
            case maps:find(Name, G#g.protos) of
                {ok, {Ret, P, V}} -> {ptr, {func, Ret, P, V}};
                error ->
                    case maps:find(Name, G#g.globals) of
                        {ok, #global{type = Type}} -> Type;
                        error -> error({undefined_type, Name})
                    end
            end
    end;
expr_type({bin, Op, L, R}, G) ->
    TL = fatcc_type:decay(expr_type(L, G)),
    TR = fatcc_type:decay(expr_type(R, G)),
    result_type(Op, TL, TR);
expr_type({un, '-', E}, G) -> expr_type(E, G);
expr_type({un, '+', E}, G) -> expr_type(E, G);
expr_type({un, '~', E}, G) -> expr_type(E, G);
expr_type({un, '!', _}, _G) -> int;
expr_type({call, {id, Name}, _Args}, G) ->
    case maps:find(Name, G#g.protos) of
        {ok, {Ret, _, _}} -> Ret;
        error -> int
    end;
expr_type({call, F, _}, G) ->
    FT = fatcc_type:decay(expr_type(F, G)),
    case FT of
        {ptr, {func, Ret, _, _}} -> Ret;
        _ -> int
    end;
expr_type({assign, _, L, _}, G) -> expr_type(L, G);
expr_type({ternary, _, T, _}, G) -> expr_type(T, G);
expr_type({comma, _, R}, G) -> expr_type(R, G);
expr_type({index, A, _}, G) ->
    fatcc_type:base(fatcc_type:decay(expr_type(A, G)));
expr_type({deref, E}, G) ->
    fatcc_type:base(expr_type(E, G));
expr_type({addr, E}, G) ->
    {ptr, expr_type(E, G)};
expr_type({member, E, Name, Arrow}, G) ->
    BaseT = case Arrow of
                true -> fatcc_type:base(expr_type(E, G));
                false -> expr_type(E, G)
            end,
    field_type(struct_members(BaseT), Name);
expr_type({cast, Type, _}, _G) -> Type;
expr_type({sizeof_type, _}, _G) -> ulong;
expr_type({sizeof_expr, _}, _G) -> ulong;
expr_type({alignof_type, _}, _G) -> ulong;
expr_type({preinc, E}, G) -> expr_type(E, G);
expr_type({predec, E}, G) -> expr_type(E, G);
expr_type({postinc, E}, G) -> expr_type(E, G);
expr_type({postdec, E}, G) -> expr_type(E, G);
expr_type(_E, _G) -> int.

%%====================================================================
%% Strings / labels
%%====================================================================
add_string(B, G) ->
    case maps:find(B, G#g.strmap) of
        {ok, Idx} -> {Idx, G};
        error ->
            Idx = G#g.strcount,
            G1 = G#g{strings = maps:put(Idx, B, G#g.strings),
                     strmap = maps:put(B, Idx, G#g.strmap),
                     strcount = Idx + 1},
            {Idx, G1}
    end.

fresh(G) ->
    N = G#g.lbl,
    {"L" ++ integer_to_list(N), G#g{lbl = N + 1}}.
