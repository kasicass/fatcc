%% Bytecode assembler: turns a symbolic instruction list (with {label, Name}
%% pseudo-instructions) into a 1-based instruction tuple and a label map.
-module(fatcc_asm).

-export([assemble/1, disassemble/1, format_instr/1]).

-spec assemble(list()) -> {tuple(), map()}.
assemble(Instrs) ->
    {RevCode, Labels} = pass1(Instrs, 1, [], #{}),
    CodeList = lists:reverse(RevCode),
    Resolved = [resolve(I, Labels) || I <- CodeList],
    {list_to_tuple(Resolved), Labels}.

pass1([], _Pc, Acc, Labels) ->
    {Acc, Labels};
pass1([{label, L} | R], Pc, Acc, Labels) ->
    pass1(R, Pc, Acc, maps:put(L, Pc, Labels));
pass1([I | R], Pc, Acc, Labels) ->
    pass1(R, Pc + 1, [I | Acc], Labels).

resolve({jmp, L}, M) -> {jmp, maps:get(L, M)};
resolve({jz, L}, M) -> {jz, maps:get(L, M)};
resolve({jnz, L}, M) -> {jnz, maps:get(L, M)};
resolve(I, _M) -> I.

-spec disassemble(tuple()) -> [string()].
disassemble(Code) ->
    [io_lib:format("~4w  ~s", [Pc, format_instr(element(Pc, Code))])
     || Pc <- lists:seq(1, tuple_size(Code))].

-spec format_instr(term()) -> string().
format_instr(I) ->
    lists:flatten(io_lib:format("~p", [I])).
