%% Load a .fc image and lay out its read-only data and globals in memory.
-module(fat_loader).
-include("fat_image.hrl").

-export([load/1, start/3, init_vm/2]).

-define(RODATA_BASE, 16#00010000).
-define(GLOBAL_BASE, 16#00020000).
-define(HEAP_BASE,   16#00100000).
-define(STACK_TOP,   16#7FFF00000000).

load(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> fat_format:decode(Bin);
        {error, Reason} -> {error, {cannot_read, Path, Reason}}
    end.

start(Path, Args, Opts) ->
    case load(Path) of
        {ok, Image} ->
            Vm = init_vm(Image, Opts),
            fat_vm:run(Vm, Args);
        {error, Reason} ->
            {error, Reason}
    end.

init_vm(#image{} = Image, Opts) ->
    Mem0 = fat_mem:new(),
    {Mem1, StrMap, AfterStrings} = write_strings(Image#image.strings, ?RODATA_BASE, 0, #{}, Mem0),
    {Mem2, GlobMap, _} = write_globals(Image#image.globals, max(AfterStrings, ?GLOBAL_BASE), #{}, StrMap, Mem1),
    {FuncAddrs, FuncByAddr} = assign_func_addrs(maps:keys(Image#image.funcs), 16#00040000, #{}, #{}),
    #vm{
        funcs = Image#image.funcs,
        func_addrs = FuncAddrs,
        func_by_addr = FuncByAddr,
        strings = StrMap,
        globals = GlobMap,
        global_types = maps:map(fun(_K, G) -> G#global.type end, Image#image.globals),
        entry = Image#image.entry,
        mem = Mem2,
        heap_top = ?HEAP_BASE,
        stack_top = ?STACK_TOP,
        sp = ?STACK_TOP,
        fp = ?STACK_TOP,
        max_steps = maps:get(max_steps, Opts, infinity),
        trace = maps:get(trace, Opts, false)
    }.

write_strings([], Addr, _Idx, Map, Mem) ->
    {Mem, Map, Addr};
write_strings([S | Rest], Addr, Idx, Map, Mem) ->
    Bin = <<(iolist_to_binary(S))/binary, 0>>,
    Mem1 = fat_mem:write_bytes(Mem, Addr, Bin),
    write_strings(Rest, Addr + byte_size(Bin), Idx + 1, maps:put(Idx, Addr, Map), Mem1).

write_globals(Globals, Addr0, Map0, StrMap, Mem0) ->
    maps:fold(
      fun(Name, #global{size = Size, init = Init}, {Mem, Map, Addr}) ->
          Mem1 = write_global_init(Mem, Addr, Init, StrMap),
          {Mem1, maps:put(Name, Addr, Map), Addr + max(Size, 1)}
      end, {Mem0, Map0, Addr0}, Globals).

write_global_init(Mem, _Addr, none, _StrMap) -> Mem;
write_global_init(Mem, Addr, Bin, _StrMap) when is_binary(Bin) ->
    fat_mem:write_bytes(Mem, Addr, Bin);
write_global_init(Mem, Addr, {str_addr, Idx}, StrMap) ->
    fat_mem:write(Mem, Addr, 8, maps:get(Idx, StrMap)).

assign_func_addrs([], _Addr, ByName, ByAddr) ->
    {ByName, ByAddr};
assign_func_addrs([Name | R], Addr, ByName, ByAddr) ->
    assign_func_addrs(R, Addr + 16,
                      maps:put(Name, Addr, ByName),
                      maps:put(Addr, Name, ByAddr)).