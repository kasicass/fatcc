%% Linker: merges relocatable .fo images into one linked .fc image.
%%
%% Calls and globals are referenced by name, so only string-pool indices and
%% {str_addr, Idx} global initializers need relocation.
-module(fatcc_link).
-include("fat_image.hrl").

-export([link/1]).

-spec link([#image{}]) -> {ok, #image{}} | {error, term()}.
link([]) ->
    {ok, #image{}};
link([First | Rest]) ->
    try
        Image = lists:foldl(fun merge/2, normalize(First), Rest),
        {ok, Image}
    catch
        throw:{link_error, Reason} -> {error, Reason}
    end.

normalize(Image) -> Image.

merge(Img, Acc) ->
    Off = length(Acc#image.strings),
    Funcs = remap_funcs(Img#image.funcs, Off),
    Globals = maps:map(fun(_K, G) -> remap_global(G, Off) end, Img#image.globals),
    check_duplicates(maps:keys(Funcs), maps:keys(Acc#image.funcs), duplicate_function),
    check_duplicates(maps:keys(Globals), maps:keys(Acc#image.globals), duplicate_global),
    #image{
        entry = pick_entry(Acc#image.entry, Img#image.entry),
        funcs = maps:merge(Acc#image.funcs, Funcs),
        symbols = maps:merge(Acc#image.symbols, Img#image.symbols),
        globals = maps:merge(Acc#image.globals, Globals),
        strings = Acc#image.strings ++ Img#image.strings,
        types = maps:merge(Acc#image.types, Img#image.types),
        meta = maps:merge(Acc#image.meta, Img#image.meta)
    }.

pick_entry(_Old, "main") -> "main";
pick_entry(Old, _New) -> Old.

check_duplicates([], _Existing, _Kind) -> ok;
check_duplicates([K | R], Existing, Kind) ->
    case lists:member(K, Existing) of
        true -> throw({link_error, {Kind, K}});
        false -> check_duplicates(R, Existing, Kind)
    end.

remap_funcs(Funcs, Off) ->
    maps:map(
      fun(_Name, F) -> F#func{code = remap_code(F#func.code, Off)} end,
      Funcs).

remap_code(Code, Off) ->
    list_to_tuple([remap_instr(I, Off) || I <- tuple_to_list(Code)]).

remap_instr({push_str, I}, Off) -> {push_str, I + Off};
remap_instr(I, _Off) -> I.

remap_global(#global{init = {str_addr, I}} = G, Off) ->
    G#global{init = {str_addr, I + Off}};
remap_global(G, _Off) ->
    G.
